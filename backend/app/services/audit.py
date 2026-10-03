"""Append-only audit trail. Writes are hash-chained so deletion is detectable."""
from __future__ import annotations

import json
from datetime import datetime, timezone
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.security import GENESIS, audit_digest, verify_audit_chain
from app.models.entities import AuditLog

CHAINED_FIELDS = ("actor_id", "actor_username", "action", "entity_type",
                  "entity_id", "detail_json", "ip_address", "occurred_at")


def _chained_event(obj: Any) -> dict[str, Any]:
    """Builds the dict of fields that get hashed - used identically by
    record() (from an in-memory, just-flushed ORM object) and verify() (from
    a freshly re-queried one), which matters more than it looks: SQLite does
    not actually preserve a timezone-aware DateTime. `occurred_at` is written
    as an aware `datetime.now(timezone.utc)` value, but a fresh SELECT reads
    it back *naive* (a documented SQLAlchemy+SQLite limitation - the offset
    is silently dropped on round-trip). `str()` of the same instant differs
    between the two ('...+00:00' vs no suffix), so hashing the raw object
    made every single row disagree with itself the moment it was re-queried
    - found by the first real pytest run, where even one freshly-created,
    untampered audit entry reported "intact: False". Normalizing to a
    canonical UTC ISO string here, before hashing, removes the discrepancy
    regardless of which side of a database round-trip the value is on.
    """
    event: dict[str, Any] = {}
    for f in CHAINED_FIELDS:
        v = getattr(obj, f)
        if isinstance(v, datetime):
            v = (v if v.tzinfo else v.replace(tzinfo=timezone.utc)).astimezone(timezone.utc).isoformat()
        event[f] = v
    return event


async def record(session: AsyncSession, *, action: str, actor_id: str | None = None,
                 actor_username: str = "", entity_type: str = "", entity_id: str = "",
                 detail: dict[str, Any] | None = None, ip: str = "",
                 user_agent: str = "") -> AuditLog:
    last = (await session.execute(
        select(AuditLog).order_by(AuditLog.sequence.desc()).limit(1))).scalar_one_or_none()
    prev = last.hash if last else GENESIS

    entry = AuditLog(
        # `sequence` has autoincrement=True in the model, but that is a
        # no-op here: SQLite only auto-populates an INTEGER column when it
        # IS the table's own rowid (i.e. the primary key), and this table's
        # primary key is `id` (a UUID string), not `sequence`. Without this
        # explicit assignment, every insert here hit a NOT NULL constraint
        # violation - on every single audit-logged action, including login,
        # since this function runs on every one. Found by the first real
        # pytest run: nearly every authenticated test failed with a wrapped
        # 503 "database error occurred", because logging in itself calls
        # this function. Computed in Python rather than left to the DB,
        # since SQLite has no portable equivalent to a real sequence object
        # for a non-rowid column; the UniqueConstraint on `sequence` still
        # catches a concurrent double-assignment rather than silently
        # corrupting the chain, but a real multi-writer deployment should
        # revisit this with row-level locking if audit volume ever
        # warrants it.
        sequence=(last.sequence + 1 if last else 1),
        actor_id=actor_id, actor_username=actor_username, action=action,
        entity_type=entity_type, entity_id=entity_id,
        detail_json=json.dumps(detail or {}, default=str, sort_keys=True),
        ip_address=ip, user_agent=user_agent[:255], prev_hash=prev, hash="",
    )
    session.add(entry)
    await session.flush()          # populates occurred_at (server-defaulted)
    entry.hash = audit_digest(prev, _chained_event(entry))
    await session.flush()
    return entry


async def verify(session: AsyncSession) -> dict[str, Any]:
    rows = (await session.execute(select(AuditLog).order_by(AuditLog.sequence))).scalars().all()
    payload = [{**_chained_event(r), "hash": r.hash, "prev_hash": r.prev_hash} for r in rows]
    intact, broken = verify_audit_chain(payload)
    return {
        "intact": intact,
        "entries": len(rows),
        "first_broken_sequence": rows[broken].sequence if broken is not None else None,
        "detail": "Audit chain verified" if intact else
                  "TAMPER DETECTED - an entry has been altered or removed. "
                  "Preserve the database file and escalate to the system authority.",
    }
