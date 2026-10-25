from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from ...database.session import get_db
from ...database.models import User, DeviceToken
from ...services.auth_service import (
    AuthService,
    SignUpRequest,
    LoginRequest,
    TokenResponse,
    OtpSentResponse,
    VerifyEmailRequest,
    EmailRequest,
    ResetPasswordRequest,
    ChangePasswordRequest,
    UpdateProfileRequest,
    UpdatePrivacyRequest,
)
from ...services.learning_stats_service import LearningStatsService
from ...services.rate_limit import rate_limit


class TonalBaselineRequest(BaseModel):
    f0_baseline_hz: float = Field(..., ge=50.0, le=500.0)


class RegisterDeviceRequest(BaseModel):
    token: str = Field(..., min_length=8, max_length=4096)
    platform: str = Field(default="android", max_length=16)

router = APIRouter(prefix="/auth", tags=["Authentication"])
security = HTTPBearer()


async def get_current_user(
    credentials: HTTPAuthorizationCredentials = Depends(security),
    db: AsyncSession = Depends(get_db),
) -> User:
    token = credentials.credentials
    payload = AuthService.decode_access_token(token)
    user_id = payload.get("sub")
    if not user_id:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Token payload missing subject identifier",
        )

    user = await db.get(User, user_id)
    if not user:
        # Fallback by username if user was seeded or created in another worker
        username = payload.get("username")
        if username:
            user = await db.scalar(select(User).where(User.username == username))
    if not user:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Authenticated user no longer exists",
        )
    if user.is_banned:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="This account has been suspended.",
        )
    return user


@router.post("/signup", response_model=OtpSentResponse, dependencies=[rate_limit("signup", 5, 60)])
async def signup(req: SignUpRequest, db: AsyncSession = Depends(get_db)):
    """Begin registration: create the account and email a verification code."""
    return await AuthService.register_user(db, req)


@router.post("/verify-email", response_model=TokenResponse, dependencies=[rate_limit("verify", 10, 60)])
async def verify_email(req: VerifyEmailRequest, db: AsyncSession = Depends(get_db)):
    """Confirm the signup email with the OTP and return the access token."""
    return await AuthService.verify_email(db, req)


@router.post("/resend-otp", response_model=OtpSentResponse, dependencies=[rate_limit("resend", 3, 60)])
async def resend_otp(req: EmailRequest, db: AsyncSession = Depends(get_db)):
    """Re-send the signup verification code."""
    return await AuthService.resend_signup_otp(db, str(req.email))


@router.post("/login", response_model=TokenResponse, dependencies=[rate_limit("login", 10, 60)])
async def login(req: LoginRequest, db: AsyncSession = Depends(get_db)):
    """Authenticate user with email address or @username."""
    return await AuthService.authenticate_user(db, req)


@router.post("/forgot-password", response_model=OtpSentResponse, dependencies=[rate_limit("forgot", 3, 60)])
async def forgot_password(req: EmailRequest, db: AsyncSession = Depends(get_db)):
    """Email a password-reset code (always returns success — no enumeration)."""
    return await AuthService.forgot_password(db, str(req.email))


@router.post("/reset-password", dependencies=[rate_limit("reset", 10, 60)])
async def reset_password(req: ResetPasswordRequest, db: AsyncSession = Depends(get_db)):
    """Reset the password using the emailed code."""
    return await AuthService.reset_password(db, req)


@router.post("/change-password/request-otp", response_model=OtpSentResponse, dependencies=[rate_limit("chpw_otp", 5, 60)])
async def request_change_password_otp(
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Email the signed-in user a one-time code to authorize a password change."""
    return await AuthService.request_change_password_otp(db, current_user)


@router.post("/change-password")
async def change_password(
    req: ChangePasswordRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Change the password for the signed-in user (requires an emailed OTP)."""
    return await AuthService.change_password(db, current_user, req)


@router.put("/me")
async def update_profile(
    req: UpdateProfileRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Update the signed-in user's profile (name, origin, dialect, country)."""
    return await AuthService.update_profile(db, current_user, req)


@router.post("/me/devices")
async def register_device(
    req: RegisterDeviceRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Register this device's push token so it can receive message/call alerts."""
    existing = await db.scalar(
        select(DeviceToken).where(DeviceToken.token == req.token)
    )
    if existing is None:
        db.add(DeviceToken(user_id=current_user.id, token=req.token, platform=req.platform))
    else:
        existing.user_id = current_user.id  # token moved to this account
        existing.platform = req.platform
    await db.commit()
    return {"status": "registered"}


@router.post("/me/presence")
async def presence_ping(current_user: User = Depends(get_current_user)):
    """Heartbeat from an open app so the user counts as online/reachable
    (drives the caller's "Ringing" vs "Calling" state)."""
    from ...services import presence
    presence.heartbeat(current_user.username)
    return {"online": True}


class DeleteAccountRequest(BaseModel):
    password: str = Field(..., min_length=1, max_length=128)


@router.post("/delete-account")
async def delete_account(
    req: DeleteAccountRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Permanently delete the signed-in user's account and their data."""
    return await AuthService.delete_account(db, current_user, req.password)


@router.put("/me/privacy")
async def update_privacy(
    req: UpdatePrivacyRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Update reachability controls: who can call/message me, and image permission."""
    return await AuthService.update_privacy(db, current_user, req)


@router.get("/me")
async def get_my_profile(current_user: User = Depends(get_current_user)):
    """Get current authenticated user profile, dialect, and voice baseline."""
    return {
        "id": current_user.id,
        "username": current_user.username,
        "email": current_user.email,
        "full_name": current_user.full_name,
        "country_code": current_user.country_code,
        "origin_region": current_user.origin_region,
        "primary_dialect": current_user.primary_dialect,
        "f0_baseline_hz": current_user.f0_baseline_hz,
        "email_verified": current_user.email_verified,
        "calls_privacy": current_user.calls_privacy,
        "messages_privacy": current_user.messages_privacy,
        "allow_images": current_user.allow_images,
        "avatar_url": current_user.avatar_url,
    }


@router.get("/me/stats")
async def get_my_stats(
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Real learning progress (streak, words learned, XP) derived from activity."""
    return await LearningStatsService.get_user_stats(db, current_user)


@router.put("/me/tonal-baseline")
async def update_tonal_baseline(
    req: TonalBaselineRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Calibrate the user's personal baseline vocal pitch (mean F0 in Hz)."""
    current_user.f0_baseline_hz = req.f0_baseline_hz
    db.add(current_user)
    await db.commit()
    return {"status": "updated", "f0_baseline_hz": current_user.f0_baseline_hz}
