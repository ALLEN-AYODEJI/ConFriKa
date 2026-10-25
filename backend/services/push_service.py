"""Push notifications via Firebase Cloud Messaging (HTTP v1).

Used to alert a user of a new direct message or an incoming call even when the
app is closed — the "notify like a phone call" requirement. Standard library
only (urllib + PyJWT, both already present). When FCM isn't configured the
service runs in STUB mode: device tokens are still registered and sends are
logged, so delivery can be wired and flipped on the moment the Firebase
service-account JSON is provided.
"""
from __future__ import annotations

import asyncio
import json
import logging
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Iterable, Optional

import jwt  # PyJWT (already used for auth)

from ..config.settings import settings

logger = logging.getLogger("confrika.push")

_SCOPE = "https://www.googleapis.com/auth/firebase.messaging"
_TIMEOUT = 15


class _Token:
    value: Optional[str] = None
    expires_at: float = 0.0


_cached = _Token()


def _service_account() -> Optional[dict]:
    try:
        with open(settings.FCM_CREDENTIALS_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception as e:
        logger.error("Cannot read FCM credentials file: %s", e)
        return None


def _access_token() -> Optional[str]:
    """Mint (and cache) an OAuth token from the service account for FCM."""
    now = time.time()
    if _cached.value and now < _cached.expires_at - 60:
        return _cached.value
    sa = _service_account()
    if not sa:
        return None
    token_uri = sa.get("token_uri", "https://oauth2.googleapis.com/token")
    assertion = jwt.encode(
        {
            "iss": sa["client_email"],
            "scope": _SCOPE,
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
    except Exception as e:
        logger.error("FCM token exchange failed: %s", e)
        return None


class PushService:
    @classmethod
    async def notify(
        cls,
        tokens: Iterable[str],
        *,
        title: str,
        body: str,
        data: Optional[dict] = None,
        notification: bool = True,
    ) -> int:
        """Send a notification to each device token. Returns the count sent.
        Runs the blocking HTTP off the event loop.

        ``notification=False`` sends a DATA-ONLY high-priority message (no tray
        notification) so the app's background handler runs — used for incoming
        calls, which must wake the app and show the native ringing UI rather
        than a silent notification."""
        toks = [t for t in tokens if t]
        if not toks:
            return 0
        if not settings.fcm_configured:
            logger.info("[push:stub] %s → %r / %r", len(toks), title, body)
            return 0
        return await asyncio.to_thread(
            cls._send_all, toks, title, body, data or {}, notification
        )

    @classmethod
    async def notify_username(
        cls, db, username: str, *, title: str, body: str,
        data: Optional[dict] = None, notification: bool = True,
    ) -> int:
        """Look up a user's registered device tokens and notify all of them."""
        from sqlalchemy import select
        from ..database.models import DeviceToken, User

        user = await db.scalar(select(User).where(User.username == username))
        if user is None:
            return 0
        tokens = (
            await db.scalars(select(DeviceToken.token).where(DeviceToken.user_id == user.id))
        ).all()
        return await cls.notify(
            tokens, title=title, body=body, data=data, notification=notification
        )

    @classmethod
    def _send_all(cls, tokens, title, body, data, notification=True) -> int:
        access = _access_token()
        if not access:
            return 0
        url = (
            f"https://fcm.googleapis.com/v1/projects/"
            f"{settings.FCM_PROJECT_ID}/messages:send"
        )
        sent = 0
        # FCM v1 sends one token per request.
        for tok in tokens:
            message = {
                "token": tok,
                "data": {k: str(v) for k, v in data.items()},
                # FCM v1 AndroidConfig.priority is an uppercase enum.
                "android": {"priority": "HIGH"},
            }
            # Data-only (no notification block) lets the app's background handler
            # run for incoming calls; otherwise the OS just shows a tray entry.
            if notification:
                message["notification"] = {"title": title, "body": body}
            payload = {"message": message}
            try:
                req = urllib.request.Request(
                    url,
                    data=json.dumps(payload).encode(),
                    headers={
                        "Authorization": f"Bearer {access}",
                        "Content-Type": "application/json",
                    },
                    method="POST",
                )
                with urllib.request.urlopen(req, timeout=_TIMEOUT) as resp:
                    if 200 <= resp.status < 300:
                        sent += 1
            except urllib.error.HTTPError as e:
                logger.warning("FCM send failed (%s): %s", e.code, e.read()[:300])
            except Exception as e:
                logger.warning("FCM send failed for a token: %s", e)
        return sent
