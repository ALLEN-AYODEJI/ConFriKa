from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession

from ...database.session import get_db
from ...database.models import User
from ...services.admin_service import AdminService, require_admin

router = APIRouter(prefix="/admin", tags=["Admin"])


@router.get("/me")
async def admin_me(admin: User = Depends(require_admin)):
    """Confirm the caller is an admin (used by the dashboard login)."""
    return {"username": admin.username, "full_name": admin.full_name, "is_admin": True}


@router.get("/stats")
async def stats(
    admin: User = Depends(require_admin),
    db: AsyncSession = Depends(get_db),
):
    return await AdminService.stats(db)


@router.get("/extension")
async def extension(
    admin: User = Depends(require_admin),
    db: AsyncSession = Depends(get_db),
):
    """Browser-extension installs + usage (totals, active, signed-in, recent)."""
    return await AdminService.extension_stats(db)


@router.get("/users")
async def list_users(
    q: str | None = Query(None),
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    admin: User = Depends(require_admin),
    db: AsyncSession = Depends(get_db),
):
    return await AdminService.list_users(db, q, limit, offset)


@router.post("/users/{username}/ban")
async def ban_user(
    username: str,
    admin: User = Depends(require_admin),
    db: AsyncSession = Depends(get_db),
):
    return await AdminService.set_banned(db, admin, username, True)


@router.post("/users/{username}/unban")
async def unban_user(
    username: str,
    admin: User = Depends(require_admin),
    db: AsyncSession = Depends(get_db),
):
    return await AdminService.set_banned(db, admin, username, False)


# ── Teach & Earn moderation ─────────────────────────────────────────────────
@router.get("/teachers")
async def list_teachers(
    q: str | None = Query(None),
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    admin: User = Depends(require_admin),
    db: AsyncSession = Depends(get_db),
):
    return await AdminService.list_teachers(db, q, limit, offset)


@router.post("/teachers/{username}/verify")
async def verify_teacher(
    username: str,
    admin: User = Depends(require_admin),
    db: AsyncSession = Depends(get_db),
):
    return await AdminService.set_teacher_verified(db, username, True)


@router.post("/teachers/{username}/unverify")
async def unverify_teacher(
    username: str,
    admin: User = Depends(require_admin),
    db: AsyncSession = Depends(get_db),
):
    return await AdminService.set_teacher_verified(db, username, False)


@router.get("/withdrawals")
async def list_withdrawals(
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    admin: User = Depends(require_admin),
    db: AsyncSession = Depends(get_db),
):
    return await AdminService.list_withdrawals(db, limit, offset)


@router.post("/withdrawals/{withdrawal_id}/mark-paid")
async def mark_withdrawal_paid(
    withdrawal_id: str,
    admin: User = Depends(require_admin),
    db: AsyncSession = Depends(get_db),
):
    return await AdminService.mark_withdrawal_paid(db, withdrawal_id)


# ── Finance ──────────────────────────────────────────────────────────────────
@router.get("/finance")
async def finance(
    admin: User = Depends(require_admin),
    db: AsyncSession = Depends(get_db),
):
    return await AdminService.finance(db)


# ── Communities ──────────────────────────────────────────────────────────────
@router.get("/communities")
async def list_communities(
    admin: User = Depends(require_admin),
    db: AsyncSession = Depends(get_db),
):
    return await AdminService.list_communities(db)


# ── Content moderation ───────────────────────────────────────────────────────
@router.get("/content/recent")
async def recent_content(
    limit: int = Query(40, ge=1, le=200),
    admin: User = Depends(require_admin),
    db: AsyncSession = Depends(get_db),
):
    return await AdminService.recent_content(db, limit)
