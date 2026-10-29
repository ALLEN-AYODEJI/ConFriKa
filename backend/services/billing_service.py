"""Monetization: ConFriKa Pro entitlement + store purchase verification.

Model: ads + freemium. Free users see ads and are capped by the free-tier
limits in settings; ConFriKa Pro removes ads and lifts every limit. Entitlement
is driven by a store subscription (Google Play on Android), verified server-side
against the Play Developer API before Pro is granted.
"""
from __future__ import annotations

import json
import logging
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from typing import Any, Dict, Optional

import jwt  # PyJWT (already used for auth + FCM)
from fastapi import HTTPException, status
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from ..config.settings import settings
from ..database.models import CommunityMembership, RevenueEvent, User
from . import usage_service

logger = logging.getLogger("confrika.billing")

_PLAY_SCOPE = "https://www.googleapis.com/auth/androidpublisher"
_TOKEN_URI = "https://oauth2.googleapis.com/token"
_TIMEOUT = 15


def _now() -> datetime:
    return datetime.now(timezone.utc)


def is_pro(user: User) -> bool:
    """True when the user has an active (non-expired) Pro subscription."""
    if (user.subscription_tier or "free") != "pro":
        return False
    exp = user.subscription_expires_at
    if exp is None:
        return True  # no expiry recorded => treat as active
    if exp.tzinfo is None:
        exp = exp.replace(tzinfo=timezone.utc)
    return exp > _now()


def limits_for(user: User) -> Dict[str, Any]:
    """The effective limits for this user (unlimited = -1 when Pro)."""
    if is_pro(user):
        return {
            "daily_translations": -1,
            "daily_call_seconds": -1,
            "max_communities": -1,
            "can_create_communities": True,
            "voice_clone": True,
            "show_ads": False,
        }
    return {
        "daily_translations": settings.FREE_DAILY_TRANSLATIONS,
        "daily_call_seconds": settings.FREE_DAILY_CALL_SECONDS,
        "max_communities": settings.FREE_MAX_COMMUNITIES,
        "can_create_communities": settings.FREE_CAN_CREATE_COMMUNITIES,
        "voice_clone": settings.FREE_VOICE_CLONE,
        "show_ads": settings.ADS_ENABLED,
    }


_UPGRADE = "Upgrade to ConFriKa Pro for unlimited access."

# resource -> (settings attribute holding the free limit, human label)
_QUOTA = {
    "translations": ("FREE_DAILY_TRANSLATIONS", "translations"),
    "call_seconds": ("FREE_DAILY_CALL_SECONDS", "translated call minutes"),
}


async def enforce(user: User, resource: str, amount: int = 1) -> None:
    """Consume free-tier quota for ``resource``; raise 402 when exhausted.

    Pro users are never limited. Fails open on infra errors (see usage_service).
    """
    if is_pro(user):
        return
    attr, label = _QUOTA[resource]
    limit = int(getattr(settings, attr))
    allowed, _remaining = await usage_service.consume(user.id, resource, amount, limit)
    if not allowed:
        raise HTTPException(
            status.HTTP_402_PAYMENT_REQUIRED,
            f"You've reached today's free {label} limit. {_UPGRADE}",
        )


def require_pro(user: User, feature: str) -> None:
    """Raise 402 unless the user is Pro. ``feature`` names the gated capability."""
    if not is_pro(user):
        raise HTTPException(
            status.HTTP_402_PAYMENT_REQUIRED,
            f"{feature} is a ConFriKa Pro feature. {_UPGRADE}",
        )


async def entitlements(db: AsyncSession, user: User) -> Dict[str, Any]:
    """Full entitlement snapshot for the client (tier, limits, usage, products)."""
    pro = is_pro(user)
    joined = await db.scalar(
        select(func.count(CommunityMembership.id)).where(
            CommunityMembership.user_id == user.id
        )
    ) or 0
    lims = limits_for(user)
    exp = user.subscription_expires_at
    return {
        "tier": "pro" if pro else "free",
        "is_pro": pro,
        "show_ads": lims["show_ads"],
        "subscription_expires_at": exp.isoformat() if exp else None,
        "limits": lims,
        "usage": {
            "translations_today": await usage_service.peek(user.id, "translations"),
            "call_seconds_today": await usage_service.peek(user.id, "call_seconds"),
            "communities_joined": joined,
        },
        "products": [
            {"id": "confrika_pro_monthly", "period": "P1M", "label": "ConFriKa Pro (Monthly)"},
            {"id": "confrika_pro_yearly", "period": "P1Y", "label": "ConFriKa Pro (Yearly)"},
        ],
    }


# --------------------------------------------------------------------------- #
# Google Play purchase verification
# --------------------------------------------------------------------------- #
class _Token:
    value: Optional[str] = None
    expires_at: float = 0.0


_cached = _Token()


def _service_account() -> Optional[dict]:
    try:
        with open(settings.PLAY_SERVICE_ACCOUNT_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception as e:  # pragma: no cover - config/env dependent
        logger.error("Cannot read Play service-account file: %s", e)
        return None


def _play_access_token() -> Optional[str]:
    now = time.time()
    if _cached.value and now < _cached.expires_at - 60:
        return _cached.value
    sa = _service_account()
    if not sa:
        return None
    token_uri = sa.get("token_uri", _TOKEN_URI)
    assertion = jwt.encode(
        {
            "iss": sa["client_email"],
            "scope": _PLAY_SCOPE,
            "aud": token_uri,
            "iat": int(now),
            "exp": int(now) + 3600,
        },
        sa["private_key"],
        algorithm="RS256",
    )
    data = urllib.parse.urlencode({
        "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion": assertion,
    }).encode()
    try:
        req = urllib.request.Request(
            token_uri, data=data,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=_TIMEOUT) as resp:
            body = json.loads(resp.read())
        _cached.value = body["access_token"]
        _cached.expires_at = now + int(body.get("expires_in", 3600))
        return _cached.value
    except Exception as e:  # pragma: no cover
        logger.error("Play token exchange failed: %s", e)
        return None


def _verify_play_subscription(product_id: str, token: str) -> Optional[datetime]:
    """Verify a Play subscription purchase. Returns the expiry datetime or None.

    Uses the Purchases.subscriptions endpoint of the Android Publisher API.
    """
    access = _play_access_token()
    if not access:
        return None
    pkg = urllib.parse.quote(settings.PLAY_PACKAGE_NAME)
    sku = urllib.parse.quote(product_id)
    tok = urllib.parse.quote(token)
    url = (
        f"https://androidpublisher.googleapis.com/androidpublisher/v3/"
        f"applications/{pkg}/purchases/subscriptions/{sku}/tokens/{tok}"
    )
    try:
        req = urllib.request.Request(
            url, headers={"Authorization": f"Bearer {access}"}, method="GET"
        )
        with urllib.request.urlopen(req, timeout=_TIMEOUT) as resp:
            body = json.loads(resp.read())
        expiry_ms = int(body.get("expiryTimeMillis", 0))
        if expiry_ms <= 0:
            return None
        return datetime.fromtimestamp(expiry_ms / 1000.0, tz=timezone.utc)
    except Exception as e:  # pragma: no cover
        logger.error("Play subscription verification failed: %s", e)
        return None


async def verify_and_apply(
    db: AsyncSession,
    user: User,
    platform: str,
    product_id: str,
    token: str,
) -> Dict[str, Any]:
    """Verify a store purchase and grant Pro on success.

    Google Play is verified against the Play Developer API. If Play is not
    configured, the purchase is rejected unless BILLING_TRUST_UNVERIFIED is set
    (dev/testing only).
    """
    if product_id not in settings.pro_product_ids:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Unknown product.")

    expires: Optional[datetime] = None
    if platform == "google_play" and settings.play_configured:
        expires = _verify_play_subscription(product_id, token)
        if expires is None or expires <= _now():
            raise HTTPException(
                status.HTTP_402_PAYMENT_REQUIRED,
                "Could not verify an active subscription for this purchase.",
            )
    elif settings.BILLING_TRUST_UNVERIFIED:
        # Dev escape hatch: grant 30 days without server-side verification.
        logger.warning("Granting Pro WITHOUT verification (BILLING_TRUST_UNVERIFIED).")
        from datetime import timedelta
        expires = _now() + timedelta(days=30)
    else:
        raise HTTPException(
            status.HTTP_501_NOT_IMPLEMENTED,
            "Purchase verification is not configured on the server.",
        )

    user.subscription_tier = "pro"
    user.subscription_platform = platform
    user.subscription_product_id = product_id
    user.subscription_token = token
    user.subscription_expires_at = expires
    # Record recognised revenue for this verified purchase (feeds admin Finance).
    price = (
        settings.PRO_YEARLY_PRICE_CENTS
        if "year" in product_id.lower()
        else settings.PRO_MONTHLY_PRICE_CENTS
    )
    db.add(RevenueEvent(
        user_id=user.id, product_id=product_id, platform=platform,
        amount_cents=int(price), currency=settings.REVENUE_CURRENCY,
    ))
    await db.commit()
    await db.refresh(user)
    return await entitlements(db, user)
