"""Public reach-metrics beacon (no auth).

Clients fire-and-forget a POST on load: the website (web_pageview), the mobile
app (app_open) and the browser extension (ext_open). The admin Overview reads
these back. Kept intentionally tiny and unauthenticated so a `mode:'no-cors'`
beacon can reach it without a CORS preflight.
"""
from typing import Optional

from fastapi import APIRouter, Depends, Response
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession

from ...database.models import User
from ...database.session import get_db
from ...services.metrics_service import MetricsService
from .auth import optional_user

router = APIRouter(prefix="/metrics", tags=["Metrics"])


@router.post("/hit", status_code=204)
async def hit(kind: str, db: AsyncSession = Depends(get_db)):
    """Increment the counter for ``kind`` (query param). Unknown kinds are
    silently ignored so the endpoint can never be used to create arbitrary rows."""
    await MetricsService.hit(db, kind)
    return Response(status_code=204)


class ExtEventRequest(BaseModel):
    install_id: str = Field(..., min_length=1, max_length=64)
    event: str  # 'register' | 'open' | 'recognize'
    version: Optional[str] = None


@router.post("/ext", status_code=204)
async def ext_event(
    body: ExtEventRequest,
    current_user: Optional[User] = Depends(optional_user),
    db: AsyncSession = Depends(get_db),
):
    """Record a browser-extension install/usage event. Works logged-out (tracks
    the anonymous install) and, when a bearer token is sent, attaches the user
    so the admin can see per-account usage."""
    await MetricsService.ext_event(db, body.install_id, body.event, body.version, current_user)
    return Response(status_code=204)
