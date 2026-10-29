from typing import Any, Dict, List, Optional

from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession

from ...database.models import User
from ...database.session import get_db
from ...services import billing_service
from ...services.teacher_service import (
    RateTeacherRequest,
    TeacherProfileRequest,
    TeacherService,
)
from .auth import get_current_user

router = APIRouter(prefix="/teachers", tags=["Teach & Earn"])


@router.post("/profile")
async def upsert_profile(
    req: TeacherProfileRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Become / update a teacher: headline, bio, languages taught, availability."""
    return await TeacherService.upsert_profile(db, current_user, req)


@router.get("")
async def list_teachers(
    q: Optional[str] = Query(None, description="Search name / @username / languages"),
    language: Optional[str] = Query(None, description="Filter to one language/dialect"),
    limit: int = Query(30, ge=1, le=100),
    offset: int = Query(0, ge=0),
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> List[Dict[str, Any]]:
    """Browse teachers, top-rated first. Bios are blurred for non-Pro users."""
    return await TeacherService.list_teachers(
        db, current_user, q=q, language=language, limit=limit, offset=offset
    )


@router.get("/me")
async def my_dashboard(
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Teacher dashboard: ratings, confirmations, accumulated reward, verified tag."""
    return await TeacherService.my_dashboard(db, current_user)


@router.post("/me/withdraw")
async def request_withdrawal(
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Request a payout of accumulated rewards (disbursement is Coming Soon)."""
    return await TeacherService.request_withdrawal(db, current_user)


@router.get("/{username}")
async def get_teacher(
    username: str,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """A teacher's page. Pro users see the full bio and can rate; others see a
    blurred bio teaser."""
    return await TeacherService.get_teacher(db, current_user, username)


@router.post("/{username}/rate")
async def rate_teacher(
    username: str,
    req: RateTeacherRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Rate / confirm a teacher's pronunciation. Pro-only (learning from a
    teacher is a Pro feature); confirmations reward the teacher."""
    billing_service.require_pro(current_user, "learn from and rate teachers")
    return await TeacherService.rate_teacher(db, current_user, username, req)
