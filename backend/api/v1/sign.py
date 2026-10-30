"""Sign-language accessibility routes.

Clients (mobile camera, browser extension, future on-device models) extract hand
landmarks and POST them here to be recognized as sign tokens. Recognition is an
accessibility feature and is deliberately **not** metered against the free-tier
quota.
"""
from typing import Optional

from fastapi import APIRouter, Depends

from ...database.models import User
from ...services import sign_service
from ...services.rate_limit import rate_limit
from ...services.sign_service import (
    RecognizeRequest,
    RecognizeResponse,
    RecognizeWordRequest,
)
from .auth import optional_user

router = APIRouter(prefix="/sign", tags=["Sign Language Accessibility"])


@router.get("/vocabulary")
async def vocabulary(current_user: Optional[User] = Depends(optional_user)):
    """The catalogue clients render: supported sign languages, the alphabet
    (fingerspelling), and the curated phrase palette (with which phrases are
    auto-recognized today vs. tap-to-insert)."""
    return {
        "sign_languages": sign_service.SUPPORTED_SIGN_LANGUAGES,
        "alphabets": ["letters", "digits"],
        "phrases": sign_service.PHRASE_CATALOG,
        "word_model": sign_service.word_model_status(),
    }


@router.post("/recognize", response_model=RecognizeResponse)
async def recognize(
    req: RecognizeRequest,
    current_user: Optional[User] = Depends(optional_user),
):
    """Turn a short burst of hand-landmark frames into a sign token
    (letter / digit / phrase) with a confidence and stability signal."""
    return sign_service.recognize(req)


@router.post(
    "/recognize-word",
    response_model=RecognizeResponse,
    dependencies=[rate_limit("sign_word", 60, 60)],
)
def recognize_word(
    req: RecognizeWordRequest,
    current_user: Optional[User] = Depends(optional_user),
):
    """Recognize a whole-word ASL sign from a burst of *holistic* landmarks
    (face + pose + both hands) using the trained 250-sign model. A word sign is
    motion over time, so the whole burst is classified as one sequence. Returns
    the top word with a confidence; ``beta`` is always True (fixed 250-sign
    vocabulary, not open translation). Sync route so the CPU inference runs in
    FastAPI's threadpool instead of blocking the event loop."""
    return sign_service.recognize_word(req)
