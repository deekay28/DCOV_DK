"""Field operations: scanning, manual entry, OCR upload, inspections, offline sync."""
from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from typing import Annotated

from fastapi import (APIRouter, Depends, File, Form, HTTPException, Query, Request,
                     UploadFile, status)
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.database import get_session
from app.core.security import Principal, current_user, requires, sign_inspection
from app.models.entities import (Component, Inspection, PendingComponent, ScanRecord,
                                 SyncState, utcnow)
from app.models.schemas import (BatchScanRequest, InspectionCreate, InspectionOut,
                                InspectionSign, ScanRequest, ScanResult, SyncPull, SyncPush)
from app.services import audit, repository
from app.services.matching import Matcher, verdict_for
from app.services.marking import analyse as analyse_marking, apply_to_verdict
from app.services.ocr import read_markings, summarize_for_api

router = APIRouter(tags=["field"])
matcher = Matcher()


# --------------------------------------------------------------------------- #
# Scanning
def _marking_for(component: dict | None, raw_input: str, ocr_text: str):
    """Run the anti-remark marking check against everything read off the chip.
    OCR text carries all the lines; a typed or scanned single value usually
    only carries the part number, in which case this finds nothing."""
    c = component or {}
    return analyse_marking(
        ocr_text or raw_input,
        manufacturer=c.get("manufacturer"),
        part_key=c.get("chip_number") or c.get("part_number"),
        catalogue_is_chinese=c.get("is_chinese"))


# --------------------------------------------------------------------------- #
async def _perform_scan(session: AsyncSession, body: ScanRequest,
                        user: Principal, image_paths: list[str] | None = None) -> ScanResult:
    started = datetime.now(timezone.utc)

    # Offline clients retry; the client_uuid makes a replay a no-op rather than
    # a duplicate history entry.
    prior = (await session.execute(
        select(ScanRecord).where(ScanRecord.client_uuid == body.client_uuid))
    ).scalar_one_or_none()
    if prior is not None:
        return await _result_from_record(session, prior, replayed=True)

    match = matcher.match(body.raw_input, repository.cache.index)
    verdict = verdict_for(match.component, match.score, match.method)
    marking = _marking_for(match.component, body.raw_input, body.ocr_text)
    verdict = apply_to_verdict(verdict, marking)

    record = ScanRecord(
        client_uuid=body.client_uuid, inspection_id=body.inspection_id, user_id=user.id,
        input_mode=body.input_mode, raw_input=body.raw_input[:512],
        normalized_input=match.normalized_input, ocr_text=body.ocr_text[:8000],
        barcode_symbology=body.barcode_symbology,
        matched_component_id=(match.component or {}).get("component_id"),
        match_method=match.method, match_score=match.score,
        result=verdict["result"], criticality=verdict.get("criticality", ""),
        device_id=body.device_id, device_model=body.device_model,
        app_version=body.app_version, latitude=body.latitude, longitude=body.longitude,
        location_label=body.location_label, remarks=body.remarks,
        duration_ms=body.duration_ms or int(
            (datetime.now(timezone.utc) - started).total_seconds() * 1000),
        scanned_at=body.scanned_at or started, synced_at=utcnow(),
        image_paths=json.dumps(image_paths or _valid_image_ref(body.image_ref)),
    )
    session.add(record)
    await session.flush()

    if verdict["result"] == "not_found":
        await _queue_pending(session, body, match, user)

    # Only origin-relevant outcomes go to the audit trail; a green scan is
    # history, a red one is evidence.
    if verdict["result"] in ("chinese", "unknown_origin"):
        await audit.record(
            session, action=f"scan.{verdict['result']}", actor_id=user.id,
            entity_type="component",
            entity_id=(match.component or {}).get("component_id", ""),
            detail={"raw_input": body.raw_input, "method": match.method,
                    "score": match.score, "criticality": verdict.get("criticality"),
                    "inspection_id": body.inspection_id,
                    "marking_findings": [f.as_dict() for f in marking.findings]})

    return await _result_from_record(session, record, match=match, verdict=verdict,
                                     marking=marking)


async def _queue_pending(session: AsyncSession, body: ScanRequest, match,
                         user: Principal) -> None:
    existing = (await session.execute(
        select(PendingComponent).where(
            PendingComponent.normalized_input == match.normalized_input,
            PendingComponent.status == "open"))).scalar_one_or_none()
    if existing:
        existing.hit_count += 1
        return
    session.add(PendingComponent(
        raw_input=body.raw_input[:512], normalized_input=match.normalized_input,
        ocr_text=body.ocr_text[:8000], reported_by=user.id,
        suggested_matches=json.dumps([
            {"component_id": c.component_id, "score": c.score,
             "component_name": c.payload.get("component_name", "")}
            for c in match.suggestions[:5]])))


async def _result_from_record(session: AsyncSession, record: ScanRecord,
                              match=None, verdict=None, replayed: bool = False,
                              marking=None) -> ScanResult:
    component = None
    if record.matched_component_id:
        component = await repository.get_by_component_id(session, record.matched_component_id)
    if verdict is None:
        # Replay path: recompute deterministically from what was stored, so a
        # replayed scan reports the same marking findings as the original.
        cdict = ({c.name: getattr(component, c.name) for c in Component.__table__.columns}
                 if component else None)
        verdict = verdict_for(cdict, record.match_score, record.match_method)
        marking = _marking_for(cdict, record.raw_input, record.ocr_text)
        verdict = apply_to_verdict(verdict, marking)

    suggestions = []
    if match is not None:
        suggestions = [{
            "component_id": c.component_id,
            "component_name": c.payload.get("component_name", ""),
            "manufacturer": c.payload.get("manufacturer", ""),
            "country_of_origin": c.payload.get("country_of_origin", ""),
            "is_chinese": c.payload.get("is_chinese", "UNKNOWN"),
            "score": round(c.score, 1),
        } for c in match.suggestions[:5]]

    notes = list(match.notes) if match else []
    if replayed:
        notes.append("Replay of a previously recorded scan - no duplicate history entry created.")

    return ScanResult(
        scan_id=record.id, client_uuid=record.client_uuid, result=record.result,
        banner=verdict["banner"], headline=verdict["headline"],
        criticality=verdict.get("criticality", ""), escalate=verdict.get("escalate", False),
        escalation_note=verdict.get("escalation_note", ""), action=verdict.get("action", ""),
        alert=verdict.get("alert", False), vibrate=verdict.get("vibrate", False),
        sound=verdict.get("sound", ""), match_method=record.match_method,
        match_score=record.match_score, confidence=verdict.get("confidence", 0.0),
        normalized_input=record.normalized_input, notes=notes,
        marking_findings=[f.as_dict() for f in marking.findings] if marking else [],
        origin_evidence=verdict.get("origin_evidence", "none"),
        evidence_detail=verdict.get("evidence_detail", ""),
        review_required=verdict.get("review_required", True),
        policy_decision=verdict.get("policy_decision", ""),
        component=component, suggestions=suggestions, inspected_at=record.scanned_at)


@router.post("/scan", response_model=ScanResult)
async def scan(body: ScanRequest, session: Annotated[AsyncSession, Depends(get_session)],
               user: Annotated[Principal, Depends(requires("scan:execute"))]) -> ScanResult:
    """Single lookup from a barcode, QR payload, OCR read, or manual keyboard entry.

    `input_mode='manual'` is the fallback path for an unreadable package: the
    inspector types the marking and it goes through the identical matching
    cascade, so a manual result is never treated as less authoritative than a
    scanned one.
    """
    return await _perform_scan(session, body, user)


@router.post("/scan/batch", response_model=list[ScanResult])
async def scan_batch(body: BatchScanRequest,
                     session: Annotated[AsyncSession, Depends(get_session)],
                     user: Annotated[Principal, Depends(requires("scan:execute"))]
                     ) -> list[ScanResult]:
    """Teardown mode: a whole board's worth of markings in one round trip."""
    return [await _perform_scan(session, s, user) for s in body.scans]


@router.post("/scan/ocr")
async def scan_from_image(session: Annotated[AsyncSession, Depends(get_session)],
                          user: Annotated[Principal, Depends(requires("scan:execute"))],
                          image: Annotated[UploadFile, File()],
                          client_uuid: Annotated[str, Form()],
                          multi_chip: Annotated[bool, Form()] = False,
                          inspection_id: Annotated[str | None, Form()] = None,
                          device_id: Annotated[str, Form()] = "",
                          auto_lookup: Annotated[bool, Form()] = True) -> dict:
    """Upload a chip photograph, run the server OCR ensemble, optionally look the
    best candidate up immediately.

    The response always includes every candidate marking, because on a marginal
    read the inspector - not the app - should choose which line is the part number.
    """
    data = await image.read()
    if len(data) > settings.max_upload_mb * 1024 * 1024:
        raise HTTPException(status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
                            f"Image exceeds {settings.max_upload_mb} MB")
    if not (image.content_type or "").startswith("image/"):
        raise HTTPException(415, "Uploaded file is not an image")

    image_path = _store_scan_image(data, client_uuid)
    ocr = read_markings(data, multi_chip=multi_chip)
    payload: dict = {"ocr": summarize_for_api(ocr), "result": None, "results": []}

    if auto_lookup and ocr.chips:
        # One scan record per segmented package, each with its own marking
        # check - a COO code read off one chip is never applied to another.
        for i, c in enumerate(ocr.chips):
            payload["results"].append(await _perform_scan(session, ScanRequest(
                client_uuid=f"{client_uuid[:32]}-{i:03d}", input_mode="ocr",
                raw_input=c["best"], ocr_text=c["full_text"], inspection_id=inspection_id,
                device_id=device_id), user, image_paths=[image_path]))
        payload["message"] = (f"{len(ocr.chips)} packages detected - each was verified "
                              f"separately. Check each result against its package.")
    elif auto_lookup and ocr.multiple_parts:
        # Several part numbers in one frame and no clean segmentation: which
        # lines belong to which part is unknown, so do not pick one silently.
        payload["message"] = ("More than one part number was read in this photo. "
                              "REQUIRES MANUAL REVIEW: choose the marking of the component "
                              "you are inspecting, or photograph one component at a time.")
    elif auto_lookup and ocr.best:
        payload["result"] = await _perform_scan(session, ScanRequest(
            client_uuid=client_uuid, input_mode="ocr", raw_input=ocr.best,
            ocr_text=ocr.full_text, inspection_id=inspection_id, device_id=device_id,
        ), user, image_paths=[image_path])
    elif auto_lookup:
        payload["message"] = ("No candidate marking could be read. Retry with macro "
                              "focus and off-axis lighting, or enter the marking manually.")
    payload["image_path"] = image_path
    return payload


def _valid_image_ref(ref: str) -> list[str]:
    """Accept only a path this server itself produced under uploads/scans."""
    if not ref or ".." in ref or ref.startswith(("/", "\\")) or not ref.startswith("scans/"):
        return []
    return [ref] if (settings.upload_dir / ref).is_file() else []


def _store_scan_image(data: bytes, client_uuid: str) -> str:
    """Keep the photograph as audit evidence (path recorded on the scan)."""
    safe = "".join(ch for ch in client_uuid if ch.isalnum() or ch in "-_")[:40] or "scan"
    day = datetime.now(timezone.utc).strftime("%Y%m%d")
    folder = settings.upload_dir / "scans" / day
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / f"{safe}.jpg"
    n = 1
    while path.exists():
        path = folder / f"{safe}-{n}.jpg"
        n += 1
    path.write_bytes(data)
    return path.relative_to(settings.upload_dir).as_posix()


@router.get("/scan/history")
async def scan_history(session: Annotated[AsyncSession, Depends(get_session)],
                       user: Annotated[Principal, Depends(requires("inspection:read"))],
                       result: str | None = None, inspection_id: str | None = None,
                       mine: bool = False, days: int = Query(30, ge=1, le=3650),
                       page: int = Query(1, ge=1), page_size: int = Query(50, ge=1, le=500)
                       ) -> dict:
    stmt = select(ScanRecord).where(
        ScanRecord.scanned_at >= datetime.now(timezone.utc) - timedelta(days=days))
    if result:
        stmt = stmt.where(ScanRecord.result == result)
    if inspection_id:
        stmt = stmt.where(ScanRecord.inspection_id == inspection_id)
    if mine:
        stmt = stmt.where(ScanRecord.user_id == user.id)
    total = (await session.execute(
        select(func.count()).select_from(stmt.subquery()))).scalar_one()
    rows = (await session.execute(
        stmt.order_by(ScanRecord.scanned_at.desc())
        .offset((page - 1) * page_size).limit(page_size))).scalars().all()
    return {"total": total, "page": page, "page_size": page_size,
            "items": [{
                "id": r.id, "scanned_at": r.scanned_at, "input_mode": r.input_mode,
                "raw_input": r.raw_input, "normalized_input": r.normalized_input,
                "result": r.result, "criticality": r.criticality,
                "matched_component_id": r.matched_component_id,
                "match_method": r.match_method, "match_score": r.match_score,
                "user_id": r.user_id, "device_id": r.device_id,
                "device_model": r.device_model, "location_label": r.location_label,
                "latitude": r.latitude, "longitude": r.longitude,
                "ocr_text": r.ocr_text[:400], "images": json.loads(r.image_paths or "[]"),
                "inspection_id": r.inspection_id, "duration_ms": r.duration_ms,
            } for r in rows]}


# --------------------------------------------------------------------------- #
# Inspections
# --------------------------------------------------------------------------- #
async def _next_inspection_number(session: AsyncSession) -> str:
    year = datetime.now(timezone.utc).year
    n = (await session.execute(
        select(func.count()).select_from(Inspection)
        .where(Inspection.inspection_number.like(f"INSP-{year}-%")))).scalar_one()
    return f"INSP-{year}-{n + 1:05d}"


@router.post("/inspections", response_model=InspectionOut,
             status_code=status.HTTP_201_CREATED)
async def create_inspection(body: InspectionCreate,
                            session: Annotated[AsyncSession, Depends(get_session)],
                            user: Annotated[Principal, Depends(requires("inspection:create"))]
                            ) -> Inspection:
    insp = Inspection(inspection_number=await _next_inspection_number(session),
                      title=body.title, platform=body.platform,
                      serial_number=body.serial_number,
                      inspector_id=body.inspector_id or user.id, location=body.location,
                      latitude=body.latitude, longitude=body.longitude, remarks=body.remarks)
    session.add(insp)
    await session.flush()
    await audit.record(session, action="inspection.created", actor_id=user.id,
                       entity_type="inspection", entity_id=insp.inspection_number,
                       detail={"platform": body.platform, "serial": body.serial_number})
    return insp


@router.get("/inspections", response_model=list[InspectionOut])
async def list_inspections(session: Annotated[AsyncSession, Depends(get_session)],
                           user: Annotated[Principal, Depends(requires("inspection:read"))],
                           status_filter: str | None = None, mine: bool = False,
                           limit: int = Query(100, ge=1, le=1000)) -> list[Inspection]:
    stmt = select(Inspection).order_by(Inspection.started_at.desc()).limit(limit)
    if status_filter:
        stmt = stmt.where(Inspection.status == status_filter)
    if mine:
        stmt = stmt.where(Inspection.inspector_id == user.id)
    return list((await session.execute(stmt)).scalars().all())


@router.get("/inspections/{inspection_id}")
async def get_inspection(inspection_id: str,
                         session: Annotated[AsyncSession, Depends(get_session)],
                         _: Annotated[Principal, Depends(requires("inspection:read"))]) -> dict:
    insp = (await session.execute(
        select(Inspection).where(Inspection.id == inspection_id))).scalar_one_or_none()
    if insp is None:
        raise HTTPException(404, "Inspection not found")
    scans = (await session.execute(
        select(ScanRecord).where(ScanRecord.inspection_id == inspection_id)
        .order_by(ScanRecord.scanned_at))).scalars().all()
    tally: dict[str, int] = {}
    for s in scans:
        tally[s.result] = tally.get(s.result, 0) + 1
    return {"inspection": InspectionOut.model_validate(insp),
            "scan_count": len(scans), "tally": tally,
            "scans": [{"id": s.id, "raw_input": s.raw_input, "result": s.result,
                       "criticality": s.criticality, "component_id": s.matched_component_id,
                       "scanned_at": s.scanned_at} for s in scans]}


@router.post("/inspections/{inspection_id}/sign", response_model=InspectionOut)
async def sign(inspection_id: str, body: InspectionSign, request: Request,
               session: Annotated[AsyncSession, Depends(get_session)],
               user: Annotated[Principal, Depends(requires("inspection:sign"))]) -> Inspection:
    """Freeze and digitally sign an inspection. Signed inspections are immutable."""
    insp = (await session.execute(
        select(Inspection).where(Inspection.id == inspection_id))).scalar_one_or_none()
    if insp is None:
        raise HTTPException(404, "Inspection not found")
    if insp.signature:
        raise HTTPException(status.HTTP_409_CONFLICT,
                            f"Inspection {insp.inspection_number} was already signed at "
                            f"{insp.signed_at:%Y-%m-%d %H:%M UTC} and cannot be re-signed. "
                            f"Raise a new inspection referencing this one.")
    if insp.inspector_id != user.id and user.role != "administrator":
        raise HTTPException(403, "Only the assigned inspector or an administrator may sign")

    scans = (await session.execute(
        select(ScanRecord).where(ScanRecord.inspection_id == inspection_id))).scalars().all()
    chinese = [s for s in scans if s.result == "chinese"]
    if chinese and body.verdict == "clear":
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            f"This inspection contains {len(chinese)} Chinese-origin finding(s); it "
            f"cannot be signed off as 'clear'. Use 'chinese_found', or void the "
            f"disputed scans first with a documented reason.")

    payload = {"inspection_number": insp.inspection_number, "platform": insp.platform,
               "serial_number": insp.serial_number, "verdict": body.verdict,
               "scan_ids": sorted(s.id for s in scans), "remarks": body.remarks}
    insp.signature = sign_inspection(payload, user.id)
    insp.signed_at = utcnow()
    insp.completed_at = utcnow()
    insp.status = "escalated" if chinese else "completed"
    insp.verdict = body.verdict
    insp.remarks = body.remarks

    await audit.record(session, action="inspection.signed", actor_id=user.id,
                       entity_type="inspection", entity_id=insp.inspection_number,
                       detail={"verdict": body.verdict, "scans": len(scans),
                               "chinese_findings": len(chinese),
                               "signature": insp.signature},
                       ip=request.client.host if request.client else "")
    return insp


# --------------------------------------------------------------------------- #
# Offline synchronisation
# --------------------------------------------------------------------------- #
@router.post("/sync/push")
async def sync_push(body: SyncPush, session: Annotated[AsyncSession, Depends(get_session)],
                    user: Annotated[Principal, Depends(requires("scan:execute"))]) -> dict:
    """Upload scans captured offline.

    Conflict policy: scans are immutable historical facts, so the server never
    overwrites one. A client_uuid already present is accepted as a duplicate and
    reported back, rather than being re-inserted or silently dropped.
    """
    accepted, duplicates, failed = [], [], []
    for item in body.scans:
        try:
            existing = (await session.execute(
                select(ScanRecord.id).where(ScanRecord.client_uuid == item.client_uuid)
            )).scalar_one_or_none()
            if existing:
                duplicates.append(item.client_uuid)
                continue
            res = await _perform_scan(session, item, user)
            accepted.append({"client_uuid": item.client_uuid, "scan_id": res.scan_id,
                             "result": res.result})
        except Exception as exc:
            failed.append({"client_uuid": item.client_uuid, "error": str(exc)})

    state = (await session.execute(
        select(SyncState).where(SyncState.device_id == body.device_id))).scalar_one_or_none()
    if state is None:
        state = SyncState(device_id=body.device_id, user_id=user.id)
        session.add(state)
    state.last_push_at = utcnow()

    return {"accepted": len(accepted), "duplicates": len(duplicates),
            "failed": len(failed), "details": {"accepted": accepted,
                                               "duplicates": duplicates, "failed": failed},
            "server_revision": repository.cache.revision}


@router.get("/sync/pull", response_model=SyncPull)
async def sync_pull(session: Annotated[AsyncSession, Depends(get_session)],
                    user: Annotated[Principal, Depends(requires("component:read"))],
                    device_id: str, since: datetime | None = None,
                    since_revision: int = 0) -> SyncPull:
    """Deliver component changes for the offline cache.

    Server-wins for component data: the catalogue is authoritative and a device
    must never keep a stale GREEN verdict for a part that has since been
    reclassified RED.
    """
    stmt = select(Component).where(Component.is_deleted.is_(False))
    if since:
        stmt = stmt.where(Component.updated_at > since)
    changed = list((await session.execute(stmt)).scalars().all())
    deleted = list((await session.execute(
        select(Component.component_id).where(
            Component.is_deleted.is_(True),
            *( [Component.updated_at > since] if since else [] )))).scalars().all())

    state = (await session.execute(
        select(SyncState).where(SyncState.device_id == device_id))).scalar_one_or_none()
    if state is None:
        state = SyncState(device_id=device_id, user_id=user.id)
        session.add(state)
    state.last_pull_at = utcnow()
    state.db_revision = repository.cache.revision

    return SyncPull(db_revision=repository.cache.revision, components_changed=changed,
                    components_deleted=deleted, conflicts=[],
                    server_time=datetime.now(timezone.utc))
