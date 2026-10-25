import base64
import hashlib
import hmac
import logging
import time
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

from fastapi import HTTPException, status
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..config.settings import settings
from ..database.models import CallSession, User
from . import presence
from .privacy_service import reachability_block
from .push_service import PushService

logger = logging.getLogger("confrika.calls")


def build_ice_servers() -> List[Dict[str, Any]]:
    """Return ICE servers with time-limited TURN credentials (coturn REST auth)."""
    servers: List[Dict[str, Any]] = [{"urls": [settings.STUN_URL]}]
    if settings.TURN_HOST and settings.TURN_SECRET:
        expiry = int(time.time()) + settings.TURN_TTL_SECONDS
        username = str(expiry)
        digest = hmac.new(
            settings.TURN_SECRET.encode("utf-8"), username.encode("utf-8"), hashlib.sha1
        ).digest()
        credential = base64.b64encode(digest).decode("utf-8")
        servers.append(
            {
                "urls": [
                    f"turn:{settings.TURN_HOST}:{settings.TURN_PORT}?transport=udp",
                    f"turn:{settings.TURN_HOST}:{settings.TURN_PORT}?transport=tcp",
                ],
                "username": username,
                "credential": credential,
            }
        )
    return servers


class InitiateCallRequest(BaseModel):
    callee_username: str
    call_transport: str = "inapp"  # 'inapp' or 'telecom'
    sdp_offer: Optional[str] = None


class CallSignalMessage(BaseModel):
    session_id: str
    sender_username: str
    target_username: str
    signal_type: str  # 'offer', 'answer', 'candidate', 'hangup', 'reject'
    payload: Dict[str, Any]


class CallSignalingService:
    ACTIVE_SESSIONS: Dict[str, Dict[str, Any]] = {}

    @classmethod
    async def initiate_call(
        cls, db: AsyncSession, caller: User, req: InitiateCallRequest
    ) -> Dict[str, Any]:
        callee_handle = req.callee_username.strip().lower()
        if not callee_handle.startswith("@"):
            callee_handle = "@" + callee_handle

        if req.call_transport == "telecom":
            return {
                "status": "coming_soon",
                "message": "No-App (PSTN) calling is not available yet. Please use In-App Call.",
                "call_transport": "telecom",
            }

        # Respect the callee's reachability setting (anti-unwanted-calls).
        callee = await db.scalar(select(User).where(User.username == callee_handle))
        if callee is not None and callee.id != caller.id:
            block = await reachability_block(db, callee, caller.username, "call")
            if block:
                raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=block)

        session = CallSession(
            caller_id=caller.id,
            caller_username=caller.username,
            callee_username=callee_handle,
            call_transport="inapp",
            status="ringing",
        )
        db.add(session)
        await db.commit()
        await db.refresh(session)

        session_data = {
            "session_id": session.id,
            "caller_username": caller.username,
            "caller_name": caller.full_name,
            "callee_username": callee_handle,
            "status": "ringing",
            "sdp_offer": req.sdp_offer,
            "created_at": datetime.now(timezone.utc).isoformat(),
        }
        cls.ACTIVE_SESSIONS[session.id] = session_data

        # Ring the callee: send a high-priority push so their phone shows the
        # incoming-call screen even if the app is backgrounded. Best-effort —
        # a push failure must not fail the caller's initiate request.
        try:
            caller_name = caller.full_name or caller.username
            await PushService.notify_username(
                db,
                callee_handle,
                title="Incoming call",
                body=f"{caller_name} is calling you",
                data={
                    "type": "incoming_call",
                    "from_user": caller.username,
                    "from_name": caller_name,
                    "session_id": session.id,
                },
                # Data-only so the callee's app wakes and shows the ringing UI
                # (CallKit) instead of a silent tray notification.
                notification=False,
            )
        except Exception as exc:  # pragma: no cover - best effort
            logger.warning("Incoming-call push failed for %s: %s", callee_handle, exc)

        # "ringing" when the callee is reachable (app open / connected) so the
        # caller shows "Ringing…"; otherwise "calling" → caller shows "Calling…"
        # while the push tries to wake them.
        callee_online = presence.is_online(callee_handle)
        return {
            "session_id": session.id,
            "status": "ringing" if callee_online else "calling",
            "callee_online": callee_online,
            "caller": caller.username,
            "callee": callee_handle,
            "call_transport": "inapp",
        }

    @classmethod
    async def answer_call(
        cls, db: AsyncSession, session_id: str, sdp_answer: str
    ) -> Dict[str, Any]:
        session_data = cls.ACTIVE_SESSIONS.get(session_id)
        if session_data:
            session_data["status"] = "connected"
            session_data["sdp_answer"] = sdp_answer
            session_data["connected_at"] = datetime.now(timezone.utc).isoformat()

        return {
            "session_id": session_id,
            "status": "connected",
            "sdp_answer": sdp_answer,
        }

    @classmethod
    async def end_call(cls, db: AsyncSession, session_id: str) -> Dict[str, Any]:
        session_data = cls.ACTIVE_SESSIONS.pop(session_id, None)
        return {
            "session_id": session_id,
            "status": "ended",
        }

    @classmethod
    async def record_outcome(
        cls, db: AsyncSession, session_id: str, connected: bool, duration_seconds: int
    ) -> Dict[str, Any]:
        """Persist how a call ended so it shows in call history / missed calls."""
        cls.ACTIVE_SESSIONS.pop(session_id, None)
        session = await db.get(CallSession, session_id)
        if session is not None:
            now = datetime.now(timezone.utc).replace(tzinfo=None)
            session.status = "ended" if connected else "missed"
            session.ended_at = now
            session.duration_seconds = max(0, int(duration_seconds))
            if connected and session.connected_at is None:
                session.connected_at = now
            await db.commit()
        return {"status": "recorded"}

    @classmethod
    async def history(cls, db: AsyncSession, user: User, limit: int = 50) -> List[Dict[str, Any]]:
        from sqlalchemy import or_, select
        rows = (
            await db.scalars(
                select(CallSession)
                .where(or_(
                    CallSession.caller_username == user.username,
                    CallSession.callee_username == user.username,
                ))
                .order_by(CallSession.started_at.desc())
                .limit(limit)
            )
        ).all()
        out = []
        for s in rows:
            outgoing = s.caller_username == user.username
            other = s.callee_username if outgoing else s.caller_username
            missed = (not outgoing) and s.status in ("ringing", "missed")
            out.append({
                "session_id": s.id,
                "other_username": other,
                "direction": "outgoing" if outgoing else "incoming",
                "status": s.status,
                "missed": missed,
                "duration_seconds": s.duration_seconds or 0,
                "started_at": s.started_at.isoformat() if s.started_at else None,
            })
        return out
