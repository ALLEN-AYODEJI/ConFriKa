"""HTTP-level tests for the Teach & Earn routes and their admin panel surface.

A minimal FastAPI app mounts the real v1 router; ``get_db`` is backed by a shared
in-memory SQLite engine and ``get_current_user`` is overridden so we can act as
different users (free / pro / admin) without the full login flow. This exercises
routing, auth/Pro gating, and the service logic end to end.
"""
import asyncio
import uuid

import httpx
import pytest
from fastapi import FastAPI
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker
from sqlalchemy.pool import StaticPool

# Importing the router package first resolves the admin_service <-> api.v1
# circular import the same way the real app startup does.
import backend.api.v1  # noqa: F401
from backend.api.v1 import v1_router
from backend.api.v1.auth import get_current_user
from backend.config.settings import settings
from backend.database.models import Base, User
from backend.database.session import get_db


def _make_user(username, *, pro=False, admin=False):
    return User(
        id=str(uuid.uuid4()),
        username=username if username.startswith("@") else "@" + username,
        email=f"{username.strip('@')}@ex.com",
        password_hash="x",
        full_name=username.strip("@").title(),
        country_code="NG",
        origin_region="West Africa",
        primary_dialect="Yoruba",
        email_verified=True,
        subscription_tier="pro" if pro else "free",
        is_admin=admin,
    )


class _Harness:
    """A running ASGI app + session factory + a mutable 'current user'."""

    def __init__(self, app, client, Session, holder):
        self.app = app
        self.client = client
        self.Session = Session
        self.holder = holder

    def act_as(self, user):
        self.holder["user"] = user


async def _make_harness():
    engine = create_async_engine(
        "sqlite+aiosqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    Session = async_sessionmaker(engine, expire_on_commit=False)

    holder = {"user": None}

    async def _override_db():
        async with Session() as s:
            yield s

    async def _override_user():
        return holder["user"]

    app = FastAPI()
    app.include_router(v1_router)
    app.dependency_overrides[get_db] = _override_db
    app.dependency_overrides[get_current_user] = _override_user

    transport = httpx.ASGITransport(app=app)
    client = httpx.AsyncClient(transport=transport, base_url="http://test")
    return _Harness(app, client, Session, holder), engine


async def _seed(h):
    """Insert a teacher candidate, a free learner, pro learners, and an admin."""
    async with h.Session() as db:
        users = {
            # Teacher is Pro so the self-rating guard (400) is reachable past
            # the rate endpoint's Pro gate.
            "teacher": _make_user("teachme", pro=True),
            "free": _make_user("free1"),
            "admin": _make_user("boss", admin=True),
        }
        for i in range(4):
            users[f"pro{i}"] = _make_user(f"pro{i}", pro=True)
        db.add_all(list(users.values()))
        await db.commit()
    return users


# --------------------------------------------------------------------------- #
# The full flow in one test (shared expensive setup; distinct assertions).
# --------------------------------------------------------------------------- #
def test_teach_and_earn_http_flow():
    async def run():
        settings.TEACHER_VERIFY_CONFIRMATIONS = 3
        h, engine = await _make_harness()
        users = await _seed(h)
        c = h.client
        try:
            # Not a teacher yet.
            h.act_as(users["teacher"])
            r = await c.get("/api/v1/teachers/me")
            assert r.status_code == 200 and r.json() == {"is_teacher": False}

            # Become a teacher.
            r = await c.post("/api/v1/teachers/profile", json={
                "headline": "Native Yoruba speaker",
                "bio": "I teach Yoruba tones the easy way. " * 5,
                "languages": "Yoruba, Igbo",
                "is_active": True,
            })
            assert r.status_code == 200, r.text
            body = r.json()
            assert body["is_teacher"] is True
            assert body["languages"] == ["Yoruba", "Igbo"]

            # Discovery: free learner sees a blurred, locked bio.
            h.act_as(users["free"])
            r = await c.get("/api/v1/teachers")
            assert r.status_code == 200
            cards = r.json()
            assert len(cards) == 1
            assert cards[0]["bio_locked"] is True
            assert cards[0]["bio"].endswith("…")

            # Pro learner sees the full bio.
            h.act_as(users["pro0"])
            r = await c.get("/api/v1/teachers")
            assert r.json()[0]["bio_locked"] is False
            assert r.json()[0]["bio"].startswith("I teach Yoruba")

            # Free learner cannot rate (Pro-gated → 402).
            h.act_as(users["free"])
            r = await c.post("/api/v1/teachers/teachme/rate",
                             json={"stars": 5, "confirmed": True})
            assert r.status_code == 402, r.text

            # Three pro learners confirm → teacher becomes verified.
            for i in range(3):
                h.act_as(users[f"pro{i}"])
                r = await c.post("/api/v1/teachers/teachme/rate",
                                 json={"stars": 5, "confirmed": True})
                assert r.status_code == 200, r.text
            assert r.json()["is_verified"] is True
            assert r.json()["rating_count"] == 3

            # Self-rating is rejected.
            h.act_as(users["teacher"])
            r = await c.post("/api/v1/teachers/teachme/rate",
                             json={"stars": 5, "confirmed": True})
            assert r.status_code == 400

            # Dashboard: 3 confirmations at base rate (2c) = 6c, verified.
            r = await c.get("/api/v1/teachers/me")
            d = r.json()
            assert d["confirmed_count"] == 3
            assert d["reward_cents"] == 6
            assert d["is_verified"] is True

            # get_teacher returns the viewer's own rating.
            h.act_as(users["pro0"])
            r = await c.get("/api/v1/teachers/teachme")
            assert r.json()["my_rating"]["stars"] == 5

            # Withdrawal (coming soon) once verified with a balance.
            h.act_as(users["teacher"])
            r = await c.post("/api/v1/teachers/me/withdraw")
            assert r.status_code == 200
            assert r.json()["status"] == "coming_soon"

            # ── Admin surface ────────────────────────────────────────────
            # Non-admin is forbidden.
            h.act_as(users["pro0"])
            assert (await c.get("/api/v1/admin/teachers")).status_code == 403

            h.act_as(users["admin"])
            stats = (await c.get("/api/v1/admin/stats")).json()
            assert stats["teachers"] == 1
            assert stats["verified_teachers"] == 1
            assert "0.06" in stats["reward_owed"]
            assert stats["pending_withdrawals"] == 1

            tlist = (await c.get("/api/v1/admin/teachers")).json()
            assert len(tlist) == 1 and tlist[0]["username"] == "@teachme"

            # Verify toggle.
            assert (await c.post("/api/v1/admin/teachers/teachme/unverify")).status_code == 200
            assert (await c.get("/api/v1/admin/teachers")).json()[0]["is_verified"] is False
            await c.post("/api/v1/admin/teachers/teachme/verify")

            # Payout: list + mark-paid clears the teacher's balance.
            wlist = (await c.get("/api/v1/admin/withdrawals")).json()
            assert len(wlist) == 1 and wlist[0]["status"] == "coming_soon"
            wid = wlist[0]["id"]
            assert (await c.post(f"/api/v1/admin/withdrawals/{wid}/mark-paid")).status_code == 200
            assert (await c.get("/api/v1/admin/withdrawals")).json()[0]["status"] == "paid"

            h.act_as(users["teacher"])
            assert (await c.get("/api/v1/teachers/me")).json()["reward_cents"] == 0
            h.act_as(users["admin"])
            assert (await c.get("/api/v1/admin/stats")).json()["pending_withdrawals"] == 0
        finally:
            await c.aclose()
            await engine.dispose()

    asyncio.run(run())


def test_withdraw_requires_verified():
    """An unverified teacher with no confirmations can't withdraw."""
    async def run():
        settings.TEACHER_VERIFY_CONFIRMATIONS = 1000
        h, engine = await _make_harness()
        users = await _seed(h)
        c = h.client
        try:
            h.act_as(users["teacher"])
            await c.post("/api/v1/teachers/profile", json={
                "languages": "Yoruba", "is_active": True})
            # No reward accrued yet → 400 (nothing to withdraw).
            r = await c.post("/api/v1/teachers/me/withdraw")
            assert r.status_code == 400, r.text

            # One confirmation accrues a reward but doesn't reach the (high)
            # verify threshold → 403 (get verified to enable payouts).
            h.act_as(users["pro0"])
            await c.post("/api/v1/teachers/teachme/rate",
                         json={"stars": 5, "confirmed": True})
            h.act_as(users["teacher"])
            r = await c.post("/api/v1/teachers/me/withdraw")
            assert r.status_code == 403, r.text
        finally:
            await c.aclose()
            await engine.dispose()

    asyncio.run(run())
