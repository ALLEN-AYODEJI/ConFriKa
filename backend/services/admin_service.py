"""Admin / moderation: platform stats, user listing, and bans.

Admin access is granted to accounts whose email is in ADMIN_EMAILS (applied on
startup) and enforced by `require_admin`."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional

from fastapi import Depends, HTTPException, status
from sqlalchemy import func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from ..config.settings import settings
from ..database.models import (
    CallSession,
    Community,
    CommunityMembership,
    DeviceToken,
    DirectMessage,
    GlobalSpacesMessage,
    TeacherProfile,
    User,
    WithdrawalRequest,
)
from ..database.session import get_db
from ..api.v1.auth import get_current_user
from .metrics_service import MetricsService


def _money(cents: int) -> str:
    return f"{(cents or 0) / 100:.2f} {settings.TEACHER_REWARD_CURRENCY}"


async def require_admin(current_user: User = Depends(get_current_user)) -> User:
    if not current_user.is_admin:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Admin access required.",
        )
    return current_user


class AdminService:
    @staticmethod
    async def bootstrap_admins(db: AsyncSession) -> None:
        """Grant admin to the configured ADMIN_EMAILS (idempotent)."""
        emails = settings.admin_emails
        if not emails:
            return
        users = (await db.scalars(select(User).where(User.email.in_(emails)))).all()
        changed = False
        for u in users:
            if not u.is_admin:
                u.is_admin = True
                changed = True
        if changed:
            await db.commit()

    @staticmethod
    async def stats(db: AsyncSession) -> Dict[str, Any]:
        total_users = await db.scalar(select(func.count(User.id))) or 0
        verified = await db.scalar(
            select(func.count(User.id)).where(User.email_verified == True)  # noqa: E712
        ) or 0
        banned = await db.scalar(
            select(func.count(User.id)).where(User.is_banned == True)  # noqa: E712
        ) or 0
        countries = await db.scalar(
            select(func.count(func.distinct(User.country_code)))
        ) or 0
        communities = await db.scalar(select(func.count(Community.id))) or 0
        dm_count = await db.scalar(select(func.count(DirectMessage.id))) or 0
        space_count = await db.scalar(select(func.count(GlobalSpacesMessage.id))) or 0
        # Users per country (top 10).
        rows = (
            await db.execute(
                select(User.country_code, func.count(User.id))
                .group_by(User.country_code)
                .order_by(func.count(User.id).desc())
                .limit(10)
            )
        ).all()
        by_country = [{"country": c, "count": n} for c, n in rows]
        # ── Teach & Earn ──────────────────────────────────────────────────
        teachers = await db.scalar(select(func.count(TeacherProfile.id))) or 0
        verified_teachers = await db.scalar(
            select(func.count(TeacherProfile.id)).where(
                TeacherProfile.is_verified == True  # noqa: E712
            )
        ) or 0
        reward_owed_cents = await db.scalar(
            select(func.coalesce(func.sum(TeacherProfile.reward_cents), 0))
        ) or 0
        pending_withdrawals = await db.scalar(
            select(func.count(WithdrawalRequest.id)).where(
                WithdrawalRequest.status != "paid"
            )
        ) or 0
        # ── Activity (time-based) ─────────────────────────────────────────
        now = datetime.now(timezone.utc).replace(tzinfo=None)  # naive UTC, matching the columns
        day_ago = now - timedelta(days=1)
        week_ago = now - timedelta(days=7)
        new_users_24h = await db.scalar(
            select(func.count(User.id)).where(User.created_at >= day_ago)
        ) or 0
        new_users_7d = await db.scalar(
            select(func.count(User.id)).where(User.created_at >= week_ago)
        ) or 0
        dm_24h = await db.scalar(
            select(func.count(DirectMessage.id)).where(DirectMessage.created_at >= day_ago)
        ) or 0
        gm_24h = await db.scalar(
            select(func.count(GlobalSpacesMessage.id)).where(
                GlobalSpacesMessage.created_at >= day_ago
            )
        ) or 0
        calls_total = await db.scalar(select(func.count(CallSession.id))) or 0
        # ── Reach ─────────────────────────────────────────────────────────
        # Registered devices (FCM tokens) is a real proxy for installs.
        devices = await db.scalar(select(func.count(DeviceToken.id))) or 0
        reach = await MetricsService.snapshot(db)  # web_pageview / app_open / ext_open
        return {
            "total_users": total_users,
            "verified_users": verified,
            "banned_users": banned,
            "total_countries": countries,
            "total_communities": communities,
            "direct_messages": dm_count,
            "global_messages": space_count,
            "users_by_country": by_country,
            "teachers": teachers,
            "verified_teachers": verified_teachers,
            "reward_owed": _money(reward_owed_cents),
            "pending_withdrawals": pending_withdrawals,
            # activity
            "new_users_24h": new_users_24h,
            "new_users_7d": new_users_7d,
            "messages_24h": int(dm_24h) + int(gm_24h),
            "calls_total": calls_total,
            # reach
            "registered_devices": devices,
            "web_pageviews": reach["web_pageview"],
            "app_opens": reach["app_open"],
            "ext_opens": reach["ext_open"],
        }

    @staticmethod
    async def list_users(
        db: AsyncSession, q: Optional[str], limit: int, offset: int
    ) -> List[Dict[str, Any]]:
        stmt = select(User)
        if q:
            like = f"%{q.strip().lower()}%"
            stmt = stmt.where(
                or_(
                    func.lower(User.username).like(like),
                    func.lower(User.email).like(like),
                    func.lower(User.full_name).like(like),
                )
            )
        stmt = stmt.order_by(User.created_at.desc()).limit(limit).offset(offset)
        users = (await db.scalars(stmt)).all()
        return [
            {
                "username": u.username,
                "email": u.email,
                "full_name": u.full_name,
                "country_code": u.country_code,
                "origin_region": u.origin_region,
                "email_verified": u.email_verified,
                "is_banned": u.is_banned,
                "is_admin": u.is_admin,
                "avatar_url": u.avatar_url,
                "created_at": u.created_at.isoformat() if u.created_at else None,
            }
            for u in users
        ]

    @staticmethod
    async def set_banned(
        db: AsyncSession, admin: User, username: str, banned: bool
    ) -> Dict[str, Any]:
        from .auth_service import normalize_username

        handle = normalize_username(username)
        user = await db.scalar(select(User).where(User.username == handle))
        if user is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found.")
        if user.id == admin.id:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="You can't ban yourself.")
        if user.is_admin:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="You can't ban another admin.")
        user.is_banned = banned
        await db.commit()
        return {"username": handle, "is_banned": banned}

    # ── Teach & Earn moderation ──────────────────────────────────────────
    @staticmethod
    async def list_teachers(
        db: AsyncSession, q: Optional[str], limit: int, offset: int
    ) -> List[Dict[str, Any]]:
        stmt = select(TeacherProfile, User).join(User, User.id == TeacherProfile.user_id)
        if q:
            like = f"%{q.strip().lower()}%"
            stmt = stmt.where(
                or_(
                    func.lower(User.username).like(like),
                    func.lower(User.full_name).like(like),
                    func.lower(TeacherProfile.languages).like(like),
                )
            )
        stmt = stmt.order_by(TeacherProfile.confirmed_count.desc()).limit(limit).offset(offset)
        rows = (await db.execute(stmt)).all()
        return [
            {
                "username": u.username,
                "full_name": u.full_name,
                "avatar_url": u.avatar_url,
                "languages": [s.strip() for s in (p.languages or "").split(",") if s.strip()],
                "is_verified": p.is_verified,
                "is_active": p.is_active,
                "confirmed_count": p.confirmed_count,
                "rating_count": p.rating_count,
                "avg_rating": round(p.rating_sum / p.rating_count, 2) if p.rating_count else 0.0,
                "reward": _money(p.reward_cents),
            }
            for p, u in rows
        ]

    @staticmethod
    async def set_teacher_verified(
        db: AsyncSession, username: str, verified: bool
    ) -> Dict[str, Any]:
        from .auth_service import normalize_username

        handle = normalize_username(username)
        user = await db.scalar(select(User).where(User.username == handle))
        profile = (
            await db.scalar(select(TeacherProfile).where(TeacherProfile.user_id == user.id))
            if user else None
        )
        if user is None or profile is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Teacher not found.")
        profile.is_verified = verified
        await db.commit()
        return {"username": handle, "is_verified": verified}

    @staticmethod
    async def list_withdrawals(
        db: AsyncSession, limit: int, offset: int
    ) -> List[Dict[str, Any]]:
        stmt = (
            select(WithdrawalRequest, User)
            .join(User, User.id == WithdrawalRequest.teacher_user_id)
            .order_by(WithdrawalRequest.created_at.desc())
            .limit(limit)
            .offset(offset)
        )
        rows = (await db.execute(stmt)).all()
        return [
            {
                "id": w.id,
                "username": u.username,
                "full_name": u.full_name,
                "amount": _money(w.amount_cents),
                "status": w.status,
                "created_at": w.created_at.isoformat() if w.created_at else None,
            }
            for w, u in rows
        ]

    @staticmethod
    async def mark_withdrawal_paid(
        db: AsyncSession, withdrawal_id: str
    ) -> Dict[str, Any]:
        w = await db.scalar(
            select(WithdrawalRequest).where(WithdrawalRequest.id == withdrawal_id)
        )
        if w is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Request not found.")
        w.status = "paid"
        # Settling a payout clears the teacher's accrued balance.
        profile = await db.scalar(
            select(TeacherProfile).where(TeacherProfile.user_id == w.teacher_user_id)
        )
        if profile is not None:
            profile.reward_cents = max(0, profile.reward_cents - w.amount_cents)
        await db.commit()
        return {"id": withdrawal_id, "status": "paid"}

    # ── Communities ───────────────────────────────────────────────────────
    @staticmethod
    async def list_communities(db: AsyncSession) -> List[Dict[str, Any]]:
        total_users = await db.scalar(select(func.count(User.id))) or 0
        mem_rows = (
            await db.execute(
                select(CommunityMembership.community_slug, func.count())
                .group_by(CommunityMembership.community_slug)
            )
        ).all()
        members = {slug: n for slug, n in mem_rows}
        post_rows = (
            await db.execute(
                select(GlobalSpacesMessage.channel_category, func.count())
                .group_by(GlobalSpacesMessage.channel_category)
            )
        ).all()
        posts = {slug: n for slug, n in post_rows}
        rows = (
            await db.scalars(
                select(Community).order_by(Community.is_default.desc(), Community.created_at.asc())
            )
        ).all()
        return [
            {
                "slug": c.slug,
                "name": c.name,
                "icon": c.icon,
                "category": c.category,
                "is_default": c.is_default,
                # Everyone belongs to a default community; others count memberships.
                "members": total_users if c.is_default else members.get(c.slug, 0),
                "posts": posts.get(c.slug, 0),
                "created_at": c.created_at.isoformat() if c.created_at else None,
            }
            for c in rows
        ]

    # ── Content moderation ────────────────────────────────────────────────
    @staticmethod
    async def recent_content(db: AsyncSession, limit: int = 40) -> List[Dict[str, Any]]:
        """Most recent public (Global Spaces) posts, for at-a-glance moderation."""
        rows = (
            await db.scalars(
                select(GlobalSpacesMessage)
                .order_by(GlobalSpacesMessage.created_at.desc())
                .limit(limit)
            )
        ).all()
        return [
            {
                "username": m.sender_username,
                "name": m.sender_name,
                "channel": m.channel_category,
                "type": m.message_type,
                "text": m.original_text,
                "created_at": m.created_at.isoformat() if m.created_at else None,
            }
            for m in rows
        ]
