"""In-process presence registry.

Tracks which users are currently reachable — either through an active WebSocket
connection, or via a recent heartbeat ping from an open app. All access happens
from the single asyncio event-loop thread, so plain dicts are safe.

For a multi-worker / multi-node deployment this is the seam where a Redis-backed
presence set would be plugged in (see REDIS_URL in settings).
"""
import time
from typing import Dict, Set

# WebSocket connection counts (chat/calls sockets).
_connection_counts: Dict[str, int] = {}
# Last heartbeat time per user (monotonic seconds) — lets an app that is open
# but not on a socket-backed screen still count as online.
_last_seen: Dict[str, float] = {}

# A heartbeat keeps a user "online" for this long. The client pings well within
# this window (every ~30s), so a couple of missed pings still count as online.
_TTL_SECONDS = 75.0


def mark_online(username: str) -> None:
    _connection_counts[username] = _connection_counts.get(username, 0) + 1
    _last_seen[username] = time.monotonic()


def mark_offline(username: str) -> None:
    count = _connection_counts.get(username, 0) - 1
    if count <= 0:
        _connection_counts.pop(username, None)
    else:
        _connection_counts[username] = count


def heartbeat(username: str) -> None:
    """Record that an open app checked in (used for the online/calling state)."""
    _last_seen[username] = time.monotonic()


def is_online(username: str) -> bool:
    if _connection_counts.get(username, 0) > 0:
        return True
    ts = _last_seen.get(username)
    return ts is not None and (time.monotonic() - ts) < _TTL_SECONDS


def online_usernames() -> Set[str]:
    now = time.monotonic()
    users: Set[str] = set(_connection_counts.keys())
    users |= {u for u, ts in _last_seen.items() if now - ts < _TTL_SECONDS}
    return users


def online_count() -> int:
    """Number of distinct users currently reachable."""
    return len(online_usernames())
