"""HTTP-level tests for the sign-language recognizer.

Synthetic MediaPipe-style hands (21 landmarks) are built with chosen fingers
extended/curled, posted to the real ``/sign/recognize`` route, and checked
against the expected ASL letter/digit/phrase. ``get_current_user`` is overridden
so no login/DB is needed — the sign routes don't touch the database.
"""
import uuid

import httpx
import pytest
from fastapi import FastAPI

import backend.api.v1  # noqa: F401  (resolves the admin_service <-> api.v1 import)
from backend.api.v1 import v1_router
from backend.api.v1.auth import get_current_user
from backend.database.models import User


def _user() -> User:
    return User(
        id=str(uuid.uuid4()), username="@deafuser", email="d@ex.com",
        password_hash="x", full_name="Deaf User", country_code="NG",
        origin_region="West Africa", primary_dialect="Yoruba",
        email_verified=True, subscription_tier="free",
    )


def _app():
    app = FastAPI()
    app.include_router(v1_router)
    app.dependency_overrides[get_current_user] = _user
    return app


async def _client(app):
    transport = httpx.ASGITransport(app=app)
    return httpx.AsyncClient(transport=transport, base_url="http://t")


# ── Synthetic hand builder ───────────────────────────────────────────────────
def _hand(thumb: bool, index: bool, middle: bool, ring: bool, pinky: bool):
    """21 landmarks (as [x,y,z]) with the named fingers extended or curled.
    Geometry is chosen to clear the recognizer's thresholds: scale = 1.0
    (wrist→middle-MCP), extended tips sit far from the wrist, curled tips pull
    back toward the knuckles."""
    # wrist, thumb CMC/MCP are fixed anchors.
    pts = {0: (0.0, 0.0, 0.0), 1: (0.2, 0.3, 0.0), 2: (0.4, 0.5, 0.0)}
    # Thumb IP(3)/TIP(4)
    if thumb:
        pts[3] = (0.6, 0.6, 0.0)
        pts[4] = (1.0, 0.8, 0.0)   # far from wrist AND far from index-MCP → "out"
    else:
        pts[3] = (0.3, 0.7, 0.0)
        pts[4] = (0.25, 1.05, 0.0)  # tucked across the palm, by the index knuckle

    # Four fingers: MCP, PIP, DIP, TIP at columns x, knuckles at y≈1.0.
    cols = {"index": (0.3, 5), "middle": (0.0, 9), "ring": (-0.3, 13), "pinky": (-0.6, 17)}
    state = {"index": index, "middle": middle, "ring": ring, "pinky": pinky}
    for name, (x, mcp) in cols.items():
        pts[mcp] = (x, 1.0, 0.0)
        if state[name]:
            pts[mcp + 1] = (x, 1.4, 0.0)   # PIP
            pts[mcp + 2] = (x, 1.8, 0.0)   # DIP
            pts[mcp + 3] = (x, 2.2, 0.0)   # TIP (far from wrist → extended)
        else:
            pts[mcp + 1] = (x, 1.5, 0.0)   # PIP
            pts[mcp + 2] = (x, 1.3, 0.0)   # DIP
            pts[mcp + 3] = (x, 1.1, 0.0)   # TIP (pulled back → curled)
    return [{"x": pts[i][0], "y": pts[i][1], "z": pts[i][2]} for i in range(21)]


def _frames(hand, n=5):
    return [{"hands": [hand]} for _ in range(n)]


async def _recognize(client, hand, alphabet="letters", sign_language="ASL", n=5):
    r = await client.post("/api/v1/sign/recognize", json={
        "frames": _frames(hand, n), "alphabet": alphabet, "sign_language": sign_language,
    })
    assert r.status_code == 200, r.text
    return r.json()


# ── Tests ────────────────────────────────────────────────────────────────────
@pytest.mark.asyncio
async def test_letter_b_four_fingers():
    app = _app()
    async with await _client(app) as client:
        out = await _recognize(client, _hand(False, True, True, True, True))
        assert out["token"] == "B"
        assert out["kind"] == "letter"
        assert out["stable"] is True
        assert out["confidence"] > 0.8


@pytest.mark.asyncio
async def test_digit_alphabet_switches_token():
    app = _app()
    async with await _client(app) as client:
        out = await _recognize(client, _hand(False, True, True, True, True), alphabet="digits")
        assert out["token"] == "4"
        assert out["kind"] == "digit"


@pytest.mark.asyncio
async def test_letter_d_index_only():
    app = _app()
    async with await _client(app) as client:
        out = await _recognize(client, _hand(False, True, False, False, False))
        assert out["token"] == "D"


@pytest.mark.asyncio
async def test_letter_l_thumb_and_index():
    app = _app()
    async with await _client(app) as client:
        out = await _recognize(client, _hand(True, True, False, False, False))
        assert out["token"] == "L"


@pytest.mark.asyncio
async def test_letter_y_thumb_and_pinky():
    app = _app()
    async with await _client(app) as client:
        out = await _recognize(client, _hand(True, False, False, False, True))
        assert out["token"] == "Y"


@pytest.mark.asyncio
async def test_phrase_ily():
    app = _app()
    async with await _client(app) as client:
        out = await _recognize(client, _hand(True, True, False, False, True))
        assert out["token"] == "ILY"
        assert out["kind"] == "phrase"
        assert out["label"] == "I love you"


@pytest.mark.asyncio
async def test_open_hand_is_five():
    app = _app()
    async with await _client(app) as client:
        out = await _recognize(client, _hand(True, True, True, True, True), alphabet="digits")
        assert out["token"] == "5"


@pytest.mark.asyncio
async def test_no_hands_yields_none():
    app = _app()
    async with await _client(app) as client:
        r = await client.post("/api/v1/sign/recognize", json={
            "frames": [{"hands": []}, {"hands": []}], "alphabet": "letters",
        })
        assert r.status_code == 200, r.text
        out = r.json()
        assert out["token"] is None
        assert out["kind"] == "none"


@pytest.mark.asyncio
async def test_unsupported_language_is_beta():
    app = _app()
    async with await _client(app) as client:
        out = await _recognize(client, _hand(False, True, False, False, False),
                               sign_language="BSL")
        assert out["beta"] is True
        assert out["token"] is None


@pytest.mark.asyncio
async def test_vocabulary_lists_phrases_and_languages():
    app = _app()
    async with await _client(app) as client:
        r = await client.get("/api/v1/sign/vocabulary")
        assert r.status_code == 200, r.text
        out = r.json()
        assert "ASL" in out["sign_languages"]
        assert any(p["token"] == "ILY" and p["auto"] for p in out["phrases"])
        assert {"letters", "digits"} <= set(out["alphabets"])
        # word-model status is advertised so clients know whole-word mode exists.
        assert "word_model" in out
        assert out["word_model"]["beta"] is True


# ── Whole-word recognizer (trained TFLite model) ─────────────────────────────
from backend.services import sign_service  # noqa: E402

_WORD_MODEL_READY = sign_service.word_model_status()["available"]
_needs_model = pytest.mark.skipif(
    not _WORD_MODEL_READY,
    reason="word-sign TFLite model/runtime not installed (ai-edge-litert + models/sign)",
)


def _rand_landmarks(n):
    import random
    return [{"x": random.random(), "y": random.random(), "z": random.random()} for _ in range(n)]


def _holistic_frames(n=40, with_left=False):
    """Synthetic holistic frames: face + pose + right hand present, left optional.
    Random coordinates — enough to exercise the full inference path (we assert on
    shape/contract, not on which word a random burst happens to produce)."""
    frames = []
    for _ in range(n):
        frames.append({
            "face": _rand_landmarks(468),
            "pose": _rand_landmarks(33),
            "right_hand": _rand_landmarks(21),
            "left_hand": _rand_landmarks(21) if with_left else [],
        })
    return frames


@_needs_model
@pytest.mark.asyncio
async def test_word_recognize_returns_a_word():
    app = _app()
    async with await _client(app) as client:
        r = await client.post("/api/v1/sign/recognize-word", json={
            "frames": _holistic_frames(40), "sign_language": "ASL", "top_k": 4,
        })
        assert r.status_code == 200, r.text
        out = r.json()
        assert out["kind"] == "word"
        assert out["beta"] is True
        assert isinstance(out["token"], str) and out["token"]
        assert 0.0 <= out["confidence"] <= 1.0
        assert 1 <= len(out["candidates"]) <= 4
        # candidates are sorted by descending confidence and probabilities valid.
        confs = [c["confidence"] for c in out["candidates"]]
        assert confs == sorted(confs, reverse=True)
        assert all(0.0 <= c <= 1.0 for c in confs)


@_needs_model
@pytest.mark.asyncio
async def test_word_recognize_handles_single_frame_and_missing_hands():
    app = _app()
    async with await _client(app) as client:
        # One frame, no hands at all (face/pose only) — must not crash.
        r = await client.post("/api/v1/sign/recognize-word", json={
            "frames": [{"face": _rand_landmarks(468), "pose": _rand_landmarks(33)}],
            "sign_language": "ASL",
        })
        assert r.status_code == 200, r.text
        assert r.json()["kind"] == "word"


@_needs_model
@pytest.mark.asyncio
async def test_word_recognize_unsupported_language_is_beta():
    app = _app()
    async with await _client(app) as client:
        r = await client.post("/api/v1/sign/recognize-word", json={
            "frames": _holistic_frames(5), "sign_language": "BSL",
        })
        assert r.status_code == 200, r.text
        out = r.json()
        assert out["beta"] is True
        assert out["token"] is None


def test_frames_to_tensor_layout_and_nan_masking():
    """The 543-row layout (face, left-hand, pose, right-hand) and NaN masking of
    missing parts is the contract the model depends on — guard it directly."""
    import numpy as np
    from backend.services.sign_service import (
        HolisticFrame, Landmark, _frames_to_tensor,
        _OFF_FACE, _OFF_LHAND, _OFF_POSE, _OFF_RHAND, _ROWS_PER_FRAME,
    )
    f = HolisticFrame(
        face=[Landmark(x=0.1, y=0.2, z=0.3) for _ in range(468)],
        pose=[Landmark(x=0.4, y=0.5, z=0.6) for _ in range(33)],
        right_hand=[Landmark(x=0.7, y=0.8, z=0.9) for _ in range(21)],
        left_hand=[],  # missing on purpose
    )
    t = _frames_to_tensor([f])
    assert t.shape == (1, _ROWS_PER_FRAME, 3)
    assert np.isfinite(t[0, _OFF_FACE:_OFF_FACE + 468]).all()
    assert np.isfinite(t[0, _OFF_POSE:_OFF_POSE + 33]).all()
    assert np.isfinite(t[0, _OFF_RHAND:_OFF_RHAND + 21]).all()
    assert np.isnan(t[0, _OFF_LHAND:_OFF_LHAND + 21]).all()  # left hand => NaN
    assert t[0, _OFF_FACE, 0] == np.float32(0.1)
    assert t[0, _OFF_RHAND, 2] == np.float32(0.9)
