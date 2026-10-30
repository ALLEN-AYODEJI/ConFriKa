"""Lightweight event counters for the admin dashboard's reach metrics.

A public beacon increments named counters (website pageviews, app opens, browser
extension opens). These are real, first-party counts — they start at zero and
grow from the moment tracking ships. External store/analytics numbers (Play
installs, Vercel Analytics) are not pulled in here; where a proxy is shown the
admin UI labels it as such (e.g. "installs" = registered devices).
"""
from typing import Dict, Optional

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..database.models import ExtensionInstall, MetricCounter, User, _utcnow

# Only these event kinds may be incremented by the public beacon.
ALLOWED_KINDS = {"web_pageview", "app_open", "ext_open"}

# Browser-extension lifecycle events the extension may report.
EXT_EVENTS = {"register", "open", "recognize"}


class MetricsService:
    @staticmethod
    async def hit(db: AsyncSession, kind: str) -> bool:
        """Increment one counter. Ignores unknown kinds (returns False)."""
        if kind not in ALLOWED_KINDS:
            return False
        row = await db.get(MetricCounter, kind)
        if row is None:
            db.add(MetricCounter(name=kind, count=1))
        else:
            row.count = (row.count or 0) + 1
        await db.commit()
        return True

    @staticmethod
    async def snapshot(db: AsyncSession) -> Dict[str, int]:
        rows = (await db.execute(select(MetricCounter))).scalars().all()
        data = {r.name: int(r.count or 0) for r in rows}
        return {k: data.get(k, 0) for k in ALLOWED_KINDS}

    @staticmethod
    async def ext_event(
        db: AsyncSession,
        install_id: str,
        event: str,
        version: Optional[str] = None,
        user: Optional[User] = None,
    ) -> bool:
        """Record a browser-extension lifecycle event against its install row.

        Upserts the ``ExtensionInstall`` keyed by ``install_id``, refreshes
        ``last_seen``, attaches the signed-in user (if any), and bumps the
        relevant usage counter. Unknown events / blank ids are ignored."""
        install_id = (install_id or "").strip()[:64]
        if not install_id or event not in EXT_EVENTS:
            return False
        now = _utcnow()
        row = await db.get(ExtensionInstall, install_id)
        if row is None:
            row = ExtensionInstall(install_id=install_id, first_seen=now)
            db.add(row)
        row.last_seen = now
        if version:
            row.version = str(version)[:20]
        if user is not None:
            row.user_id = user.id
            row.user_email = user.email
        if event == "open":
            row.open_count = (row.open_count or 0) + 1
        elif event == "recognize":
            row.recognize_count = (row.recognize_count or 0) + 1
        # Keep the aggregate Overview "ext_opens" tile meaningful.
        if event in ("register", "open"):
            counter = await db.get(MetricCounter, "ext_open")
            if counter is None:
                db.add(MetricCounter(name="ext_open", count=1))
            else:
                counter.count = (counter.count or 0) + 1
        await db.commit()
        return True
