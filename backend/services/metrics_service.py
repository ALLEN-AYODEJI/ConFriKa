"""Lightweight event counters for the admin dashboard's reach metrics.

A public beacon increments named counters (website pageviews, app opens, browser
extension opens). These are real, first-party counts — they start at zero and
grow from the moment tracking ships. External store/analytics numbers (Play
installs, Vercel Analytics) are not pulled in here; where a proxy is shown the
admin UI labels it as such (e.g. "installs" = registered devices).
"""
from typing import Dict

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..database.models import MetricCounter

# Only these event kinds may be incremented by the public beacon.
ALLOWED_KINDS = {"web_pageview", "app_open", "ext_open"}


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
