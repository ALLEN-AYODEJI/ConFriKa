"""Sign-language accessibility routes.

Clients (mobile camera, browser extension, future on-device models) extract hand
landmarks and POST them here to be recognized as sign tokens. Recognition is an
accessibility feature and is deliberately **not** metered against the free-tier
quota.
"""
from fastapi import APIRouter, Depends

from ...database.models import User
from ...services import sign_service
from ...services.sign_service import RecognizeRequest, RecognizeResponse
from .auth import get_current_user

router = APIRouter(prefix="/sign", tags=["Sign Language Accessibility"])


@router.get("/vocabulary")
async def vocabulary(current_user: User = Depends(get_current_user)):
    """The catalogue clients render: supported sign languages, the alphabet
    (fingerspelling), and the curated phrase palette (with which phrases are
    auto-recognized today vs. tap-to-insert)."""
    return {
        "sign_languages": sign_service.SUPPORTED_SIGN_LANGUAGES,
        "alphabets": ["letters", "digits"],
        "phrases": sign_service.PHRASE_CATALOG,
    }


@router.post("/recognize", response_model=RecognizeResponse)
async def recognize(
    req: RecognizeRequest,
    current_user: User = Depends(get_current_user),
):
    """Turn a short burst of hand-landmark frames into a sign token
    (letter / digit / phrase) with a confidence and stability signal."""
    return sign_service.recognize(req)
