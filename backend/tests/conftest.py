"""Shared fixtures.

Environment variables are set at *module import time*, before anything under
`app` is imported by any test file — pytest loads a directory's conftest.py
before collecting its test modules, so this is the one place that's early
enough to affect `app.core.config.settings`, which is built once and cached.

Each test session gets its own file-backed SQLite database (not `:memory:` -
an in-memory SQLite database is private to a single connection, and the app
legitimately opens several). The file lives under a temp directory and is
discarded automatically when the process exits.
"""
from __future__ import annotations

import asyncio
import os
import tempfile
from pathlib import Path

_TMP_DIR = Path(tempfile.mkdtemp(prefix="dcov-test-"))
os.environ["DCOV_DATABASE_URL"] = f"sqlite+aiosqlite:///{_TMP_DIR / 'test.sqlite'}"
os.environ["DCOV_SECRET_KEY"] = "test-only-secret-do-not-use-in-production"
os.environ["DCOV_ENVIRONMENT"] = "test"
os.environ["DCOV_FORCE_HTTPS"] = "false"
os.environ["DCOV_DEBUG"] = "true"
# pbkdf2 in tests: bcrypt's fixed cost makes hundreds of logins/test-runs slow
# for no security benefit in a throwaway test database.
os.environ["DCOV_PASSWORD_SCHEME"] = "pbkdf2_sha256"
os.environ["DCOV_BCRYPT_ROUNDS"] = "4"
os.environ["DCOV_RATE_LIMIT_PER_MINUTE"] = "100000"
os.environ["DCOV_UPLOAD_DIR"] = str(_TMP_DIR / "uploads")
os.environ["DCOV_REPORT_DIR"] = str(_TMP_DIR / "reports")
os.environ["DCOV_BACKUP_DIR"] = str(_TMP_DIR / "backups")

import pytest  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

ADMIN_USER = "admin"
ADMIN_PASS = "TestAdminPass123!"
INSPECTOR_USER = "inspector1"
INSPECTOR_PASS = "TestInspectorPass123!"
VIEWER_USER = "viewer1"
VIEWER_PASS = "TestViewerPass123!"


@pytest.fixture(scope="session", autouse=True)
def _bootstrap_users():
    """Creates the schema, three users spanning the role matrix, and loads the
    203-record seed catalogue - once per test session, via the same CLI paths
    an operator would use. Every scan/dashboard/catalog test depends on the
    catalogue being present; without this they'd all see an empty database
    and every scan would come back 'not_found' regardless of what's asserted.
    """
    from app.cli.manage import create_admin, load_seed
    from app.core.database import session_scope
    from app.core.security import hash_password
    from app.models.entities import User

    asyncio.run(create_admin(ADMIN_USER, ADMIN_PASS, "Test Administrator"))

    async def _seed_more():
        async with session_scope() as session:
            session.add(User(username=INSPECTOR_USER, full_name="Test Inspector",
                             role="inspector", password_hash=hash_password(INSPECTOR_PASS),
                             must_change_password=False))
            session.add(User(username=VIEWER_USER, full_name="Test Viewer",
                             role="viewer", password_hash=hash_password(VIEWER_PASS),
                             must_change_password=False))
    asyncio.run(_seed_more())

    seed_path = Path(__file__).resolve().parents[2] / "data" / "components_seed.json"
    asyncio.run(load_seed(str(seed_path)))


@pytest.fixture(scope="session")
def client():
    """A Starlette TestClient, entered as a context manager so the app's
    lifespan (schema creation, index build) actually runs - a bare
    `TestClient(app)` without the `with` does not trigger startup/shutdown."""
    from app.main import app
    with TestClient(app) as c:
        yield c


def _login(client: TestClient, username: str, password: str) -> dict[str, str]:
    r = client.post("/api/v1/auth/login",
                    json={"username": username, "password": password,
                          "device_id": "pytest"})
    assert r.status_code == 200, r.text
    token = r.json()["access_token"]
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture(scope="session")
def admin_headers(client):
    return _login(client, ADMIN_USER, ADMIN_PASS)


@pytest.fixture(scope="session")
def inspector_headers(client):
    return _login(client, INSPECTOR_USER, INSPECTOR_PASS)


@pytest.fixture(scope="session")
def viewer_headers(client):
    return _login(client, VIEWER_USER, VIEWER_PASS)


@pytest.fixture()
def uid():
    """A fresh unique token per test, for client_uuid / usernames / component
    ids that must not collide across the session-scoped shared database."""
    import uuid
    return uuid.uuid4().hex[:12]
