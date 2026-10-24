"""Real neural machine translation engine for ConFriKa.

Backed by Meta's open-source NLLB-200 model (No Language Left Behind), which
covers the major African languages ConFriKa targets. The model is loaded lazily
on first use and inference runs in a worker thread so the async event loop is
never blocked.

No external API keys are required; the model runs locally. The provider is
pluggable via ``settings.TRANSLATION_PROVIDER`` so a managed translation API can
be substituted later without touching callers.
"""
from __future__ import annotations

import asyncio
import logging
import math
import threading
from dataclasses import dataclass
from typing import Optional

from ..config.settings import settings
from . import google_translate_provider

logger = logging.getLogger("confrika.translation")

# ---------------------------------------------------------------------------
# Language label -> FLORES-200 code resolution
# ---------------------------------------------------------------------------
# Keys are lowercase keywords searched for inside a free-form dialect label such
# as "Yorùbá (Ọ̀yọ́)" or "Swahili (Nairobi)". Order matters: more specific keys
# should precede broader ones.
_KEYWORD_TO_FLORES: list[tuple[str, str]] = [
    ("english", "eng_Latn"),
    ("français", "fra_Latn"),
    ("francais", "fra_Latn"),
    ("french", "fra_Latn"),
    ("português", "por_Latn"),
    ("portugues", "por_Latn"),
    ("portuguese", "por_Latn"),
    ("العربية", "arb_Arab"),
    ("arabic", "arb_Arab"),
    ("afrikaans", "afr_Latn"),
    ("yorùbá", "yor_Latn"),
    ("yoruba", "yor_Latn"),
    ("igbo", "ibo_Latn"),
    ("hausa", "hau_Latn"),
    ("fulfulde", "fuv_Latn"),
    ("fulani", "fuv_Latn"),
    ("fula", "fuv_Latn"),
    ("swahili", "swh_Latn"),
    ("kiswahili", "swh_Latn"),
    ("amharic", "amh_Ethi"),
    ("tigrinya", "tir_Ethi"),
    ("oromo", "gaz_Latn"),
    ("somali", "som_Latn"),
    ("zulu", "zul_Latn"),
    ("isizulu", "zul_Latn"),
    ("xhosa", "xho_Latn"),
    ("isixhosa", "xho_Latn"),
    ("swati", "ssw_Latn"),
    ("tswana", "tsn_Latn"),
    ("setswana", "tsn_Latn"),
    ("northern sotho", "nso_Latn"),
    ("sepedi", "nso_Latn"),
    ("sotho", "sot_Latn"),
    ("sesotho", "sot_Latn"),
    ("tsonga", "tso_Latn"),
    ("shona", "sna_Latn"),
    ("twi", "aka_Latn"),
    ("akan", "aka_Latn"),
    ("ashanti", "aka_Latn"),
    ("ewe", "ewe_Latn"),
    ("fon", "fon_Latn"),
    ("bambara", "bam_Latn"),
    ("bamanankan", "bam_Latn"),
    ("wolof", "wol_Latn"),
    ("lingala", "lin_Latn"),
    ("kongo", "kon_Latn"),
    ("kikongo", "kon_Latn"),
    ("kinyarwanda", "kin_Latn"),
    ("rwanda", "kin_Latn"),
    ("kirundi", "run_Latn"),
    ("rundi", "run_Latn"),
    ("luganda", "lug_Latn"),
    ("ganda", "lug_Latn"),
    ("kikuyu", "kik_Latn"),
    ("gikuyu", "kik_Latn"),
    ("kamba", "kam_Latn"),
    ("luo", "luo_Latn"),
    ("chichewa", "nya_Latn"),
    ("nyanja", "nya_Latn"),
    ("bemba", "bem_Latn"),
    ("umbundu", "umb_Latn"),
    ("kabyle", "kab_Latn"),
    ("tamazight", "kab_Latn"),
    # ----- Extended NLLB-200 African coverage (proper language models) -----
    ("dioula", "dyu_Latn"),
    ("dyula", "dyu_Latn"),
    ("jula", "dyu_Latn"),
    ("kabuverdianu", "kea_Latn"),
    ("cape verdean", "kea_Latn"),
    ("crioulo", "kea_Latn"),
    ("kriolu", "kea_Latn"),
    ("kimbundu", "kmb_Latn"),
    ("mooré", "mos_Latn"),
    ("moore", "mos_Latn"),
    ("mossi", "mos_Latn"),
    ("sango", "sag_Latn"),
    ("tamasheq", "taq_Latn"),
    ("tamajaq", "taq_Latn"),
    ("tuareg", "taq_Latn"),
    ("tshiluba", "lua_Latn"),
    ("ciluba", "lua_Latn"),
    ("luba", "lua_Latn"),
    ("kanuri", "knc_Latn"),
    ("kanembu", "knc_Latn"),
    ("dinka", "dik_Latn"),
    ("nuer", "nus_Latn"),
    ("tumbuka", "tum_Latn"),
    ("kabiyè", "kbp_Latn"),
    ("kabiye", "kbp_Latn"),
    ("malagasy", "plt_Latn"),
    ("merina", "plt_Latn"),
    ("kituba", "kon_Latn"),
    ("kutuba", "kon_Latn"),
    # ----- Regional Arabic varieties -----
    ("darija", "ary_Arab"),
    ("moroccan", "ary_Arab"),
    ("algerian", "ary_Arab"),
    ("egyptian", "arz_Arab"),
    ("masri", "arz_Arab"),
    ("tunisian", "aeb_Arab"),
    # ----- Best-effort fallbacks: NLLB-200 has no dedicated model for these
    # local dialects, so we route them to the closest regional language the
    # model DOES support (better than an "unavailable" error). -----
    ("bamiléké", "fra_Latn"),
    ("bamileke", "fra_Latn"),
    ("duala", "fra_Latn"),
    ("ewondo", "fra_Latn"),
    ("bulu", "fra_Latn"),
    ("basaa", "fra_Latn"),
    ("banda", "sag_Latn"),
    ("gbaya", "sag_Latn"),
    ("sara", "fra_Latn"),
    ("teke", "lin_Latn"),
    ("bariba", "fra_Latn"),
    ("dendi", "fra_Latn"),
    ("chokwe", "umb_Latn"),
    ("kalanga", "sna_Latn"),
    ("shekgalagari", "tsn_Latn"),
    ("shikomori", "swh_Latn"),
    ("shindzuani", "swh_Latn"),
    ("shimwali", "swh_Latn"),
    ("comorian", "swh_Latn"),
    # ----- Nigerian languages NLLB-200 does NOT cover. These resolve to an
    # English FLORES placeholder (so same-language short-circuits still work),
    # but the translation router sends them to a managed provider (Google) when
    # one is configured, via _KEYWORD_TO_GOOGLE below. If no provider covers a
    # given language, it degrades to the English fallback as before. -----
    ("tiv", "eng_Latn"),
    ("efik", "eng_Latn"),
    ("ibibio", "eng_Latn"),
    ("idoma", "eng_Latn"),
    ("igala", "eng_Latn"),
    ("nupe", "eng_Latn"),
    ("edo", "eng_Latn"),
    ("bini", "eng_Latn"),
    ("urhobo", "eng_Latn"),
    ("isoko", "eng_Latn"),
    ("kalabari", "eng_Latn"),
    ("ijaw", "eng_Latn"),
    ("nigerian pidgin", "eng_Latn"),
    ("pidgin", "eng_Latn"),
]

DEFAULT_FLORES = "eng_Latn"


def resolve_flores_code(label: Optional[str]) -> str:
    """Map a free-form dialect/language label to a FLORES-200 code.

    Falls back to English when no known language keyword is found.
    """
    if not label:
        return DEFAULT_FLORES
    low = label.strip().lower()
    for keyword, code in _KEYWORD_TO_FLORES:
        if keyword in low:
            return code
    return DEFAULT_FLORES


# ---------------------------------------------------------------------------
# Managed-provider routing
# ---------------------------------------------------------------------------
# Keywords whose FLORES resolution above is a *lossy* fallback: NLLB-200 has no
# dedicated model for the real dialect, so it is routed to English or a nearby
# regional language. For these the router prefers a managed provider that does
# cover the language, when one is configured.
_FALLBACK_KEYWORDS: set[str] = {
    "bamiléké", "bamileke", "duala", "ewondo", "bulu", "basaa", "banda",
    "gbaya", "sara", "teke", "bariba", "dendi", "chokwe", "kalanga",
    "shekgalagari", "shikomori", "shindzuani", "shimwali", "comorian",
    "tiv", "efik", "ibibio", "idoma", "igala", "nupe", "edo", "bini",
    "urhobo", "isoko", "kalabari", "ijaw", "nigerian pidgin", "pidgin",
}

# Keyword -> Google Cloud Translation language code. Codes follow ISO 639-1
# where one exists, else ISO 639-3. The router only ever calls Google after
# confirming each code against Google's live supported-languages list, so a
# code Google does not (yet) support is simply skipped and the request falls
# back to NLLB. Add new gap languages here as providers gain coverage.
_KEYWORD_TO_GOOGLE: dict[str, str] = {
    # Pivot / major languages (used when a gap language is paired with them).
    "english": "en", "french": "fr", "français": "fr", "francais": "fr",
    "portuguese": "pt", "português": "pt", "portugues": "pt",
    "arabic": "ar", "afrikaans": "af",
    "yoruba": "yo", "yorùbá": "yo", "igbo": "ig", "hausa": "ha",
    "swahili": "sw", "kiswahili": "sw",
    "amharic": "am", "tigrinya": "ti", "oromo": "om", "somali": "so",
    "zulu": "zu", "isizulu": "zu", "xhosa": "xh", "isixhosa": "xh",
    "sotho": "st", "sesotho": "st", "tswana": "tn", "setswana": "tn",
    "northern sotho": "nso", "sepedi": "nso", "tsonga": "ts", "shona": "sn",
    "twi": "ak", "akan": "ak", "ashanti": "ak", "ewe": "ee", "fon": "fon",
    "bambara": "bm", "bamanankan": "bm", "wolof": "wo",
    "lingala": "ln", "kongo": "kg", "kikongo": "kg",
    "kinyarwanda": "rw", "rwanda": "rw", "kirundi": "rn", "rundi": "rn",
    "luganda": "lg", "ganda": "lg", "luo": "luo", "chichewa": "ny",
    "nyanja": "ny", "bemba": "bem", "malagasy": "mg",
    # Nigerian gap languages NLLB-200 lacks (coverage varies by provider; the
    # live-support check gates each one).
    "tiv": "tiv", "efik": "efi", "ibibio": "ibb", "idoma": "idu",
    "igala": "igl", "nupe": "nup", "edo": "bin", "bini": "bin",
    "urhobo": "urh", "isoko": "iso", "kalabari": "ijn", "ijaw": "ijn",
    "nigerian pidgin": "pcm", "pidgin": "pcm",
}


@dataclass
class _Language:
    """Resolved view of a free-form language label."""

    flores: str
    google: Optional[str]
    nllb_native: bool  # False when FLORES above is a lossy fallback


def _resolve_language(label: Optional[str]) -> _Language:
    """Resolve a label to FLORES + managed-provider codes and NLLB coverage."""
    if not label:
        return _Language(DEFAULT_FLORES, _KEYWORD_TO_GOOGLE.get("english"), True)
    low = label.strip().lower()
    for keyword, code in _KEYWORD_TO_FLORES:
        if keyword in low:
            return _Language(
                flores=code,
                google=_KEYWORD_TO_GOOGLE.get(keyword),
                nllb_native=keyword not in _FALLBACK_KEYWORDS,
            )
    # Unknown label: English placeholder (treated as NLLB-native English).
    return _Language(DEFAULT_FLORES, _KEYWORD_TO_GOOGLE.get("english"), True)


@dataclass
class EngineResult:
    translated_text: str
    source_code: str
    target_code: str
    confidence: float  # [0, 1], derived from the model's own token scores
    model: str


class _NLLBEngine:
    """Lazy, thread-safe wrapper around an NLLB-200 seq2seq model."""

    def __init__(self) -> None:
        self._tokenizer = None
        self._model = None
        self._torch = None
        self._lock = threading.Lock()
        self._ready = False

    @property
    def is_ready(self) -> bool:
        return self._ready

    def _ensure_loaded(self) -> None:
        if self._ready:
            return
        with self._lock:
            if self._ready:
                return
            logger.info("Loading NLLB translation model: %s", settings.NLLB_MODEL)
            import torch  # noqa: WPS433 (heavy, intentionally lazy)
            from transformers import AutoModelForSeq2SeqLM, AutoTokenizer

            cache_dir = settings.MODEL_CACHE_DIR or None
            self._tokenizer = AutoTokenizer.from_pretrained(
                settings.NLLB_MODEL, cache_dir=cache_dir
            )
            self._model = AutoModelForSeq2SeqLM.from_pretrained(
                settings.NLLB_MODEL, cache_dir=cache_dir
            )
            device = settings.NLLB_DEVICE if (settings.NLLB_DEVICE == "cuda" and torch.cuda.is_available()) else "cpu"
            self._model.to(device)
            self._model.eval()
            self._torch = torch
            self._device = device
            self._ready = True
            logger.info("NLLB model loaded on device=%s", device)

    def translate(self, text: str, src_code: str, tgt_code: str) -> EngineResult:
        self._ensure_loaded()
        torch = self._torch
        tokenizer = self._tokenizer
        model = self._model

        tokenizer.src_lang = src_code
        inputs = tokenizer(
            text,
            return_tensors="pt",
            truncation=True,
            max_length=settings.NLLB_MAX_INPUT_TOKENS,
        ).to(self._device)

        bos_id = tokenizer.convert_tokens_to_ids(tgt_code)
        with torch.no_grad():
            generated = model.generate(
                **inputs,
                forced_bos_token_id=bos_id,
                max_length=settings.NLLB_MAX_INPUT_TOKENS,
                num_beams=4,
                output_scores=True,
                return_dict_in_generate=True,
            )

        sequences = generated.sequences
        translated = tokenizer.batch_decode(sequences, skip_special_tokens=True)[0].strip()

        confidence = 0.0
        try:
            transition = model.compute_transition_scores(
                sequences, generated.scores, generated.beam_indices, normalize_logits=True
            )
            # transition log-probs -> mean prob across generated tokens.
            valid = transition[0][torch.isfinite(transition[0])]
            if valid.numel() > 0:
                confidence = float(torch.exp(valid.mean()).clamp(0.0, 1.0))
        except Exception:  # scoring is best-effort; translation still returned
            confidence = 0.0

        return EngineResult(
            translated_text=translated,
            source_code=src_code,
            target_code=tgt_code,
            confidence=round(confidence, 4),
            model=settings.NLLB_MODEL,
        )


_engine: Optional[_NLLBEngine] = None
_engine_init_lock = threading.Lock()


def _get_engine() -> _NLLBEngine:
    global _engine
    if _engine is None:
        with _engine_init_lock:
            if _engine is None:
                _engine = _NLLBEngine()
    return _engine


def engine_ready() -> bool:
    return _engine is not None and _engine.is_ready


async def warmup() -> None:
    """Pre-load the model so the first user request is fast."""
    if settings.TRANSLATION_PROVIDER != "nllb":
        return
    try:
        await asyncio.to_thread(_get_engine()._ensure_loaded)
    except Exception as exc:  # pragma: no cover - warmup is best effort
        logger.warning("Translation warmup failed (will retry on demand): %s", exc)


async def _translate_via_google(text: str, src: _Language, tgt: _Language) -> EngineResult:
    """Google Cloud Translation as the *primary* engine (no local NLLB).

    Used by the lightweight deploy (``TRANSLATION_PROVIDER=google``) so real
    translation works on a tiny machine with no model loaded. When Google is
    unconfigured or does not cover the pair, the source text is returned
    unchanged — there is no local model to fall back to in this mode.
    """
    if src.google and tgt.google and google_translate_provider.is_configured():
        gp = google_translate_provider.get_provider()
        try:
            if await gp.supports(src.google, tgt.google):
                translated = await gp.translate(text, src.google, tgt.google)
                return EngineResult(
                    translated_text=translated,
                    source_code=src.google,
                    target_code=tgt.google,
                    confidence=google_translate_provider.PROVIDER_CONFIDENCE,
                    model=gp.model_name,
                )
            logger.info(
                "Google does not cover %s->%s; returning source unchanged",
                src.google, tgt.google,
            )
        except Exception as exc:
            logger.warning(
                "Google translate failed (%s->%s), returning source unchanged: %s",
                src.google, tgt.google, exc,
            )
    elif not google_translate_provider.is_configured():
        logger.warning(
            "TRANSLATION_PROVIDER=google but GOOGLE_TRANSLATE_API_KEY is not set; "
            "returning source unchanged"
        )
    return EngineResult(text, src.flores, tgt.flores, 0.0, "passthrough")


async def translate(text: str, source_label: str, target_label: str) -> EngineResult:
    """Translate ``text`` from ``source_label`` to ``target_label``.

    Labels are free-form language/dialect names. The request is routed:
      1. NLLB-200 (local, free) handles every language it covers.
      2. For languages NLLB cannot do (e.g. Tiv), a managed provider (Google) is
         used when configured and when it actually covers both languages.
      3. Otherwise the request degrades to NLLB's closest/English fallback.
    """
    src = _resolve_language(source_label)
    tgt = _resolve_language(target_label)

    stripped = (text or "").strip()
    if not stripped:
        return EngineResult("", src.flores, tgt.flores, 0.0, "none")

    # Identity keyed on the strongest available code, so two different gap
    # languages that share the English FLORES placeholder are NOT short-circuited.
    src_key = src.google or src.flores
    tgt_key = tgt.google or tgt.flores
    if src_key == tgt_key:
        return EngineResult(stripped, src.flores, tgt.flores, 1.0, "identity")

    provider = settings.TRANSLATION_PROVIDER
    if provider == "echo":
        # Development-only passthrough. Never enabled in production.
        return EngineResult(stripped, src.flores, tgt.flores, 0.0, "echo")

    if provider == "google":
        # Managed provider as the sole engine (lightweight deploy, no NLLB).
        return await _translate_via_google(stripped, src, tgt)

    # --- Managed-provider route for languages NLLB-200 does not cover. ---
    nllb_lossy = (not src.nllb_native) or (not tgt.nllb_native)
    if (
        nllb_lossy
        and src.google
        and tgt.google
        and google_translate_provider.is_configured()
    ):
        gp = google_translate_provider.get_provider()
        try:
            if await gp.supports(src.google, tgt.google):
                translated = await gp.translate(stripped, src.google, tgt.google)
                return EngineResult(
                    translated_text=translated,
                    source_code=src.google,
                    target_code=tgt.google,
                    confidence=google_translate_provider.PROVIDER_CONFIDENCE,
                    model=gp.model_name,
                )
            logger.info(
                "Google does not cover %s->%s; falling back to NLLB",
                src.google, tgt.google,
            )
        except Exception as exc:
            logger.warning(
                "Google translate failed (%s->%s), falling back to NLLB: %s",
                src.google, tgt.google, exc,
            )

    engine = _get_engine()
    return await asyncio.to_thread(engine.translate, stripped, src.flores, tgt.flores)
