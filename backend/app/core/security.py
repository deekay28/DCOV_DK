"""Authentication, hashing, RBAC and tamper-evident audit helpers."""
from __future__ import annotations

import hashlib
import hmac
import json
import secrets
from datetime import datetime, timedelta, timezone
from enum import StrEnum
from typing import Annotated, Any

from fastapi import Depends, HTTPException, Request, status
from fastapi.security import OAuth2PasswordBearer
from jose import JWTError, jwt
from passlib.context import CryptContext

from app.core.config import settings

# Scheme is configurable because bcrypt (via the `bcrypt` package) is a native
# extension that some environments (notably Termux/Android, where there is no
# manylinux wheel and building it means a Rust toolchain on a phone) would
# rather avoid. DCOV_PASSWORD_SCHEME=pbkdf2_sha256 is pure Python, needs no
# compiled extension, and is still an acceptable KDF for this threat model.
# Existing bcrypt hashes keep verifying either way; passlib handles both.
# Deduplicated while preserving order: DCOV_PASSWORD_SCHEME (settings.
# password_scheme) can itself be "bcrypt" or "pbkdf2_sha256" - both already
# hardcoded below as fallback/legacy-verification options - and passlib's
# CryptContext raises a hard KeyError ("multiple handlers with same name")
# if the same scheme name appears twice in this list. This is exactly what
# happened the first time the test suite actually ran: conftest.py sets
# DCOV_PASSWORD_SCHEME=pbkdf2_sha256 for fast tests, which duplicated the
# pbkdf2_sha256 already listed here and broke every single test that
# touched auth, not just password-hashing tests specifically - the whole
# CryptContext fails to construct at import time. dict.fromkeys(...) is the
# standard Python idiom for order-preserving deduplication.
_password_schemes = list(dict.fromkeys([settings.password_scheme, "bcrypt", "pbkdf2_sha256"]))
pwd_context = CryptContext(
    schemes=_password_schemes,
    default=settings.password_scheme, deprecated="auto",
    bcrypt__rounds=settings.bcrypt_rounds,
    pbkdf2_sha256__rounds=settings.pbkdf2_rounds)
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/api/v1/auth/login", auto_error=False)


class Role(StrEnum):
    ADMINISTRATOR = "administrator"
    DATABASE_MANAGER = "database_manager"
    INSPECTOR = "inspector"
    VIEWER = "viewer"


# Permission -> roles allowed. Deny by default.
PERMISSIONS: dict[str, set[Role]] = {
    "component:read":    {Role.ADMINISTRATOR, Role.DATABASE_MANAGER, Role.INSPECTOR, Role.VIEWER},
    "component:write":   {Role.ADMINISTRATOR, Role.DATABASE_MANAGER},
    "component:delete":  {Role.ADMINISTRATOR},
    "database:import":   {Role.ADMINISTRATOR, Role.DATABASE_MANAGER},
    "database:export":   {Role.ADMINISTRATOR, Role.DATABASE_MANAGER},
    "database:restore":  {Role.ADMINISTRATOR},
    "scan:execute":      {Role.ADMINISTRATOR, Role.DATABASE_MANAGER, Role.INSPECTOR},
    "inspection:create": {Role.ADMINISTRATOR, Role.INSPECTOR},
    "inspection:sign":   {Role.ADMINISTRATOR, Role.INSPECTOR},
    "inspection:read":   {Role.ADMINISTRATOR, Role.DATABASE_MANAGER, Role.INSPECTOR, Role.VIEWER},
    "report:generate":   {Role.ADMINISTRATOR, Role.DATABASE_MANAGER, Role.INSPECTOR, Role.VIEWER},
    "user:manage":       {Role.ADMINISTRATOR},
    "audit:read":        {Role.ADMINISTRATOR},
}


# --------------------------------------------------------------------------- #
# Passwords / PINs
# --------------------------------------------------------------------------- #
def hash_password(raw: str) -> str:
    return pwd_context.hash(raw)


def verify_password(raw: str, hashed: str) -> bool:
    return pwd_context.verify(raw, hashed)


def hash_pin(pin: str, user_id: str) -> str:
    """PINs are short, so they are salted with the user id before bcrypt."""
    return pwd_context.hash(f"{user_id}:{pin}")


def verify_pin(pin: str, user_id: str, hashed: str) -> bool:
    return pwd_context.verify(f"{user_id}:{pin}", hashed)


PASSWORD_RULES = (
    (lambda p: len(p) >= 12, "must be at least 12 characters"),
    (lambda p: any(c.isupper() for c in p), "must contain an upper-case letter"),
    (lambda p: any(c.islower() for c in p), "must contain a lower-case letter"),
    (lambda p: any(c.isdigit() for c in p), "must contain a digit"),
    (lambda p: any(not c.isalnum() for c in p), "must contain a symbol"),
)


def validate_password(raw: str) -> None:
    failures = [msg for rule, msg in PASSWORD_RULES if not rule(raw)]
    if failures:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY,
                            detail="Password " + "; ".join(failures))


# --------------------------------------------------------------------------- #
# Tokens
# --------------------------------------------------------------------------- #
def _encode(payload: dict[str, Any], ttl: timedelta, kind: str) -> str:
    now = datetime.now(timezone.utc)
    body = payload | {"iat": now, "exp": now + ttl, "typ": kind,
                      "jti": secrets.token_urlsafe(16)}
    return jwt.encode(body, settings.secret_key, algorithm=settings.algorithm)


def create_access_token(user_id: str, role: str, device_id: str | None = None) -> str:
    return _encode({"sub": user_id, "role": role, "did": device_id},
                   timedelta(minutes=settings.access_token_minutes), "access")


def create_refresh_token(user_id: str) -> str:
    return _encode({"sub": user_id}, timedelta(days=settings.refresh_token_days), "refresh")


def decode_token(token: str, expect: str = "access") -> dict[str, Any]:
    try:
        claims = jwt.decode(token, settings.secret_key, algorithms=[settings.algorithm])
    except JWTError as exc:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid or expired token",
                            headers={"WWW-Authenticate": "Bearer"}) from exc
    if claims.get("typ") != expect:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Wrong token type")
    return claims


# --------------------------------------------------------------------------- #
# Dependencies
# --------------------------------------------------------------------------- #
class Principal:
    __slots__ = ("id", "role", "device_id", "jti")

    def __init__(self, claims: dict[str, Any]):
        self.id = claims["sub"]
        self.role = Role(claims["role"])
        self.device_id = claims.get("did")
        self.jti = claims.get("jti")

    def can(self, permission: str) -> bool:
        return self.role in PERMISSIONS.get(permission, set())


async def current_user(request: Request,
                       token: Annotated[str | None, Depends(oauth2_scheme)]) -> Principal:
    if not token:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Not authenticated",
                            headers={"WWW-Authenticate": "Bearer"})
    principal = Principal(decode_token(token))
    if await is_revoked(request, principal.jti):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Session revoked")
    request.state.principal = principal
    return principal


async def is_revoked(request: Request, jti: str | None) -> bool:
    store: set[str] = getattr(request.app.state, "revoked_jti", set())
    return bool(jti and jti in store)


def requires(permission: str):
    """Route dependency: `Depends(requires("component:write"))`."""
    async def _guard(user: Annotated[Principal, Depends(current_user)]) -> Principal:
        if not user.can(permission):
            raise HTTPException(status.HTTP_403_FORBIDDEN,
                                f"Role '{user.role}' lacks permission '{permission}'")
        return user
    return _guard


# --------------------------------------------------------------------------- #
# Tamper-evident audit chain
# --------------------------------------------------------------------------- #
GENESIS = "0" * 64


def audit_digest(prev_hash: str, event: dict[str, Any]) -> str:
    """SHA-256 over (previous hash || canonical event JSON), keyed with the app secret.

    Any retrospective edit or deletion of a row breaks every subsequent digest,
    which `verify_audit_chain` detects.
    """
    canonical = json.dumps(event, sort_keys=True, separators=(",", ":"), default=str)
    return hmac.new(settings.secret_key.encode(),
                    f"{prev_hash}{canonical}".encode(), hashlib.sha256).hexdigest()


def verify_audit_chain(rows: list[dict[str, Any]]) -> tuple[bool, int | None]:
    """Return (intact, index_of_first_broken_row)."""
    prev = GENESIS
    for i, row in enumerate(rows):
        event = {k: v for k, v in row.items() if k not in ("hash", "prev_hash", "id")}
        if audit_digest(prev, event) != row["hash"] or row["prev_hash"] != prev:
            return False, i
        prev = row["hash"]
    return True, None


def sign_inspection(payload: dict[str, Any], user_id: str) -> str:
    """Detached HMAC signature over the frozen inspection record."""
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"), default=str)
    return hmac.new(settings.secret_key.encode(),
                    f"{user_id}|{canonical}".encode(), hashlib.sha256).hexdigest()
