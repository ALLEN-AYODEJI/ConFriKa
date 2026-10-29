"""Teach-and-earn: native speakers teach their language and earn rewards.

Learners (Pro users) browse teachers, learn from their pages, and rate/confirm
that a teacher's pronunciation is correct. Confirmations accrue a reward for the
teacher (a liability funded from app revenue), unlock a verified tag at a
threshold, and scale up per additional 1,000 confirmations. Payout/withdrawal is
tracked but actual disbursement is Coming Soon.
"""
from typing import Any, Dict, List, Optional

from fastapi import HTTPException, status
from pydantic import BaseModel, Field
from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from ..config.settings import settings
from ..database.models import TeacherProfile, TeacherRating, User, WithdrawalRequest
from . import billing_service


class TeacherProfileRequest(BaseModel):
    headline: Optional[str] = Field(None, max_length=160)
    bio: Optional[str] = Field(None, max_length=2000)
    languages: Optional[str] = Field(None, max_length=400)  # comma-separated
    is_active: bool = True


class RateTeacherRequest(BaseModel):
    stars: int = Field(5, ge=1, le=5)
    confirmed: bool = True  # "the pronunciation is correct"
    comment: Optional[str] = Field(None, max_length=500)


def _avg(profile: TeacherProfile) -> float:
    return round(profile.rating_sum / profile.rating_count, 2) if profile.rating_count else 0.0


def _blur_bio(bio: Optional[str]) -> Optional[str]:
    """A short teaser shown (blurred) to non-Pro users to entice an upgrade."""
    if not bio:
        return None
    teaser = bio.strip()[:70]
    return teaser + ("…" if len(bio.strip()) > 70 else "")


def _card(profile: TeacherProfile, user: User, *, viewer_is_pro: bool, full: bool = False) -> Dict[str, Any]:
    reward_tier = profile.confirmed_count // max(1, settings.TEACHER_VERIFY_CONFIRMATIONS)
    card: Dict[str, Any] = {
        "username": user.username,
        "full_name": user.full_name,
        "avatar_url": user.avatar_url,
        "country_code": user.country_code,
        "headline": profile.headline,
        "languages": [s.strip() for s in (profile.languages or "").split(",") if s.strip()],
        "is_verified": profile.is_verified,
        "avg_rating": _avg(profile),
        "rating_count": profile.rating_count,
        "confirmed_count": profile.confirmed_count,
        # Only Pro users can actually learn from a teacher; everyone else sees a
        # blurred bio teaser as an upgrade nudge.
        "bio_locked": not viewer_is_pro,
        "bio": profile.bio if viewer_is_pro else _blur_bio(profile.bio),
    }
    if full:
        card["reward_tier"] = reward_tier
    return card


class TeacherService:
    # ── Profile (become / update a teacher) ──────────────────────────────
    @classmethod
    async def upsert_profile(
        cls, db: AsyncSession, user: User, req: TeacherProfileRequest
    ) -> Dict[str, Any]:
        profile = await db.scalar(
            select(TeacherProfile).where(TeacherProfile.user_id == user.id)
        )
        if profile is None:
            profile = TeacherProfile(user_id=user.id)
            db.add(profile)
        profile.headline = req.headline
        profile.bio = req.bio
        profile.languages = req.languages
        profile.is_active = req.is_active
        await db.commit()
        await db.refresh(profile)
        return cls._dashboard_dict(profile, user)

    # ── Discovery (search, top-rated first) ──────────────────────────────
    @classmethod
    async def list_teachers(
        cls, db: AsyncSession, viewer: User, *, q: Optional[str] = None,
        language: Optional[str] = None, limit: int = 30, offset: int = 0,
    ) -> List[Dict[str, Any]]:
        stmt = (
            select(TeacherProfile, User)
            .join(User, User.id == TeacherProfile.user_id)
            .where(TeacherProfile.is_active.is_(True))
        )
        if language:
            stmt = stmt.where(TeacherProfile.languages.ilike(f"%{language.strip()}%"))
        if q:
            like = f"%{q.strip()}%"
            stmt = stmt.where(
                or_(
                    User.full_name.ilike(like),
                    User.username.ilike(like),
                    TeacherProfile.headline.ilike(like),
                    TeacherProfile.languages.ilike(like),
                )
            )
        rows = (await db.execute(stmt)).all()
        viewer_is_pro = billing_service.is_pro(viewer)

        # Top-rated first: a rating-count-aware average (so a single 5-star
        # doesn't outrank a well-reviewed teacher), verified teachers nudged up.
        def score(pair) -> tuple:
            p, _u = pair
            avg = p.rating_sum / (p.rating_count + 1)
            return (1 if p.is_verified else 0, avg, p.rating_count, p.confirmed_count)

        rows.sort(key=score, reverse=True)
        page = rows[offset : offset + limit]
        return [_card(p, u, viewer_is_pro=viewer_is_pro) for p, u in page]

    @classmethod
    async def get_teacher(
        cls, db: AsyncSession, viewer: User, username: str
    ) -> Dict[str, Any]:
        handle = username if username.startswith("@") else "@" + username
        user = await db.scalar(select(User).where(User.username == handle))
        profile = (
            await db.scalar(select(TeacherProfile).where(TeacherProfile.user_id == user.id))
            if user else None
        )
        if user is None or profile is None:
            raise HTTPException(status_code=404, detail="Teacher not found.")
        card = _card(profile, user, viewer_is_pro=billing_service.is_pro(viewer), full=True)
        # Has the viewer already rated this teacher?
        existing = await db.scalar(
            select(TeacherRating).where(
                TeacherRating.teacher_user_id == user.id,
                TeacherRating.rater_user_id == viewer.id,
            )
        )
        card["my_rating"] = (
            {"stars": existing.stars, "confirmed": existing.confirmed, "comment": existing.comment}
            if existing else None
        )
        return card

    # ── Rating / confirming a teacher (Pro learners only) ────────────────
    @classmethod
    async def rate_teacher(
        cls, db: AsyncSession, rater: User, username: str, req: RateTeacherRequest
    ) -> Dict[str, Any]:
        handle = username if username.startswith("@") else "@" + username
        teacher = await db.scalar(select(User).where(User.username == handle))
        profile = (
            await db.scalar(select(TeacherProfile).where(TeacherProfile.user_id == teacher.id))
            if teacher else None
        )
        if teacher is None or profile is None:
            raise HTTPException(status_code=404, detail="Teacher not found.")
        if teacher.id == rater.id:
            raise HTTPException(status_code=400, detail="You can't rate yourself.")

        existing = await db.scalar(
            select(TeacherRating).where(
                TeacherRating.teacher_user_id == teacher.id,
                TeacherRating.rater_user_id == rater.id,
            )
        )
        if existing is None:
            db.add(TeacherRating(
                teacher_user_id=teacher.id, rater_user_id=rater.id,
                stars=req.stars, confirmed=req.confirmed, comment=req.comment,
            ))
            profile.rating_count += 1
            profile.rating_sum += req.stars
            if req.confirmed:
                cls._accrue_confirmation(profile)
        else:
            profile.rating_sum += (req.stars - existing.stars)
            if req.confirmed and not existing.confirmed:
                cls._accrue_confirmation(profile)
            elif existing.confirmed and not req.confirmed:
                profile.confirmed_count = max(0, profile.confirmed_count - 1)
                # reward already earned is not clawed back
            existing.stars = req.stars
            existing.confirmed = req.confirmed
            existing.comment = req.comment

        await db.commit()
        await db.refresh(profile)
        return {
            "username": teacher.username,
            "avg_rating": _avg(profile),
            "rating_count": profile.rating_count,
            "is_verified": profile.is_verified,
        }

    @staticmethod
    def _accrue_confirmation(profile: TeacherProfile) -> None:
        # Reward per confirmation grows by one bonus unit for each full tier of
        # TEACHER_VERIFY_CONFIRMATIONS the teacher has already passed.
        tier = profile.confirmed_count // max(1, settings.TEACHER_VERIFY_CONFIRMATIONS)
        per = (
            settings.TEACHER_REWARD_PER_CONFIRMATION_CENTS
            + tier * settings.TEACHER_REWARD_TIER_BONUS_CENTS
        )
        profile.confirmed_count += 1
        profile.reward_cents += per
        if profile.confirmed_count >= settings.TEACHER_VERIFY_CONFIRMATIONS:
            profile.is_verified = True

    # ── Teacher dashboard + withdrawal (payout: coming soon) ─────────────
    @classmethod
    async def my_dashboard(cls, db: AsyncSession, user: User) -> Dict[str, Any]:
        profile = await db.scalar(
            select(TeacherProfile).where(TeacherProfile.user_id == user.id)
        )
        if profile is None:
            return {"is_teacher": False}
        return cls._dashboard_dict(profile, user)

    @staticmethod
    def _dashboard_dict(profile: TeacherProfile, user: User) -> Dict[str, Any]:
        remaining = max(0, settings.TEACHER_VERIFY_CONFIRMATIONS - profile.confirmed_count)
        return {
            "is_teacher": True,
            "headline": profile.headline,
            "bio": profile.bio,
            "languages": [s.strip() for s in (profile.languages or "").split(",") if s.strip()],
            "is_active": profile.is_active,
            "is_verified": profile.is_verified,
            "avg_rating": _avg(profile),
            "rating_count": profile.rating_count,
            "confirmed_count": profile.confirmed_count,
            "reward_cents": profile.reward_cents,
            "reward_currency": settings.TEACHER_REWARD_CURRENCY,
            "reward_display": f"{profile.reward_cents / 100:.2f} {settings.TEACHER_REWARD_CURRENCY}",
            "monetization_eligible": profile.is_verified,
            "confirmations_to_verify": remaining,
            "verify_threshold": settings.TEACHER_VERIFY_CONFIRMATIONS,
            "payout_status": "coming_soon",
        }

    @classmethod
    async def request_withdrawal(
        cls, db: AsyncSession, user: User
    ) -> Dict[str, Any]:
        profile = await db.scalar(
            select(TeacherProfile).where(TeacherProfile.user_id == user.id)
        )
        if profile is None or profile.reward_cents <= 0:
            raise HTTPException(status_code=400, detail="No rewards available to withdraw yet.")
        if not profile.is_verified:
            raise HTTPException(
                status_code=403,
                detail="Get verified (reach the confirmation threshold) to enable payouts.",
            )
        db.add(WithdrawalRequest(
            teacher_user_id=user.id, amount_cents=profile.reward_cents, status="coming_soon",
        ))
        await db.commit()
        return {
            "status": "coming_soon",
            "message": "Payouts are coming soon. Your request is noted and your rewards are safe.",
            "amount_display": f"{profile.reward_cents / 100:.2f} {settings.TEACHER_REWARD_CURRENCY}",
        }
