"""Component catalogue, search, and database management (import/export/backup)."""
from __future__ import annotations

import json
import shutil
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Annotated, Any

from fastapi import (APIRouter, Body, Depends, File, HTTPException, Query, Request,
                     UploadFile, status)
from fastapi.responses import Response
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.database import get_session
from app.core.security import Principal, requires
from app.models.entities import Component, ComponentRevision, ImportBatch, utcnow
from app.models.schemas import (ComponentCreate, ComponentOut, ComponentPage,
                                ComponentUpdate, ImportCommit, ImportPreview, ImportSummary)
from app.services import audit, importer, repository, reports
from app.services.matching import normalize, normalize_manufacturer

router = APIRouter(tags=["catalog"])

# batch_id -> staged import awaiting commit. Bounded; entries expire on commit,
# rollback, or server restart (a staged import is deliberately not durable).
_STAGED: dict[str, importer.StagedImport] = {}
STAGE_LIMIT = 20


# --------------------------------------------------------------------------- #
# Search and retrieval
# --------------------------------------------------------------------------- #
@router.get("/components", response_model=ComponentPage)
async def list_components(session: Annotated[AsyncSession, Depends(get_session)],
                          _: Annotated[Principal, Depends(requires("component:read"))],
                          q: str = "", country: str = "", manufacturer: str = "",
                          subsystem: str = "", category: str = "", is_chinese: str = "",
                          criticality: str = "", pending: bool | None = None,
                          order: str = "component_name",
                          page: int = Query(1, ge=1),
                          page_size: int = Query(50, ge=1, le=500)) -> ComponentPage:
    items, total = await repository.search(
        session, q=q, country=country, manufacturer=manufacturer, subsystem=subsystem,
        category=category, is_chinese=is_chinese, criticality=criticality,
        pending=pending, page=page, page_size=page_size, order=order)
    return ComponentPage(items=items, total=total, page=page, page_size=page_size)


@router.get("/components/facets")
async def component_facets(session: Annotated[AsyncSession, Depends(get_session)],
                           _: Annotated[Principal, Depends(requires("component:read"))]
                           ) -> dict[str, list[dict]]:
    return await repository.facets(session)


@router.get("/components/{component_id}", response_model=ComponentOut)
async def get_component(component_id: str,
                        session: Annotated[AsyncSession, Depends(get_session)],
                        _: Annotated[Principal, Depends(requires("component:read"))]
                        ) -> Component:
    comp = await repository.get_by_component_id(session, component_id)
    if comp is None:
        raise HTTPException(404, f"No component with id '{component_id}'")
    return comp


@router.get("/components/{component_id}/history")
async def component_history(component_id: str,
                            session: Annotated[AsyncSession, Depends(get_session)],
                            _: Annotated[Principal, Depends(requires("component:read"))]
                            ) -> list[dict]:
    rows = (await session.execute(
        select(ComponentRevision).where(ComponentRevision.component_id == component_id)
        .order_by(ComponentRevision.created_at.desc()))).scalars().all()
    return [{"revision": r.revision, "operation": r.operation,
             "changed_fields": json.loads(r.changed_fields), "actor_id": r.actor_id,
             "batch_id": r.batch_id, "at": r.created_at,
             "snapshot": json.loads(r.snapshot_json)} for r in rows]


# --------------------------------------------------------------------------- #
# Mutation
# --------------------------------------------------------------------------- #
@router.post("/components", response_model=ComponentOut,
             status_code=status.HTTP_201_CREATED)
async def create_component(body: ComponentCreate,
                           session: Annotated[AsyncSession, Depends(get_session)],
                           user: Annotated[Principal, Depends(requires("component:write"))]
                           ) -> Component:
    data = body.model_dump()
    data["manufacturer"] = normalize_manufacturer(data["manufacturer"])
    data["is_chinese"] = importer.derive_is_chinese(data["country_of_origin"],
                                                    data["remarks"])
    data["search_key"] = normalize(data["chip_number"] or data["part_number"])
    if not data["component_id"]:
        data["component_id"] = importer.stable_component_id(data)
    if await repository.get_by_component_id(session, data["component_id"]):
        raise HTTPException(status.HTTP_409_CONFLICT,
                            f"Component '{data['component_id']}' already exists. "
                            f"Edit the existing record instead of creating a duplicate.")
    comp = Component(**data, pending_verification=(data["is_chinese"] == "UNKNOWN"))
    session.add(comp)
    await session.flush()
    await repository.snapshot(session, comp, "create", list(data), user.id)
    await audit.record(session, action="component.created", actor_id=user.id,
                       entity_type="component", entity_id=comp.component_id,
                       detail={"is_chinese": comp.is_chinese,
                               "country": comp.country_of_origin})
    await repository.cache.rebuild(session)
    return comp


@router.patch("/components/{component_id}", response_model=ComponentOut)
async def update_component(component_id: str, body: ComponentUpdate,
                           session: Annotated[AsyncSession, Depends(get_session)],
                           user: Annotated[Principal, Depends(requires("component:write"))]
                           ) -> Component:
    """Every edit requires a `change_reason`, which is written to the audit trail.

    An origin change is the one edit that can turn a rejected part into an
    accepted one, so it is never anonymous.
    """
    comp = await repository.get_by_component_id(session, component_id)
    if comp is None:
        raise HTTPException(404, f"No component with id '{component_id}'")

    changes = body.model_dump(exclude_unset=True, exclude={"change_reason"})
    if not changes:
        raise HTTPException(422, "No fields supplied to update")

    before = {k: getattr(comp, k) for k in changes}
    await repository.snapshot(session, comp, "update", list(changes), user.id)
    for k, v in changes.items():
        setattr(comp, k, v)

    if "country_of_origin" in changes:
        comp.is_chinese = importer.derive_is_chinese(comp.country_of_origin, comp.remarks)
        comp.pending_verification = comp.is_chinese == "UNKNOWN"
    if "manufacturer" in changes:
        comp.manufacturer = normalize_manufacturer(comp.manufacturer)
    comp.revision += 1
    comp.updated_at = utcnow()

    await audit.record(session, action="component.updated", actor_id=user.id,
                       entity_type="component", entity_id=comp.component_id,
                       detail={"reason": body.change_reason,
                               "before": {k: str(v) for k, v in before.items()},
                               "after": {k: str(v) for k, v in changes.items()},
                               "new_verdict": comp.is_chinese})
    await repository.cache.rebuild(session)
    return comp


@router.delete("/components/{component_id}", status_code=status.HTTP_204_NO_CONTENT, response_model=None)
async def delete_component(component_id: str, reason: Annotated[str, Query(min_length=3)],
                           session: Annotated[AsyncSession, Depends(get_session)],
                           user: Annotated[Principal, Depends(requires("component:delete"))]
                           ) -> None:
    """Soft delete. The row and its revision history are retained so that an
    inspection that once referenced it remains explicable."""
    if not await repository.soft_delete(session, component_id, user.id):
        raise HTTPException(404, f"No component with id '{component_id}'")
    await audit.record(session, action="component.deleted", actor_id=user.id,
                       entity_type="component", entity_id=component_id,
                       detail={"reason": reason})
    await repository.cache.rebuild(session)


@router.post("/components/bulk-update")
async def bulk_update(session: Annotated[AsyncSession, Depends(get_session)],
                      user: Annotated[Principal, Depends(requires("component:write"))],
                      component_ids: Annotated[list[str], Body()],
                      changes: Annotated[dict[str, Any], Body()],
                      reason: Annotated[str, Body(min_length=3)]) -> dict:
    try:
        n = await repository.bulk_update(session, component_ids, changes, user.id)
    except ValueError as exc:
        raise HTTPException(422, str(exc)) from exc
    await audit.record(session, action="component.bulk_updated", actor_id=user.id,
                       entity_type="component", entity_id=f"{n} rows",
                       detail={"reason": reason, "changes": changes,
                               "ids": component_ids[:50]})
    await repository.cache.rebuild(session)
    return {"updated": n}


# --------------------------------------------------------------------------- #
# Import wizard
# --------------------------------------------------------------------------- #
@router.post("/database/import/stage", response_model=ImportPreview)
async def stage_import(session: Annotated[AsyncSession, Depends(get_session)],
                       user: Annotated[Principal, Depends(requires("database:import"))],
                       file: Annotated[UploadFile, File()],
                       sheet: str | None = None,
                       mapping_json: str | None = None) -> ImportPreview:
    """Step 1 of 2. Parses, maps, validates and diffs the file. Writes nothing.

    Returns the full preview - new rows, changed rows with per-field before/after,
    duplicates, validation errors, and any origin-verdict flips - for review
    before `/commit`.
    """
    data = await file.read()
    if len(data) > settings.max_upload_mb * 1024 * 1024:
        raise HTTPException(status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
                            f"File exceeds {settings.max_upload_mb} MB")
    try:
        parsed = importer.parse_file(data, file.filename or "upload", sheet)
    except Exception as exc:
        raise HTTPException(422, f"Could not read the file: {exc}") from exc
    if not parsed.rows:
        raise HTTPException(422, "The file contains a header but no data rows")

    override = json.loads(mapping_json) if mapping_json else None
    batch_id = str(uuid.uuid4())
    existing = await repository.existing_map(session)
    staged = importer.stage_import(parsed, existing, batch_id,
                                   file.filename or "upload", override)

    if len(_STAGED) >= STAGE_LIMIT:
        _STAGED.pop(next(iter(_STAGED)))
    _STAGED[batch_id] = staged

    session.add(ImportBatch(
        id=batch_id, filename=file.filename or "upload", file_sha256=parsed.sha256,
        file_format=parsed.file_format, status="staged", actor_id=user.id,
        rows_total=len(parsed.rows), rows_new=len(staged.new_rows),
        rows_updated=len(staged.updated_rows), rows_unchanged=staged.unchanged,
        rows_duplicate=len(staged.duplicates),
        rows_invalid=len([i for i in staged.invalid if i.severity == "error"]),
        summary_json=json.dumps(importer.summarize(staged), default=str)))
    await audit.record(session, action="import.staged", actor_id=user.id,
                       entity_type="import_batch", entity_id=batch_id,
                       detail={"filename": file.filename, "sha256": parsed.sha256,
                               "rows": len(parsed.rows)})
    return ImportPreview(**importer.summarize(staged))


@router.post("/database/import/commit", response_model=ImportSummary)
async def commit_import(body: ImportCommit,
                        session: Annotated[AsyncSession, Depends(get_session)],
                        user: Annotated[Principal, Depends(requires("database:import"))]
                        ) -> ImportSummary:
    """Step 2 of 2. Applies the staged batch in a single transaction.

    Every touched row gets a revision snapshot tagged with this batch id, which
    is what `/rollback` replays.
    """
    staged = _STAGED.get(body.batch_id)
    batch = (await session.execute(
        select(ImportBatch).where(ImportBatch.id == body.batch_id))).scalar_one_or_none()
    if batch is None:
        raise HTTPException(404, "Unknown or expired batch. Re-stage the file.")
    if batch.status != "staged":
        # Checked before `staged is None` deliberately: `_STAGED` is popped
        # on a successful commit (see the end of this function), so a
        # second commit attempt on an already-committed batch always has
        # staged=None - if that were checked first, this correctly-a-409
        # case would incorrectly return 404 instead. Found by the first
        # real pytest run: test_committing_an_already_committed_batch_is_rejected
        # expected 409, got 404.
        raise HTTPException(status.HTTP_409_CONFLICT,
                            f"Batch is '{batch.status}' and cannot be committed again")
    if staged is None:
        # Genuinely expired (server restarted, or the STAGE_LIMIT eviction
        # in stage_import dropped it) while the batch itself is still
        # "staged" in the DB - re-staging is the only way forward.
        raise HTTPException(404, "This staged batch has expired. Re-stage the file.")

    new_n = updated_n = deleted_n = 0

    if body.apply_new:
        for row in staged.new_rows:
            payload = {k: v for k, v in row.items()
                       if k in Component.__table__.columns.keys()}
            comp = Component(**payload, source_batch_id=body.batch_id,
                             pending_verification=(row.get("is_chinese") == "UNKNOWN"))
            session.add(comp)
            await session.flush()
            await repository.snapshot(session, comp, "create", list(payload), user.id,
                                      body.batch_id)
            new_n += 1

    if body.apply_updates:
        for change in staged.updated_rows:
            comp = await repository.get_by_component_id(session, change["component_id"])
            if comp is None:
                continue
            await repository.snapshot(session, comp, "update",
                                      list(change["changed"]), user.id, body.batch_id)
            for field, delta in change["changed"].items():
                if field in Component.__table__.columns.keys():
                    setattr(comp, field, change["after"][field])
            comp.revision += 1
            comp.updated_at = utcnow()
            comp.source_batch_id = body.batch_id
            updated_n += 1

    if body.soft_delete_missing:
        for cid in staged.missing_in_file:
            comp = await repository.get_by_component_id(session, cid)
            if comp is None:
                continue
            await repository.snapshot(session, comp, "delete", ["is_deleted"],
                                      user.id, body.batch_id)
            comp.is_deleted = True
            comp.revision += 1
            deleted_n += 1

    batch.status = "committed"
    batch.committed_at = utcnow()
    batch.rows_new, batch.rows_updated, batch.rows_deleted = new_n, updated_n, deleted_n

    await audit.record(session, action="import.committed", actor_id=user.id,
                       entity_type="import_batch", entity_id=body.batch_id,
                       detail={"new": new_n, "updated": updated_n, "deleted": deleted_n,
                               "filename": batch.filename, "sha256": batch.file_sha256})
    _STAGED.pop(body.batch_id, None)
    await repository.cache.rebuild(session)

    return ImportSummary(batch_id=body.batch_id, status="committed", rows_new=new_n,
                         rows_updated=updated_n, rows_unchanged=staged.unchanged,
                         rows_deleted=deleted_n,
                         rows_invalid=len([i for i in staged.invalid
                                           if i.severity == "error"]),
                         committed_at=batch.committed_at)


@router.post("/database/import/{batch_id}/rollback", response_model=ImportSummary)
async def rollback_import(batch_id: str, reason: Annotated[str, Query(min_length=3)],
                          session: Annotated[AsyncSession, Depends(get_session)],
                          user: Annotated[Principal, Depends(requires("database:restore"))]
                          ) -> ImportSummary:
    """Undo a committed import by replaying its revision snapshots in reverse.

    Rows created by the batch are removed; rows it modified are restored to the
    snapshot taken immediately before the change.
    """
    batch = (await session.execute(
        select(ImportBatch).where(ImportBatch.id == batch_id))).scalar_one_or_none()
    if batch is None:
        raise HTTPException(404, "Unknown batch")
    if batch.status != "committed":
        raise HTTPException(status.HTTP_409_CONFLICT,
                            f"Only a committed batch can be rolled back (this one is "
                            f"'{batch.status}')")

    revs = (await session.execute(
        select(ComponentRevision).where(ComponentRevision.batch_id == batch_id)
        .order_by(ComponentRevision.created_at.desc()))).scalars().all()

    restored = removed = 0
    for rev in revs:
        comp = (await session.execute(
            select(Component).where(Component.id == rev.component_pk))).scalar_one_or_none()
        if comp is None:
            continue
        if rev.operation == "create":
            await session.delete(comp)
            removed += 1
        else:
            snap = json.loads(rev.snapshot_json)
            for col in Component.__table__.columns:
                if col.name in snap and col.name not in ("id", "created_at"):
                    value = snap[col.name]
                    if col.name == "confidence_score" and value not in ("", None):
                        value = float(value)
                    if isinstance(col.type.python_type, type) and \
                       col.type.python_type is bool and isinstance(value, str):
                        value = value.lower() in ("true", "1")
                    if col.name in ("updated_at",):
                        continue
                    setattr(comp, col.name, value)
            comp.updated_at = utcnow()
            restored += 1

    batch.status = "rolled_back"
    await audit.record(session, action="import.rolled_back", actor_id=user.id,
                       entity_type="import_batch", entity_id=batch_id,
                       detail={"reason": reason, "restored": restored, "removed": removed})
    await repository.cache.rebuild(session)
    return ImportSummary(batch_id=batch_id, status="rolled_back", rows_new=0,
                         rows_updated=restored, rows_unchanged=0, rows_deleted=removed,
                         rows_invalid=0, committed_at=batch.committed_at)


@router.get("/database/imports")
async def import_history(session: Annotated[AsyncSession, Depends(get_session)],
                         _: Annotated[Principal, Depends(requires("database:import"))],
                         limit: int = Query(50, ge=1, le=500)) -> list[dict]:
    rows = (await session.execute(
        select(ImportBatch).order_by(ImportBatch.created_at.desc()).limit(limit))
    ).scalars().all()
    return [{"batch_id": b.id, "filename": b.filename, "format": b.file_format,
             "sha256": b.file_sha256, "status": b.status, "rows_total": b.rows_total,
             "rows_new": b.rows_new, "rows_updated": b.rows_updated,
             "rows_deleted": b.rows_deleted, "rows_invalid": b.rows_invalid,
             "created_at": b.created_at, "committed_at": b.committed_at} for b in rows]


# --------------------------------------------------------------------------- #
# Export / backup / restore
# --------------------------------------------------------------------------- #
@router.get("/database/export")
async def export_database(session: Annotated[AsyncSession, Depends(get_session)],
                          user: Annotated[Principal, Depends(requires("database:export"))],
                          fmt: str = Query("xlsx", pattern="^(xlsx|csv|json)$"),
                          is_chinese: str = "") -> Response:
    items, _total = await repository.search(session, is_chinese=is_chinese,
                                            page=1, page_size=1_000_000)
    rows = [{c.name: getattr(i, c.name) for c in Component.__table__.columns
             if c.name not in ("id", "source_batch_id")} for i in items]
    meta = {"generated_by": user.id, "db_revision": repository.cache.revision}

    if fmt == "json":
        payload = json.dumps({"exported_at": datetime.now(timezone.utc).isoformat(),
                              "revision": meta["db_revision"], "components": rows},
                             default=str, indent=1).encode()
        media, name = "application/json", "dcov_export.json"
    elif fmt == "csv":
        payload = reports.to_csv(rows)
        media, name = "text/csv", "dcov_export.csv"
    else:
        payload = reports.to_xlsx(rows, meta, "DCOV Component Database")
        media = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        name = "dcov_export.xlsx"

    await audit.record(session, action="database.exported", actor_id=user.id,
                       entity_type="database", entity_id=fmt,
                       detail={"rows": len(rows), "filter": is_chinese})
    return Response(payload, media_type=media,
                    headers={"Content-Disposition": f'attachment; filename="{name}"'})


@router.post("/database/backup")
async def backup(session: Annotated[AsyncSession, Depends(get_session)],
                 user: Annotated[Principal, Depends(requires("database:export"))]) -> dict:
    """Consistent snapshot of the SQLite file (or a pg_dump hint for server mode)."""
    if not settings.database_url.startswith("sqlite"):
        raise HTTPException(501, "For PostgreSQL/MySQL deployments use the database's "
                                 "own backup tooling (pg_dump / mysqldump) - see "
                                 "docs/ADMIN_MANUAL.md, section 'Backup and restore'.")
    src = Path(settings.database_url.split("///")[-1])
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    dest = settings.backup_dir / f"dcov-{stamp}.sqlite"
    import sqlite3
    with sqlite3.connect(src) as s, sqlite3.connect(dest) as d:
        s.backup(d)                      # online backup API: safe with writers active
    digest = reports.body_digest([{"file": dest.name, "size": dest.stat().st_size}])
    await audit.record(session, action="database.backup", actor_id=user.id,
                       entity_type="database", entity_id=dest.name,
                       detail={"bytes": dest.stat().st_size})
    return {"file": dest.name, "path": str(dest), "bytes": dest.stat().st_size,
            "sha256_marker": digest, "created_at": stamp}


@router.post("/database/restore")
async def restore(filename: str, confirm: bool,
                  session: Annotated[AsyncSession, Depends(get_session)],
                  user: Annotated[Principal, Depends(requires("database:restore"))]) -> dict:
    if not confirm:
        raise HTTPException(422, "Restore replaces the live database. Re-send with "
                                 "confirm=true once you have taken a fresh backup.")
    candidate = (settings.backup_dir / filename).resolve()
    if candidate.parent != settings.backup_dir.resolve() or not candidate.exists():
        raise HTTPException(404, "Backup not found in the backup directory")
    live = Path(settings.database_url.split("///")[-1])
    pre = settings.backup_dir / f"pre-restore-{datetime.now(timezone.utc):%Y%m%d-%H%M%S}.sqlite"
    shutil.copy2(live, pre)
    shutil.copy2(candidate, live)
    await audit.record(session, action="database.restored", actor_id=user.id,
                       entity_type="database", entity_id=filename,
                       detail={"pre_restore_copy": pre.name})
    return {"restored_from": filename, "pre_restore_backup": pre.name,
            "note": "Restart the service so all workers reopen the restored file."}
