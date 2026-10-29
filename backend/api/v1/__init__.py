from fastapi import APIRouter
from .auth import router as auth_router
from .contacts import router as contacts_router
from .chat import router as chat_router
from .speech_translation import router as speech_router
from .tone_coach import router as tone_router
from .calls import router as calls_router
from .media import router as media_router
from .communities import router as communities_router
from .admin import router as admin_router
from .billing import router as billing_router
from .teachers import router as teachers_router
from .sign import router as sign_router

v1_router = APIRouter(prefix="/api/v1")
v1_router.include_router(auth_router)
v1_router.include_router(contacts_router)
v1_router.include_router(chat_router)
v1_router.include_router(speech_router)
v1_router.include_router(tone_router)
v1_router.include_router(calls_router)
v1_router.include_router(media_router)
v1_router.include_router(communities_router)
v1_router.include_router(admin_router)
v1_router.include_router(billing_router)
v1_router.include_router(teachers_router)
v1_router.include_router(sign_router)

__all__ = ["v1_router"]
