"""HTTP tests for the reach-metrics beacon and the new admin sections."""
import uuid

import httpx
import pytest
from fastapi import FastAPI
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine
from sqlalchemy.pool import StaticPool

import backend.api.v1  # noqa: F401
from backend.api.v1 import v1_router
from backend.api.v1.auth import get_current_user
from backend.database.models import Base, User
from backend.database.session import get_db


def _admin() -> User:
    return User(
        id=str(uuid.uuid4()), username="@admin", email="a@ex.com", password_hash="x",
        full_name="Admin", country_code="NG", origin_region="West Africa",
        primary_dialect="Yoruba", email_verified=True, subscription_tier="free",
        is_admin=True,
    )


async def _client():
    engine = create_async_engine(
        "sqlite+aiosqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    Session = async_sessionmaker(engine, expire_on_commit=False)

    async def _get_db():
        async with Session() as s:
            yield s

    app = FastAPI()
    app.include_router(v1_router)
    app.dependency_overrides[get_db] = _get_db
    app.dependency_overrides[get_current_user] = _admin
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t")


@pytest.mark.asyncio
async def test_metrics_beacon_counts_and_surfaces_in_stats():
    async with await _client() as c:
        # Unknown kinds are accepted (204) but never counted.
        assert (await c.post("/api/v1/metrics/hit?kind=bogus")).status_code == 204
        for _ in range(3):
            assert (await c.post("/api/v1/metrics/hit?kind=web_pageview")).status_code == 204
        assert (await c.post("/api/v1/metrics/hit?kind=ext_open")).status_code == 204

        s = (await c.get("/api/v1/admin/stats")).json()
        assert s["web_pageviews"] == 3
        assert s["ext_opens"] == 1
        assert s["app_opens"] == 0
        for k in ["new_users_24h", "new_users_7d", "messages_24h",
                  "calls_total", "registered_devices", "calls_by_country", "daily"]:
            assert k in s
        assert isinstance(s["calls_by_country"], list)
        assert len(s["daily"]) == 14
        assert {"date", "messages", "calls", "signups"} <= set(s["daily"][0].keys())


@pytest.mark.asyncio
async def test_admin_communities_and_recent_content():
    async with await _client() as c:
        assert (await c.get("/api/v1/admin/communities")).status_code == 200
        r = await c.get("/api/v1/admin/content/recent")
        assert r.status_code == 200
        assert r.json() == []
