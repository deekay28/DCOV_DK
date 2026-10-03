"""The hash-chained audit log is only worth anything if tampering is actually
detectable - this test corrupts a row directly (bypassing the API, the way a
rogue database-level edit would) and confirms /audit/verify catches it."""
from __future__ import annotations

import asyncio

from sqlalchemy import select, update


def test_audit_verify_detects_a_directly_altered_row(client, admin_headers, uid):
    # generate at least one real audit entry to tamper with
    client.post("/api/v1/components", headers=admin_headers, json={
        "component_name": f"Audit Target {uid}", "part_number": f"AUD-{uid}",
        "manufacturer": "Vendor", "country_of_origin": "India",
    })
    before = client.get("/api/v1/audit/verify", headers=admin_headers).json()
    assert before["intact"] is True

    async def _tamper():
        from app.core.database import session_scope
        from app.models.entities import AuditLog
        async with session_scope() as session:
            row = (await session.execute(
                select(AuditLog).where(AuditLog.action == "component.created")
                .order_by(AuditLog.sequence.desc()).limit(1))).scalar_one()
            original_detail_json = row.detail_json
            await session.execute(
                update(AuditLog).where(AuditLog.id == row.id)
                .values(detail_json='{"tampered": true}'))
        return row.id, original_detail_json
    tampered_id, original_detail_json = asyncio.run(_tamper())

    after = client.get("/api/v1/audit/verify", headers=admin_headers).json()
    assert after["intact"] is False
    assert after["first_broken_sequence"] is not None

    # Restore the row's exact original content - not just any value. The
    # row's stored `hash` was computed over the real original detail_json;
    # writing back anything else (even a plausible-looking placeholder like
    # "{}") would leave the chain just as broken as the tampering did, only
    # less obviously so. This matters beyond just this test: it shares a
    # session-scoped database with every other test in the run, and leaving
    # the corruption in place would make every audit-chain check in every
    # test file that runs afterward see "intact: False" forever, for a
    # reason that has nothing to do with whatever that later test is
    # actually checking. Found the hard way:
    # test_catalog_api.py::test_audit_chain_is_intact_after_normal_operations
    # failed even though nothing in that test file does anything wrong.
    async def _restore():
        from app.core.database import session_scope
        from app.models.entities import AuditLog
        async with session_scope() as session:
            row = await session.get(AuditLog, tampered_id)
            row.detail_json = original_detail_json
    asyncio.run(_restore())

    restored = client.get("/api/v1/audit/verify", headers=admin_headers).json()
    assert restored["intact"] is True, (
        "restoring the tampered row's original content should make the "
        "chain verify clean again - if this fails, the restore itself is "
        "wrong, not just incomplete")
