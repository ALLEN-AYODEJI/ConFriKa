"""Public reach-metrics beacon (no auth).

Clients fire-and-forget a POST on load: the website (web_pageview), the mobile
app (app_open) and the browser extension (ext_open). The admin Overview reads
these back. Kept intentionally tiny and unauthenticated so a `mode:'no-cors'`
beacon can reach it without a CORS preflight.
"""
from fastapi import APIRouter, Depends, Response
from sqlalchemy.ext.asyncio import AsyncSession

from ...database.session import get_db
from ...services.metrics_service import MetricsService

router = APIRouter(prefix="/metrics", tags=["Metrics"])


@router.post("/hit", status_code=204)
async def hit(kind: str, db: AsyncSession = Depends(get_db)):
    """Increment the counter for ``kind`` (query param). Unknown kinds are
    silently ignored so the endpoint can never be used to create arbitrary rows."""
    await MetricsService.hit(db, kind)
    return Response(status_code=204)
