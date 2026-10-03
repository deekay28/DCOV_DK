"""Field workflow through the HTTP API: photo upload, duplicate handling,
offline sync, token refresh, and the evidence fields on every scan result."""
from __future__ import annotations

import shutil

import pytest

from .conftest import ADMIN_PASS, ADMIN_USER


def test_scan_result_carries_evidence_and_policy(client, admin_headers, uid):
    r = client.post("/api/v1/scan", headers=admin_headers,
                    json={"client_uuid": f"ev-{uid}", "input_mode": "manual",
                          "raw_input": "ADF4350"})
    b = r.json()
    assert b["banner"] == "GREEN"
    assert b["origin_evidence"] == "component"
    assert b["evidence_detail"] and b["policy_decision"].startswith("ACCEPTABLE")
    assert b["review_required"] is False


def test_replayed_scan_is_not_duplicated(client, admin_headers, uid):
    body = {"client_uuid": f"dup-{uid}", "input_mode": "manual", "raw_input": "STM32F302C8T6"}
    a = client.post("/api/v1/scan", headers=admin_headers, json=body).json()
    b = client.post("/api/v1/scan", headers=admin_headers, json=body).json()
    assert a["scan_id"] == b["scan_id"]
    assert any("Replay" in n for n in b["notes"])


def test_sync_push_reports_duplicates(client, admin_headers, uid):
    scans = [{"client_uuid": f"off-{uid}-{i}", "input_mode": "manual",
              "raw_input": "STM32F302C8T6"} for i in range(3)]
    r1 = client.post("/api/v1/sync/push", headers=admin_headers,
                     json={"device_id": "pytest", "scans": scans}).json()
    r2 = client.post("/api/v1/sync/push", headers=admin_headers,
                     json={"device_id": "pytest", "scans": scans}).json()
    assert r1["accepted"] == 3 and r2["duplicates"] == 3 and r2["accepted"] == 0


def test_refresh_token_in_json_body(client):
    r = client.post("/api/v1/auth/login", json={"username": ADMIN_USER, "password": ADMIN_PASS,
                                                "device_id": "pytest-refresh"})
    refresh = r.json()["refresh_token"]
    r2 = client.post("/api/v1/auth/refresh", json={"refresh_token": refresh})
    assert r2.status_code == 200, r2.text
    assert r2.json()["access_token"]
    # legacy query-string form still accepted
    r3 = client.post(f"/api/v1/auth/refresh?refresh_token={r2.json()['refresh_token']}")
    assert r3.status_code == 200
    # an access token is not a refresh token
    r4 = client.post("/api/v1/auth/refresh", json={"refresh_token": r2.json()["access_token"]})
    assert r4.status_code == 401


def test_invalid_image_upload_rejected(client, admin_headers, uid):
    r = client.post("/api/v1/scan/ocr", headers=admin_headers,
                    data={"client_uuid": f"img-{uid}"},
                    files={"image": ("x.txt", b"hello", "text/plain")})
    assert r.status_code == 415


@pytest.mark.skipif(shutil.which("tesseract") is None, reason="tesseract not installed")
def test_photo_upload_ocr_only_then_confirmed_scan_links_image(client, admin_headers, uid):
    pytest.importorskip("cv2")
    from .chip_images import chip, jpeg
    img = jpeg(chip(["STM32F302C8T6", "CHN 302"]))
    r = client.post("/api/v1/scan/ocr", headers=admin_headers,
                    data={"client_uuid": f"ph-{uid}", "auto_lookup": "false"},
                    files={"image": ("chip.jpg", img, "image/jpeg")})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["ocr"]["best"] == "STM32F302C8T6"
    assert body["result"] is None                    # OCR only - no scan recorded yet
    ref = body["image_path"]
    assert ref.startswith("scans/")

    s = client.post("/api/v1/scan", headers=admin_headers,
                    json={"client_uuid": f"ph-{uid}", "input_mode": "ocr",
                          "raw_input": body["ocr"]["best"], "ocr_text": body["ocr"]["full_text"],
                          "image_ref": ref}).json()
    assert s["banner"] == "RED"
    hist = client.get("/api/v1/scan/history", headers=admin_headers,
                      params={"page_size": 200}).json()["items"]
    rec = next(h for h in hist if h["id"] == s["scan_id"])
    assert rec["images"] == [ref]
    assert sum(1 for h in hist if h["raw_input"] == "STM32F302C8T6"
               and h["id"] == s["scan_id"]) == 1


def test_image_ref_outside_uploads_is_ignored(client, admin_headers, uid):
    s = client.post("/api/v1/scan", headers=admin_headers,
                    json={"client_uuid": f"trav-{uid}", "input_mode": "manual",
                          "raw_input": "ADF4350", "image_ref": "scans/../../etc/passwd"}).json()
    hist = client.get("/api/v1/scan/history", headers=admin_headers,
                      params={"page_size": 200}).json()["items"]
    rec = next(h for h in hist if h["id"] == s["scan_id"])
    assert rec["images"] == []


@pytest.mark.skipif(shutil.which("tesseract") is None, reason="tesseract not installed")
def test_multi_chip_photo_creates_one_scan_per_package(client, admin_headers, uid):
    pytest.importorskip("cv2")
    from .chip_images import board, chip, jpeg
    img = jpeg(board([chip(["STM32F302C8T6", "CHN"]), chip(["MX25L12833F", "TWN"], seed=3)]))
    r = client.post("/api/v1/scan/ocr", headers=admin_headers,
                    data={"client_uuid": f"mc-{uid}", "multi_chip": "true"},
                    files={"image": ("board.jpg", img, "image/jpeg")})
    body = r.json()
    assert body["result"] is None
    by_part = {x["normalized_input"]: x["banner"] for x in body["results"]}
    assert by_part.get("STM32F302C8T6") == "RED"
    assert by_part.get("MX25L12833F") == "GREEN"      # not contaminated by the other chip's CHN


def test_trusted_hosts_setting_exists():
    from app.core.config import settings
    assert isinstance(settings.trusted_hosts, list)


def test_pin_enrolment_accepts_json_body(client, inspector_headers):
    r = client.post("/api/v1/auth/pin", headers=inspector_headers, json={"pin": "582047"})
    assert r.status_code == 204, r.text
    r = client.post("/api/v1/auth/pin", headers=inspector_headers, json={"pin": "1234"})
    assert r.status_code == 422
