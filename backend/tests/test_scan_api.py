"""Scan endpoint through the real API - the same cascade already unit-tested
in test_matching.py, now exercised through auth, persistence and the
dashboard counters that depend on it."""
from __future__ import annotations


def test_scan_known_chinese_marking_returns_red(client, admin_headers, uid):
    r = client.post("/api/v1/scan", headers=admin_headers,
                    json={"client_uuid": f"red-{uid}", "input_mode": "manual",
                          "raw_input": "STM32F302C8T6"})
    assert r.status_code == 200
    body = r.json()
    assert body["banner"] == "RED"
    assert body["result"] == "chinese"
    assert body["component"]["is_chinese"] == "YES"


def test_scan_ocr_misread_still_resolves_through_the_api(client, admin_headers, uid):
    r = client.post("/api/v1/scan", headers=admin_headers,
                    json={"client_uuid": f"ocr-{uid}", "input_mode": "ocr",
                          "raw_input": "stm32 f3o2-c8t6"})
    assert r.status_code == 200
    body = r.json()
    assert body["banner"] == "RED"
    assert body["match_method"] == "ocr_corrected"


def test_scan_unknown_marking_returns_grey_and_queues_for_review(client, admin_headers, uid):
    marking = f"NO-SUCH-PART-{uid}"
    r = client.post("/api/v1/scan", headers=admin_headers,
                    json={"client_uuid": f"grey-{uid}", "input_mode": "manual",
                          "raw_input": marking})
    assert r.status_code == 200
    assert r.json()["banner"] == "GREY"

    r = client.get("/api/v1/pending", headers=admin_headers)
    assert r.status_code == 200
    assert any(p["normalized"] == marking.upper().replace("-", "") for p in r.json())


def test_replaying_the_same_client_uuid_does_not_duplicate_history(client, admin_headers, uid):
    payload = {"client_uuid": f"replay-{uid}", "input_mode": "manual",
              "raw_input": "ATMEGA16U2"}
    r1 = client.post("/api/v1/scan", headers=admin_headers, json=payload)
    r2 = client.post("/api/v1/scan", headers=admin_headers, json=payload)
    assert r1.status_code == 200 and r2.status_code == 200
    assert r1.json()["scan_id"] == r2.json()["scan_id"]
    assert "Replay" in " ".join(r2.json()["notes"])

    hist = client.get("/api/v1/scan/history", headers=admin_headers,
                      params={"days": 1, "page_size": 500}).json()
    matches = [h for h in hist["items"] if h["raw_input"] == "ATMEGA16U2"
              and h["id"] == r1.json()["scan_id"]]
    assert len(matches) == 1


def test_batch_scan_processes_every_item(client, admin_headers, uid):
    r = client.post("/api/v1/scan/batch", headers=admin_headers, json={"scans": [
        {"client_uuid": f"batch-{uid}-1", "input_mode": "manual", "raw_input": "STM32F302C8T6"},
        {"client_uuid": f"batch-{uid}-2", "input_mode": "manual", "raw_input": "ATMEGA16U2"},
        {"client_uuid": f"batch-{uid}-3", "input_mode": "manual", "raw_input": "NOPE-XYZ"},
    ]})
    assert r.status_code == 200
    banners = [item["banner"] for item in r.json()]
    assert banners == ["RED", "GREEN", "GREY"]


def test_dashboard_reflects_scan_activity(client, admin_headers, uid):
    client.post("/api/v1/scan", headers=admin_headers,
               json={"client_uuid": f"dash-{uid}", "input_mode": "manual",
                     "raw_input": "STM32F302C8T6"})
    r = client.get("/api/v1/dashboard", headers=admin_headers)
    assert r.status_code == 200
    body = r.json()
    assert body["total_components"] > 0
    assert body["scans_today"] >= 1


def test_sync_push_is_idempotent_and_reports_duplicates(client, admin_headers, uid):
    payload = {"device_id": f"device-{uid}", "scans": [
        {"client_uuid": f"sync-{uid}", "input_mode": "manual", "raw_input": "ATMEGA16U2"},
    ]}
    r1 = client.post("/api/v1/sync/push", headers=admin_headers, json=payload)
    r2 = client.post("/api/v1/sync/push", headers=admin_headers, json=payload)
    assert r1.json()["accepted"] == 1
    assert r2.json()["accepted"] == 0
    assert r2.json()["duplicates"] == 1


def test_sync_pull_returns_the_catalogue(client, admin_headers, uid):
    r = client.get("/api/v1/sync/pull", headers=admin_headers,
                   params={"device_id": f"device-{uid}"})
    assert r.status_code == 200
    body = r.json()
    assert body["db_revision"] >= 1
    assert len(body["components_changed"]) > 0


# --------------------------------------------------------------------------- #
# Anti-remark marking check, end to end through the API.

def test_china_country_code_on_package_overrides_non_chinese_catalogue(client, admin_headers, uid):
    # STM32G484 is catalogued Philippines / non-Chinese. Same part number, but
    # this unit's package reads CHN - the unit's own marking must win.
    base = client.post("/api/v1/scan", headers=admin_headers,
                       json={"client_uuid": f"mk-base-{uid}", "input_mode": "manual",
                             "raw_input": "STM32G484"}).json()
    assert base["result"] != "chinese"
    assert base["marking_findings"] == []

    r = client.post("/api/v1/scan", headers=admin_headers,
                    json={"client_uuid": f"mk-cn-{uid}", "input_mode": "ocr",
                          "raw_input": "STM32G484",
                          "ocr_text": "32G484CEU6\nGQ 22X 7A\nCHN 31 4C2"})
    assert r.status_code == 200
    body = r.json()
    assert body["banner"] == "RED" and body["result"] == "chinese"
    assert body["headline"] == "CHINESE ORIGIN MARKED ON PACKAGE"
    assert [f["code"] for f in body["marking_findings"]] == \
        ["unit_marked_china_catalogue_non_chinese"]


def test_marking_findings_survive_an_offline_replay(client, admin_headers, uid):
    payload = {"client_uuid": f"mk-replay-{uid}", "input_mode": "ocr",
               "raw_input": "STM32G484", "ocr_text": "32G484CEU6\nGK 22X 7A\nPHL 31 4C2"}
    first = client.post("/api/v1/scan", headers=admin_headers, json=payload).json()
    again = client.post("/api/v1/scan", headers=admin_headers, json=payload).json()
    assert first["banner"] == again["banner"] == "RED"
    assert first["marking_findings"] == again["marking_findings"]
    assert first["marking_findings"][0]["code"] == "site_code_contradicts_country_code"
