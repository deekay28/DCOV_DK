"""Dashboard, analytics, report generation and audit access."""
from __future__ import annotations

from collections import Counter
from datetime import datetime, timedelta, timezone
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import Response
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_session
from app.core.security import Principal, requires
from app.models.entities import (AuditLog, Component, ImportBatch, Inspection,
                                 PendingComponent, ScanRecord)
from app.models.schemas import DashboardStats
from app.services import audit, repository, reports

router = APIRouter(tags=["insights"])


def _since(days: int) -> datetime:
    return datetime.now(timezone.utc) - timedelta(days=days)


# --------------------------------------------------------------------------- #
@router.get("/dashboard", response_model=DashboardStats)
async def dashboard(session: Annotated[AsyncSession, Depends(get_session)],
                    _: Annotated[Principal, Depends(requires("component:read"))]
                    ) -> DashboardStats:
    counts = await repository.dashboard_counts(session)

    async def scan_count(days: int, result: str | None = None) -> int:
        stmt = select(func.count()).select_from(ScanRecord).where(
            ScanRecord.scanned_at >= _since(days))
        if result:
            stmt = stmt.where(ScanRecord.result == result)
        return (await session.execute(stmt)).scalar_one()

    recent = (await session.execute(
        select(ScanRecord).order_by(ScanRecord.scanned_at.desc()).limit(10))).scalars().all()
    imports = (await session.execute(
        select(ImportBatch).where(ImportBatch.status == "committed")
        .order_by(ImportBatch.committed_at.desc()).limit(5))).scalars().all()
    alerts = (await session.execute(
        select(ScanRecord).where(ScanRecord.result == "chinese",
                                 ScanRecord.criticality == "CRITICAL")
        .order_by(ScanRecord.scanned_at.desc()).limit(10))).scalars().all()
    open_insp = (await session.execute(
        select(func.count()).select_from(Inspection)
        .where(Inspection.status == "open"))).scalar_one()

    return DashboardStats(
        **counts,
        scans_today=await scan_count(1),
        scans_7d=await scan_count(7),
        chinese_hits_7d=await scan_count(7, "chinese"),
        open_inspections=open_insp,
        recently_scanned=[{"id": r.id, "input": r.raw_input, "result": r.result,
                           "component_id": r.matched_component_id,
                           "at": r.scanned_at, "mode": r.input_mode} for r in recent],
        recently_imported=[{"batch_id": b.id, "filename": b.filename,
                            "new": b.rows_new, "updated": b.rows_updated,
                            "at": b.committed_at} for b in imports],
        recent_alerts=[{"id": a.id, "input": a.raw_input,
                        "component_id": a.matched_component_id,
                        "criticality": a.criticality, "at": a.scanned_at,
                        "message": "Chinese-origin part in a CRITICAL subsystem"}
                       for a in alerts],
        db_revision=repository.cache.revision,
        last_import_at=imports[0].committed_at if imports else None)


@router.get("/analytics")
async def analytics(session: Annotated[AsyncSession, Depends(get_session)],
                    _: Annotated[Principal, Depends(requires("component:read"))],
                    days: int = Query(90, ge=1, le=3650)) -> dict:
    """Trends, leaderboards and the heat-map series behind the analytics screen."""
    scans = (await session.execute(
        select(ScanRecord).where(ScanRecord.scanned_at >= _since(days)))).scalars().all()

    by_component = Counter(s.matched_component_id for s in scans
                           if s.result == "chinese" and s.matched_component_id)
    names: dict[str, str] = {}
    if by_component:
        rows = (await session.execute(
            select(Component.component_id, Component.component_name,
                   Component.manufacturer, Component.drone_subsystem)
            .where(Component.component_id.in_(list(by_component))))).all()
        names = {r[0]: {"name": r[1], "manufacturer": r[2], "subsystem": r[3]} for r in rows}

    daily: Counter[str] = Counter()
    daily_cn: Counter[str] = Counter()
    for s in scans:
        d = s.scanned_at.strftime("%Y-%m-%d")
        daily[d] += 1
        if s.result == "chinese":
            daily_cn[d] += 1

    monthly: dict[str, Counter] = {}
    for s in scans:
        m = s.scanned_at.strftime("%Y-%m")
        monthly.setdefault(m, Counter())[s.result] += 1

    # Heat map: location label x weekday, used to show where and when detections cluster.
    heat: Counter[tuple[str, int]] = Counter()
    for s in scans:
        if s.result == "chinese":
            heat[(s.location_label or "unspecified", s.scanned_at.weekday())] += 1

    mfr = Counter()
    for cid, n in by_component.items():
        mfr[names.get(cid, {}).get("manufacturer", "unknown")] += n

    unknown = (await session.execute(
        select(PendingComponent).where(PendingComponent.status == "open")
        .order_by(PendingComponent.hit_count.desc()).limit(25))).scalars().all()

    return {
        "window_days": days,
        "total_scans": len(scans),
        "result_mix": dict(Counter(s.result for s in scans)),
        "input_mode_mix": dict(Counter(s.input_mode for s in scans)),
        "match_method_mix": dict(Counter(s.match_method for s in scans)),
        "most_detected_chinese": [
            {"component_id": cid, "hits": n, **names.get(cid, {})}
            for cid, n in by_component.most_common(15)],
        "top_manufacturers": [{"manufacturer": m, "hits": n} for m, n in mfr.most_common(15)],
        "most_scanned": [{"component_id": cid, "hits": n} for cid, n in
                         Counter(s.matched_component_id for s in scans
                                 if s.matched_component_id).most_common(15)],
        "unknown_components": [{"input": p.raw_input, "normalized": p.normalized_input,
                                "hits": p.hit_count, "first_seen": p.created_at}
                               for p in unknown],
        "trend_daily": [{"date": d, "scans": daily[d], "chinese": daily_cn[d]}
                        for d in sorted(daily)],
        "trend_monthly": [{"month": m, **dict(c)} for m, c in sorted(monthly.items())],
        "heatmap": [{"location": loc, "weekday": wd, "hits": n}
                    for (loc, wd), n in heat.items()],
    }


@router.get("/pending")
async def pending_queue(session: Annotated[AsyncSession, Depends(get_session)],
                        _: Annotated[Principal, Depends(requires("component:read"))],
                        status_filter: str = "open") -> list[dict]:
    import json
    rows = (await session.execute(
        select(PendingComponent).where(PendingComponent.status == status_filter)
        .order_by(PendingComponent.hit_count.desc()))).scalars().all()
    return [{"id": p.id, "raw_input": p.raw_input, "normalized": p.normalized_input,
             "hits": p.hit_count, "ocr_text": p.ocr_text[:400],
             "suggestions": json.loads(p.suggested_matches or "[]"),
             "reported_by": p.reported_by, "created_at": p.created_at} for p in rows]


# --------------------------------------------------------------------------- #
# Reports
# --------------------------------------------------------------------------- #
@router.get("/reports/{report_key}")
async def generate_report(report_key: str,
                          session: Annotated[AsyncSession, Depends(get_session)],
                          user: Annotated[Principal, Depends(requires("report:generate"))],
                          fmt: str = Query("pdf", pattern="^(pdf|xlsx|csv)$"),
                          inspection_id: str | None = None,
                          days: int = Query(30, ge=1, le=3650)) -> Response:
    """Report keys: inspection, chinese_components, unknown_origin, statistics,
    monthly, audit."""
    meta = {"generated_by": user.id, "db_revision": repository.cache.revision}
    rows: list[dict] = []
    notes: list[str] = []

    if report_key == "inspection":
        stmt = select(ScanRecord).order_by(ScanRecord.scanned_at)
        stmt = (stmt.where(ScanRecord.inspection_id == inspection_id) if inspection_id
                else stmt.where(ScanRecord.scanned_at >= _since(days)))
        scans = (await session.execute(stmt)).scalars().all()
        lookup: dict[str, tuple[str, str, str]] = {}
        ids = [s.matched_component_id for s in scans if s.matched_component_id]
        if ids:
            found = (await session.execute(
                select(Component.component_id, Component.component_name,
                       Component.manufacturer, Component.country_of_origin)
                .where(Component.component_id.in_(ids)))).all()
            lookup = {r[0]: (r[1], r[2], r[3]) for r in found}
        for s in scans:
            name, mfr, coo = lookup.get(s.matched_component_id or "", ("", "", ""))
            rows.append({"scanned_at": s.scanned_at.strftime("%Y-%m-%d %H:%M"),
                         "raw_input": s.raw_input, "normalized_input": s.normalized_input,
                         "matched_component_id": s.matched_component_id or "",
                         "component_name": name, "manufacturer": mfr,
                         "country_of_origin": coo, "result": s.result,
                         "criticality": s.criticality, "match_method": s.match_method,
                         "match_score": round(s.match_score, 1),
                         "location_label": s.location_label, "remarks": s.remarks})

    elif report_key in ("chinese_components", "unknown_origin"):
        verdict = "YES" if report_key == "chinese_components" else "UNKNOWN"
        items, _n = await repository.search(session, is_chinese=verdict,
                                            page=1, page_size=1_000_000)
        items.sort(key=lambda c: (c.criticality != "CRITICAL", c.drone_subsystem))
        rows = [{c.name: getattr(i, c.name) for c in Component.__table__.columns}
                for i in items]

    elif report_key == "statistics":
        counts = await repository.dashboard_counts(session)
        scans = (await session.execute(
            select(ScanRecord).where(ScanRecord.scanned_at >= _since(days)))).scalars().all()
        mix = Counter(s.result for s in scans)
        rows = [{"metric": k.replace("_", " ").title(), "value": v} for k, v in counts.items()]
        rows += [{"metric": f"Scans ({days}d): {k}", "value": v} for k, v in mix.items()]
        rows.append({"metric": "Database revision", "value": repository.cache.revision})

    elif report_key == "monthly":
        scans = (await session.execute(
            select(ScanRecord).where(ScanRecord.scanned_at >= _since(days)))).scalars().all()
        buckets: dict[str, dict] = {}
        for s in scans:
            m = s.scanned_at.strftime("%Y-%m")
            b = buckets.setdefault(m, {"month": m, "inspections": set(), "scans": 0,
                                       "chinese_hits": 0, "unknown": 0, "not_found": 0,
                                       "inspectors": set()})
            b["scans"] += 1
            b["inspectors"].add(s.user_id)
            if s.inspection_id:
                b["inspections"].add(s.inspection_id)
            if s.result == "chinese":
                b["chinese_hits"] += 1
            elif s.result == "unknown_origin":
                b["unknown"] += 1
            elif s.result == "not_found":
                b["not_found"] += 1
        rows = [{"month": b["month"], "inspections": len(b["inspections"]),
                 "scans": b["scans"], "chinese_hits": b["chinese_hits"],
                 "unknown": b["unknown"], "not_found": b["not_found"],
                 "distinct_inspectors": len(b["inspectors"])}
                for b in sorted(buckets.values(), key=lambda x: x["month"])]

    elif report_key == "audit":
        if not user.can("audit:read"):
            raise HTTPException(403, "Only an administrator may export the audit trail")
        entries = (await session.execute(
            select(AuditLog).where(AuditLog.occurred_at >= _since(days))
            .order_by(AuditLog.sequence))).scalars().all()
        rows = [{"sequence": e.sequence,
                 "occurred_at": e.occurred_at.strftime("%Y-%m-%d %H:%M:%S"),
                 "actor_username": e.actor_username or e.actor_id or "",
                 "action": e.action, "entity_type": e.entity_type,
                 "entity_id": e.entity_id, "ip_address": e.ip_address,
                 "hash": e.hash[:16] + "..."} for e in entries]
        chain = await audit.verify(session)
        notes.append(f"Chain verification: <b>{chain['detail']}</b> "
                     f"({chain['entries']} entries).")
    else:
        raise HTTPException(404, f"Unknown report '{report_key}'. Available: "
                                 f"{', '.join(reports.REPORTS)}")

    if notes:
        reports.REPORTS[report_key] = {**reports.REPORTS[report_key],
                                       "notes": reports.REPORTS[report_key].get("notes", [])
                                       + notes}
    payload, filename, media = reports.build(report_key, rows, meta, fmt)
    await audit.record(session, action="report.generated", actor_id=user.id,
                       entity_type="report", entity_id=report_key,
                       detail={"format": fmt, "rows": len(rows), "days": days})
    return Response(payload, media_type=media,
                    headers={"Content-Disposition": f'attachment; filename="{filename}"'})


# --------------------------------------------------------------------------- #
@router.get("/audit")
async def audit_entries(session: Annotated[AsyncSession, Depends(get_session)],
                        _: Annotated[Principal, Depends(requires("audit:read"))],
                        action: str | None = None, days: int = Query(30, ge=1, le=3650),
                        limit: int = Query(200, ge=1, le=5000)) -> list[dict]:
    stmt = select(AuditLog).where(AuditLog.occurred_at >= _since(days))
    if action:
        stmt = stmt.where(AuditLog.action == action)
    rows = (await session.execute(
        stmt.order_by(AuditLog.sequence.desc()).limit(limit))).scalars().all()
    import json
    return [{"sequence": r.sequence, "at": r.occurred_at, "actor": r.actor_username,
             "action": r.action, "entity": f"{r.entity_type}:{r.entity_id}",
             "detail": json.loads(r.detail_json or "{}"), "ip": r.ip_address,
             "hash": r.hash} for r in rows]


@router.get("/audit/verify")
async def audit_verify(session: Annotated[AsyncSession, Depends(get_session)],
                       _: Annotated[Principal, Depends(requires("audit:read"))]) -> dict:
    """Recompute the hash chain end to end. A break means a row was altered or
    deleted directly in the database, bypassing the application."""
    return await audit.verify(session)
