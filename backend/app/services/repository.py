"""Data access for components, plus the shared in-memory match index.

The index is rebuilt on startup and whenever an import commits or a component is
edited. At 200 rows this is instant; the `refresh` hook is where an incremental
update or a switch to SQL-backed lookup would go for a 1M-row catalogue.
"""
from __future__ import annotations

import asyncio
import json
import logging
from datetime import datetime, timezone
from typing import Any

from sqlalchemy import func, or_, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.entities import Component, ComponentRevision, utcnow
from app.services.matching import ComponentIndex, normalize

log = logging.getLogger(__name__)

INDEXED_COLUMNS = ["component_id", "component_name", "part_number", "chip_number",
                   "search_key", "manufacturer", "manufacturer_country",
                   "country_of_origin", "is_chinese", "category", "drone_subsystem",
                   "criticality", "criticality_policy", "alternative_manufacturer",
                   "military_grade", "barcode", "qr_code", "function", "remarks",
                   "image_path", "datasheet_url", "supplier", "verified_by",
                   "verification_source", "confidence_score"]


class IndexCache:
    """Single shared index with a read-write lock held only during a swap."""

    def __init__(self) -> None:
        self._index = ComponentIndex([])
        self._revision = 0
        self._lock = asyncio.Lock()
        self._built_at: datetime | None = None

    @property
    def index(self) -> ComponentIndex:
        return self._index

    @property
    def revision(self) -> int:
        return self._revision

    async def rebuild(self, session: AsyncSession) -> int:
        async with self._lock:
            rows = (await session.execute(
                select(*[getattr(Component, c) for c in INDEXED_COLUMNS])
                .where(Component.is_deleted.is_(False)))).all()
            payload = [dict(zip(INDEXED_COLUMNS, r)) for r in rows]
            self._index = ComponentIndex(payload)
            self._revision += 1
            self._built_at = datetime.now(timezone.utc)
            log.info("component index rebuilt: %d rows, revision %d",
                     len(payload), self._revision)
            return len(payload)

    def stats(self) -> dict[str, Any]:
        return {"rows": len(self._index.rows), "revision": self._revision,
                "built_at": self._built_at.isoformat() if self._built_at else None}


cache = IndexCache()


# --------------------------------------------------------------------------- #
async def get_by_component_id(session: AsyncSession, component_id: str) -> Component | None:
    return (await session.execute(
        select(Component).where(Component.component_id == component_id,
                                Component.is_deleted.is_(False)))).scalar_one_or_none()


async def existing_map(session: AsyncSession) -> dict[str, dict]:
    rows = (await session.execute(
        select(*[getattr(Component, c) for c in INDEXED_COLUMNS])
        .where(Component.is_deleted.is_(False)))).all()
    return {r[0]: dict(zip(INDEXED_COLUMNS, r)) for r in rows}


async def snapshot(session: AsyncSession, comp: Component, operation: str,
                   changed: list[str], actor_id: str | None,
                   batch_id: str | None = None) -> None:
    """Record a full row snapshot. This is what makes rollback and diff possible."""
    payload = {c.name: getattr(comp, c.name) for c in Component.__table__.columns}
    session.add(ComponentRevision(
        component_pk=comp.id, component_id=comp.component_id, revision=comp.revision,
        operation=operation, snapshot_json=json.dumps(payload, default=str),
        changed_fields=json.dumps(changed), batch_id=batch_id, actor_id=actor_id))


async def search(session: AsyncSession, *, q: str = "", country: str = "",
                 manufacturer: str = "", subsystem: str = "", category: str = "",
                 is_chinese: str = "", criticality: str = "", pending: bool | None = None,
                 page: int = 1, page_size: int = 50,
                 order: str = "component_name") -> tuple[list[Component], int]:
    stmt = select(Component).where(Component.is_deleted.is_(False))

    if q:
        like = f"%{q.strip()}%"
        key = normalize(q)
        clauses = [Component.component_name.ilike(like),
                   Component.part_number.ilike(like),
                   Component.chip_number.ilike(like),
                   Component.manufacturer.ilike(like),
                   Component.remarks.ilike(like),
                   Component.barcode.ilike(like),
                   Component.supplier.ilike(like)]
        if key:
            clauses.append(Component.search_key.like(f"{key}%"))
        stmt = stmt.where(or_(*clauses))

    for column, value in ((Component.country_of_origin, country),
                          (Component.manufacturer, manufacturer),
                          (Component.drone_subsystem, subsystem),
                          (Component.category, category),
                          (Component.is_chinese, is_chinese),
                          (Component.criticality, criticality)):
        if value:
            stmt = stmt.where(column == value)
    if pending is not None:
        stmt = stmt.where(Component.pending_verification.is_(pending))

    total = (await session.execute(
        select(func.count()).select_from(stmt.subquery()))).scalar_one()

    col = getattr(Component, order, Component.component_name)
    stmt = stmt.order_by(col).offset((max(page, 1) - 1) * page_size).limit(page_size)
    return list((await session.execute(stmt)).scalars().all()), total


async def facets(session: AsyncSession) -> dict[str, list[dict]]:
    """Filter dropdown values, with counts, computed from live data."""
    out: dict[str, list[dict]] = {}
    for name, col in (("country_of_origin", Component.country_of_origin),
                      ("manufacturer", Component.manufacturer),
                      ("drone_subsystem", Component.drone_subsystem),
                      ("category", Component.category),
                      ("criticality", Component.criticality)):
        rows = (await session.execute(
            select(col, func.count()).where(Component.is_deleted.is_(False))
            .group_by(col).order_by(func.count().desc()))).all()
        out[name] = [{"value": v or "(blank)", "count": c} for v, c in rows]
    return out


async def soft_delete(session: AsyncSession, component_id: str, actor_id: str) -> bool:
    comp = await get_by_component_id(session, component_id)
    if comp is None:
        return False
    await snapshot(session, comp, "delete", ["is_deleted"], actor_id)
    comp.is_deleted = True
    comp.revision += 1
    comp.updated_at = utcnow()
    return True


async def bulk_update(session: AsyncSession, component_ids: list[str],
                      changes: dict[str, Any], actor_id: str) -> int:
    allowed = {"drone_subsystem", "category", "criticality", "verified_by",
               "verification_source", "alternative_manufacturer", "military_grade",
               "supplier", "pending_verification"}
    bad = set(changes) - allowed
    if bad:
        raise ValueError(f"Fields not permitted in a bulk update: {', '.join(sorted(bad))}. "
                         f"Origin and identity fields must be edited row by row so that "
                         f"each change carries its own justification.")
    rows = (await session.execute(
        select(Component).where(Component.component_id.in_(component_ids)))).scalars().all()
    for comp in rows:
        await snapshot(session, comp, "update", list(changes), actor_id)
        for k, v in changes.items():
            setattr(comp, k, v)
        comp.revision += 1
        comp.updated_at = utcnow()
    return len(rows)


async def dashboard_counts(session: AsyncSession) -> dict[str, int]:
    base = Component.is_deleted.is_(False)
    async def count(*where):
        return (await session.execute(
            select(func.count()).select_from(Component).where(base, *where))).scalar_one()
    return {
        "total_components": await count(),
        "chinese_components": await count(Component.is_chinese == "YES"),
        "non_chinese_components": await count(Component.is_chinese == "NO"),
        "unknown_origin": await count(Component.is_chinese == "UNKNOWN"),
        "pending_verification": await count(Component.pending_verification.is_(True)),
        "critical_chinese": await count(Component.is_chinese == "YES",
                                        Component.criticality == "CRITICAL"),
    }
