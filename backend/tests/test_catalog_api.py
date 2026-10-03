"""Component catalogue and the import wizard's stage -> commit -> rollback
flow, through the real API - the highest-risk surface in the system, since a
bad import can silently flip a component's origin verdict."""
from __future__ import annotations

import io


def test_create_component_requires_change_and_derives_verdict(client, admin_headers, uid):
    r = client.post("/api/v1/components", headers=admin_headers, json={
        "component_name": f"Test Part {uid}", "part_number": f"TP-{uid}",
        "manufacturer": "Some Vendor", "country_of_origin": "China",
    })
    assert r.status_code == 201
    body = r.json()
    assert body["is_chinese"] == "YES"          # derived from country_of_origin, not asserted directly
    assert body["criticality"] in ("REVIEW", "NON-CRITICAL", "CRITICAL")


def test_creating_a_duplicate_component_id_is_rejected(client, admin_headers, uid):
    payload = {"component_name": f"Dup {uid}", "part_number": f"DUP-{uid}",
              "manufacturer": "Vendor", "country_of_origin": "India"}
    r1 = client.post("/api/v1/components", headers=admin_headers, json=payload)
    assert r1.status_code == 201
    r2 = client.post("/api/v1/components", headers=admin_headers, json=payload)
    assert r2.status_code == 409


def test_update_component_requires_a_change_reason(client, admin_headers, uid):
    created = client.post("/api/v1/components", headers=admin_headers, json={
        "component_name": f"Editable {uid}", "part_number": f"ED-{uid}",
        "manufacturer": "Vendor", "country_of_origin": "USA",
    }).json()
    cid = created["component_id"]

    r = client.patch(f"/api/v1/components/{cid}", headers=admin_headers,
                     json={"remarks": "updated without a reason"})
    assert r.status_code == 422, "change_reason is required by ComponentUpdate"

    r = client.patch(f"/api/v1/components/{cid}", headers=admin_headers,
                     json={"country_of_origin": "China",
                           "change_reason": "re-inspected, marking confirms Chinese origin"})
    assert r.status_code == 200
    assert r.json()["is_chinese"] == "YES"       # re-derived from the new country

    hist = client.get(f"/api/v1/components/{cid}/history", headers=admin_headers).json()
    assert any(h["operation"] == "update" for h in hist)


def test_bulk_update_rejects_identity_and_origin_fields(client, admin_headers, uid):
    created = client.post("/api/v1/components", headers=admin_headers, json={
        "component_name": f"Bulk {uid}", "part_number": f"BLK-{uid}",
        "manufacturer": "Vendor", "country_of_origin": "India",
    }).json()
    r = client.post("/api/v1/components/bulk-update", headers=admin_headers, json={
        "component_ids": [created["component_id"]],
        "changes": {"country_of_origin": "China"},
        "reason": "attempting to bulk-flip origin",
    })
    assert r.status_code == 422, (
        "bulk update must reject origin/identity fields - those require a "
        "row-by-row change_reason, not a batch operation")


def test_import_stage_does_not_write_to_the_live_catalogue(client, admin_headers, uid):
    csv_bytes = (
        f"component_name,part_number,manufacturer,country_of_origin\n"
        f"Staged Only {uid},STG-{uid},Vendor X,China\n"
    ).encode()
    r = client.post("/api/v1/database/import/stage", headers=admin_headers,
                    files={"file": (f"stage-{uid}.csv", io.BytesIO(csv_bytes), "text/csv")})
    assert r.status_code == 200
    preview = r.json()
    assert preview["rows_new"] == 1
    batch_id = preview["batch_id"]

    # not yet visible in the catalogue - staging must not write
    r = client.get("/api/v1/components", headers=admin_headers,
                   params={"q": f"STG-{uid}"})
    assert r.json()["total"] == 0


def test_import_commit_then_rollback_round_trip(client, admin_headers, uid):
    csv_bytes = (
        f"component_name,part_number,manufacturer,country_of_origin\n"
        f"Roundtrip Part {uid},RT-{uid},Vendor Y,China\n"
    ).encode()
    staged = client.post("/api/v1/database/import/stage", headers=admin_headers,
                         files={"file": (f"rt-{uid}.csv", io.BytesIO(csv_bytes), "text/csv")}
                        ).json()
    batch_id = staged["batch_id"]

    committed = client.post("/api/v1/database/import/commit", headers=admin_headers, json={
        "batch_id": batch_id, "apply_updates": True, "apply_new": True,
        "soft_delete_missing": False, "confirm": True,
    })
    assert committed.status_code == 200
    assert committed.json()["rows_new"] == 1

    found = client.get("/api/v1/components", headers=admin_headers,
                       params={"q": f"RT-{uid}"}).json()
    assert found["total"] == 1
    assert found["items"][0]["is_chinese"] == "YES"

    rolled_back = client.post(
        f"/api/v1/database/import/{batch_id}/rollback",
        headers=admin_headers, params={"reason": "test rollback"})
    assert rolled_back.status_code == 200

    found_after = client.get("/api/v1/components", headers=admin_headers,
                             params={"q": f"RT-{uid}"}).json()
    assert found_after["total"] == 0, "rollback should remove the row the import created"


def test_committing_an_already_committed_batch_is_rejected(client, admin_headers, uid):
    csv_bytes = (f"component_name,part_number,country_of_origin\n"
                f"Once Only {uid},ONCE-{uid},India\n").encode()
    staged = client.post("/api/v1/database/import/stage", headers=admin_headers,
                         files={"file": ("f.csv", io.BytesIO(csv_bytes), "text/csv")}).json()
    body = {"batch_id": staged["batch_id"], "apply_updates": True, "apply_new": True,
           "soft_delete_missing": False, "confirm": True}
    r1 = client.post("/api/v1/database/import/commit", headers=admin_headers, json=body)
    r2 = client.post("/api/v1/database/import/commit", headers=admin_headers, json=body)
    assert r1.status_code == 200
    assert r2.status_code == 409


def test_export_returns_a_nonempty_workbook(client, admin_headers):
    r = client.get("/api/v1/database/export", headers=admin_headers, params={"fmt": "xlsx"})
    assert r.status_code == 200
    assert len(r.content) > 1000
    assert r.headers["content-type"].startswith(
        "application/vnd.openxmlformats-officedocument")


def test_reports_generate_in_all_three_formats(client, admin_headers):
    for fmt in ("pdf", "xlsx", "csv"):
        r = client.get(f"/api/v1/reports/chinese_components", headers=admin_headers,
                       params={"fmt": fmt})
        assert r.status_code == 200, f"{fmt} report failed: {r.text}"
        assert len(r.content) > 200


def test_audit_chain_is_intact_after_normal_operations(client, admin_headers):
    r = client.get("/api/v1/audit/verify", headers=admin_headers)
    assert r.status_code == 200
    assert r.json()["intact"] is True
