"""Free managed translation provider: MyMemory (api.mymemory.translated.net).

No API key or billing required, which makes it the zero-cost primary translator
for the lightweight deploy when neither a local NLLB model nor a paid provider
(Google) is available.

Quotas (per the public API): the anonymous tier allows ~5,000 characters/day per
calling IP; providing a contact email via ``MYMEMORY_EMAIL`` raises it to
~50,000/day. When the quota is exhausted MyMemory returns a non-200
``responseStatus`` (and puts a warning in ``translatedText``), which we treat as
a failure so the router falls back to returning the source text unchanged.

All failures here are soft: callers return the source text on any exception.
"""
from __future__ import annotations

import asyncio
import logging
from typing import Optional

import httpx

from ..config.settings import settings

logger = logging.getLogger("confrika.translation.mymemory")

_BASE = "https://api.mymemory.translated.net/get"
_TIMEOUT = httpx.Timeout(10.0, connect=5.0)

# Free crowd/MT translations: good, but honestly below paid NMT, so report a
# middling confidence.
_PROVIDER_CONFIDENCE = 0.75


def is_configured() -> bool:
    """Always available — MyMemory needs no key."""
    return True


class MyMemoryProvider:
    """Thin async client around the free MyMemory translation API."""

    @property
    def model_name(self) -> str:
        return "mymemory"

    async def translate(self, text: str, source_code: str, target_code: str) -> str:
        """Translate ``text`` from ``source_code`` to ``target_code``.

        Codes are ISO language codes (e.g. ``en``, ``yo``, ``ig``). Raises on any
        API error or exhausted quota; the router catches and falls back.
        """
        params = {"q": text, "langpair": f"{source_code}|{target_code}"}
        email = (settings.MYMEMORY_EMAIL or "").strip()
        if email:
            # Raises the daily quota from ~5k to ~50k characters.
            params["de"] = email
        # A freshly woken (scale-to-zero) machine can briefly fail DNS/connect,
        # so retry transport errors a couple of times before giving up.
        last_exc: Optional[Exception] = None
        resp = None
        for attempt in range(3):
            try:
                async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
                    resp = await client.get(_BASE, params=params)
                break
            except httpx.TransportError as exc:
                last_exc = exc
                if attempt < 2:
                    await asyncio.sleep(0.4 * (attempt + 1))
        if resp is None:
            raise RuntimeError(f"MyMemory unreachable: {last_exc}")
        resp.raise_for_status()
        data = resp.json()
        status = data.get("responseStatus")
        if status not in (200, "200"):
            # e.g. 403/429 when the daily quota is exhausted, or invalid pair.
            raise RuntimeError(
                f"MyMemory responseStatus={status}: {data.get('responseDetails')}"
            )
        translated = (data.get("responseData", {}).get("translatedText") or "").strip()
        if not translated:
            raise RuntimeError("MyMemory returned an empty translation")
        return translated


_provider: Optional[MyMemoryProvider] = None


def get_provider() -> MyMemoryProvider:
    global _provider
    if _provider is None:
        _provider = MyMemoryProvider()
    return _provider


PROVIDER_CONFIDENCE = _PROVIDER_CONFIDENCE
