"""Auth flow, account lockout and role-based access, through the real API."""
from __future__ import annotations

from tests.conftest import ADMIN_PASS, ADMIN_USER, INSPECTOR_PASS, INSPECTOR_USER


def test_login_success_returns_role_and_token(client):
    r = client.post("/api/v1/auth/login",
                    json={"username": ADMIN_USER, "password": ADMIN_PASS,
                          "device_id": "pytest"})
    assert r.status_code == 200
    body = r.json()
    assert body["role"] == "administrator"
    assert body["token_type"] == "bearer"
    assert len(body["access_token"]) > 20


def test_wrong_password_is_rejected_without_distinguishing_reason(client):
    r1 = client.post("/api/v1/auth/login",
                     json={"username": ADMIN_USER, "password": "wrong-password-xx"})
    r2 = client.post("/api/v1/auth/login",
                     json={"username": "no-such-user", "password": "irrelevant123"})
    assert r1.status_code == 401
    assert r2.status_code == 401
    # same generic message either way - the API must not reveal which part was wrong
    assert r1.json()["detail"] == r2.json()["detail"]


def test_me_requires_a_token(client):
    r = client.get("/api/v1/auth/me")
    assert r.status_code == 401


def test_me_returns_the_authenticated_users_profile(client, admin_headers):
    r = client.get("/api/v1/auth/me", headers=admin_headers)
    assert r.status_code == 200
    assert r.json()["username"] == ADMIN_USER
    assert r.json()["role"] == "administrator"


def test_account_locks_after_repeated_failed_logins(client, uid):
    """Uses a dedicated throwaway user so this test can't lock out the shared
    session-scoped admin/inspector fixtures other tests depend on."""
    username = f"locktest-{uid}"
    password = "InitialPassw0rd!!"
    r = client.post("/api/v1/auth/users",
                    json={"username": username, "password": password, "role": "viewer"},
                    headers=_admin_headers(client))
    assert r.status_code == 201

    # Deliberately wrong, but still schema-valid: LoginRequest.password has
    # min_length=8 (see app/models/schemas.py), and the original "bad" here
    # was only 3 characters. Every one of the 5 "failed" attempts was
    # actually getting rejected by Pydantic request validation (422) before
    # ever reaching login()'s code - meaning _reject() never ran, the
    # failed_logins counter never incremented, and this test had never
    # once exercised the lockout logic it was named for. Found only by
    # printing the real per-request status codes: three separate,
    # completely real bugs in get_session()/UTCDateTime/the audit sequence
    # column got found and fixed chasing this same "200 != 423" failure
    # before finding that the actual cause, for this specific test, was
    # the test's own fixture data - all of which are still worth having
    # fixed, they just weren't what was breaking this one.
    wrong_password = "WrongPassw0rd!!"
    for _ in range(5):
        resp = client.post("/api/v1/auth/login",
                           json={"username": username, "password": wrong_password})
        assert resp.status_code == 401, (
            f"expected a genuine auth rejection (401), got {resp.status_code} - "
            f"if this is 422, the wrong-password fixture value above is no "
            f"longer valid against LoginRequest's schema")

    r = client.post("/api/v1/auth/login", json={"username": username, "password": password})
    assert r.status_code == 423, "account should be locked after the configured failed-attempt limit"


def _admin_headers(client) -> dict[str, str]:
    r = client.post("/api/v1/auth/login", json={"username": ADMIN_USER, "password": ADMIN_PASS})
    return {"Authorization": f"Bearer {r.json()['access_token']}"}


def test_viewer_cannot_create_users(client, viewer_headers):
    r = client.post("/api/v1/auth/users",
                    json={"username": "shouldnotexist", "password": "SomePassw0rd!!",
                          "role": "viewer"},
                    headers=viewer_headers)
    assert r.status_code == 403


def test_viewer_cannot_write_components_but_can_read_them(client, viewer_headers):
    r = client.get("/api/v1/components", headers=viewer_headers)
    assert r.status_code == 200
    r = client.post("/api/v1/components",
                    json={"component_name": "Should Fail", "part_number": "NOPE-1"},
                    headers=viewer_headers)
    assert r.status_code == 403


def test_inspector_can_scan_but_not_import(client, inspector_headers, uid):
    r = client.post("/api/v1/scan", headers=inspector_headers,
                    json={"client_uuid": f"rbac-{uid}", "input_mode": "manual",
                          "raw_input": "ATMEGA16U2"})
    assert r.status_code == 200

    r = client.post("/api/v1/database/import/stage", headers=inspector_headers,
                    files={"file": ("x.csv", b"a,b\n1,2\n", "text/csv")})
    assert r.status_code == 403


def test_administrator_cannot_demote_their_own_last_admin_role(client, admin_headers):
    me = client.get("/api/v1/auth/me", headers=admin_headers).json()
    r = client.patch(f"/api/v1/auth/users/{me['id']}/role?role=viewer", headers=admin_headers)
    assert r.status_code == 422


def test_pin_login_is_rejected_from_a_device_that_never_password_logged_in(client, admin_headers, uid):
    """A PIN is 4-12 digits - it must not work as a standalone credential from
    an arbitrary device. It should only work from a device_id that has
    already completed a real password login."""
    username = f"pintest-{uid}"
    password = "PinTestPassw0rd!!"
    r = client.post("/api/v1/auth/users",
                    json={"username": username, "password": password, "role": "viewer"},
                    headers=admin_headers)
    assert r.status_code == 201

    known_device = f"known-device-{uid}"
    login = client.post("/api/v1/auth/login",
                        json={"username": username, "password": password,
                              "device_id": known_device})
    assert login.status_code == 200
    pin_token = login.json()["access_token"]

    r = client.post("/api/v1/auth/pin", params={"pin": "483920"},
                    headers={"Authorization": f"Bearer {pin_token}"})
    assert r.status_code == 204

    # the enrolling device may now use the PIN
    ok = client.post("/api/v1/auth/login/pin",
                     json={"username": username, "pin": "483920", "device_id": known_device})
    assert ok.status_code == 200

    # a device that never completed a password login may not, even with the
    # correct PIN
    stranger_device = f"stranger-device-{uid}"
    blocked = client.post("/api/v1/auth/login/pin",
                          json={"username": username, "pin": "483920",
                                "device_id": stranger_device})
    assert blocked.status_code == 401
