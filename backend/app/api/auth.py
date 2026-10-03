"""Authentication: password, PIN, biometric-assertion, refresh, user admin."""
from __future__ import annotations

import json
import secrets
from datetime import datetime, timedelta, timezone
from typing import Annotated

from pydantic import BaseModel
from fastapi import APIRouter, Depends, HTTPException, Request, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.database import get_session
from app.core.security import (Principal, Role, create_access_token, create_refresh_token,
                               current_user, decode_token, hash_password, hash_pin,
                               requires, validate_password, verify_password, verify_pin)
from app.models.entities import User, utcnow
from app.models.schemas import (BiometricLoginRequest, LoginRequest, PasswordChange,
                                PinLoginRequest, TokenPair, UserCreate, UserOut)
from app.services import audit

router = APIRouter(prefix="/auth", tags=["auth"])

# device_id -> (nonce, expiry). In a multi-worker deployment this belongs in Redis.
_NONCES: dict[str, tuple[str, datetime]] = {}


def _client_ip(request: Request) -> str:
    fwd = request.headers.get("x-forwarded-for", "")
    return (fwd.split(",")[0].strip() if fwd else
            (request.client.host if request.client else ""))


async def _load_user(session: AsyncSession, username: str) -> User | None:
    return (await session.execute(
        select(User).where(User.username == username))).scalar_one_or_none()


async def _reject(session: AsyncSession, request: Request, user: User | None,
                  username: str, reason: str) -> HTTPException:
    """Uniform failure. The response never distinguishes 'no such user' from
    'wrong password' - that difference is a user-enumeration oracle."""
    if user is not None:
        user.failed_logins += 1
        if user.failed_logins >= settings.max_failed_logins:
            user.locked_until = utcnow() + timedelta(minutes=settings.lockout_minutes)
    await audit.record(session, action="auth.login_failed", actor_username=username,
                       entity_type="user", entity_id=user.id if user else "",
                       detail={"reason": reason}, ip=_client_ip(request),
                       user_agent=request.headers.get("user-agent", ""))
    return HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid credentials",
                         headers={"WWW-Authenticate": "Bearer"})


async def _issue(session: AsyncSession, request: Request, user: User,
                 device_id: str, method: str, *, trust_device: bool = False) -> TokenPair:
    user.failed_logins = 0
    user.locked_until = None
    user.last_login = utcnow()
    if trust_device and device_id:
        devices: list[str] = json.loads(user.trusted_device_ids or "[]")
        if device_id not in devices:
            devices.append(device_id)
            # cap the list rather than let it grow unbounded across a career's
            # worth of phones - drop the oldest entries first
            user.trusted_device_ids = json.dumps(devices[-20:])
    await audit.record(session, action="auth.login", actor_id=user.id,
                       actor_username=user.username, entity_type="user",
                       entity_id=user.id, detail={"method": method, "device": device_id},
                       ip=_client_ip(request),
                       user_agent=request.headers.get("user-agent", ""))
    return TokenPair(
        access_token=create_access_token(user.id, user.role, device_id),
        refresh_token=create_refresh_token(user.id),
        expires_in=settings.access_token_minutes * 60,
        role=user.role, must_change_password=user.must_change_password)


def _guard_active(user: User | None) -> None:
    if user is None:
        return
    if user.locked_until and user.locked_until > utcnow():
        wait = int((user.locked_until - utcnow()).total_seconds() // 60) + 1
        raise HTTPException(status.HTTP_423_LOCKED,
                            f"Account locked after repeated failed attempts. "
                            f"Try again in {wait} minute(s) or contact an administrator.")


# --------------------------------------------------------------------------- #
@router.post("/login", response_model=TokenPair)
async def login(body: LoginRequest, request: Request,
                session: Annotated[AsyncSession, Depends(get_session)]) -> TokenPair:
    user = await _load_user(session, body.username)
    _guard_active(user)
    if user is None or not user.is_active or not verify_password(body.password, user.password_hash):
        raise await _reject(session, request, user, body.username, "bad_password")
    return await _issue(session, request, user, body.device_id, "password", trust_device=True)


@router.post("/login/pin", response_model=TokenPair)
async def login_pin(body: PinLoginRequest, request: Request,
                    session: Annotated[AsyncSession, Depends(get_session)]) -> TokenPair:
    """PIN unlock for a device that has already completed a full password (or
    biometric) login. Device binding is enforced, not just documented: the
    incoming device_id must already appear in the user's trusted-device list,
    which only a successful password/biometric login ever populates (see
    _issue). A PIN is 4-12 digits - without this check it would be a weak
    password usable from anywhere, not a convenience for a known device.
    """
    user = await _load_user(session, body.username)
    _guard_active(user)
    if user is None or not user.is_active or not user.pin_hash \
            or not verify_pin(body.pin, user.id, user.pin_hash):
        raise await _reject(session, request, user, body.username, "bad_pin")
    trusted = json.loads(user.trusted_device_ids or "[]")
    if not body.device_id or body.device_id not in trusted:
        raise await _reject(session, request, user, body.username, "untrusted_device")
    return await _issue(session, request, user, body.device_id, "pin")


@router.get("/biometric/nonce")
async def biometric_nonce(device_id: str) -> dict[str, str]:
    nonce = secrets.token_urlsafe(32)
    _NONCES[device_id] = (nonce, datetime.now(timezone.utc) + timedelta(minutes=2))
    return {"nonce": nonce, "expires_in": "120"}


@router.post("/login/biometric", response_model=TokenPair)
async def login_biometric(body: BiometricLoginRequest, request: Request,
                          session: Annotated[AsyncSession, Depends(get_session)]) -> TokenPair:
    """Verifies an assertion signed inside the device's secure enclave.

    The biometric template itself never leaves the handset; the server only ever
    sees a signature over a nonce it issued.
    """
    issued = _NONCES.pop(body.device_id, None)
    if not issued or issued[0] != body.nonce or issued[1] < datetime.now(timezone.utc):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Nonce expired or unknown")
    user = await _load_user(session, body.username)
    _guard_active(user)
    if user is None or not user.is_active or not user.biometric_public_key:
        raise await _reject(session, request, user, body.username, "no_biometric_key")
    if not _verify_assertion(user.biometric_public_key, body.nonce, body.signature):
        raise await _reject(session, request, user, body.username, "bad_assertion")
    return await _issue(session, request, user, body.device_id, "biometric", trust_device=True)


def _verify_assertion(public_key_pem: str, nonce: str, signature_b64: str) -> bool:
    import base64
    from cryptography.exceptions import InvalidSignature
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec, padding, rsa
    try:
        key = serialization.load_pem_public_key(public_key_pem.encode())
        sig = base64.b64decode(signature_b64)
        if isinstance(key, ec.EllipticCurvePublicKey):
            key.verify(sig, nonce.encode(), ec.ECDSA(hashes.SHA256()))
        elif isinstance(key, rsa.RSAPublicKey):
            key.verify(sig, nonce.encode(), padding.PKCS1v15(), hashes.SHA256())
        else:
            return False
        return True
    except (InvalidSignature, ValueError, TypeError):
        return False


class _RefreshBody(BaseModel):
    refresh_token: str


@router.post("/refresh", response_model=TokenPair)
async def refresh(session: Annotated[AsyncSession, Depends(get_session)],
                  body: _RefreshBody | None = None,
                  refresh_token: str | None = None) -> TokenPair:
    """Exchange a refresh token for a new pair. Send it in the JSON body
    ({"refresh_token": ...}); the query-string form is still accepted for
    older clients but puts a 7-day credential into proxy/access logs."""
    token = (body.refresh_token if body else None) or refresh_token
    if not token:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "refresh_token is required")
    claims = decode_token(token, expect="refresh")
    user = (await session.execute(
        select(User).where(User.id == claims["sub"]))).scalar_one_or_none()
    if user is None or not user.is_active:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Account is no longer active")
    return TokenPair(access_token=create_access_token(user.id, user.role),
                     refresh_token=create_refresh_token(user.id),
                     expires_in=settings.access_token_minutes * 60,
                     role=user.role, must_change_password=user.must_change_password)


# response_model=None is required, not optional decoration, on every 204
# route below: FastAPI infers response_model from a `-> None` return
# annotation, and that inferred model is truthy enough to fail FastAPI's own
# "a body-less status code can't have a response model" assertion - at
# ROUTE REGISTRATION time, i.e. at import time, not at request time. Found
# via the first real pytest run: every single HTTP-based test failed
# identically, because the shared `client` fixture's `from app.main import
# app` itself raised before any request could be made - a single bad
# decorator anywhere in the router broke the entire app import.
@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT, response_model=None)
async def logout(request: Request, user: Annotated[Principal, Depends(current_user)],
                 session: Annotated[AsyncSession, Depends(get_session)]) -> None:
    revoked: set[str] = getattr(request.app.state, "revoked_jti", set())
    if user.jti:
        revoked.add(user.jti)
    request.app.state.revoked_jti = revoked
    await audit.record(session, action="auth.logout", actor_id=user.id,
                       entity_type="user", entity_id=user.id, ip=_client_ip(request))


@router.get("/me", response_model=UserOut)
async def me(user: Annotated[Principal, Depends(current_user)],
             session: Annotated[AsyncSession, Depends(get_session)]) -> User:
    row = (await session.execute(select(User).where(User.id == user.id))).scalar_one()
    return row


@router.post("/password", status_code=status.HTTP_204_NO_CONTENT, response_model=None)
async def change_password(body: PasswordChange, request: Request,
                          user: Annotated[Principal, Depends(current_user)],
                          session: Annotated[AsyncSession, Depends(get_session)]) -> None:
    row = (await session.execute(select(User).where(User.id == user.id))).scalar_one()
    if not verify_password(body.current_password, row.password_hash):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Current password is incorrect")
    validate_password(body.new_password)
    if verify_password(body.new_password, row.password_hash):
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY,
                            "New password must differ from the current one")
    row.password_hash = hash_password(body.new_password)
    row.must_change_password = False
    await audit.record(session, action="auth.password_changed", actor_id=row.id,
                       actor_username=row.username, entity_type="user", entity_id=row.id,
                       ip=_client_ip(request))


class _PinBody(BaseModel):
    pin: str


@router.post("/pin", status_code=status.HTTP_204_NO_CONTENT, response_model=None)
async def set_pin(user: Annotated[Principal, Depends(current_user)],
                  session: Annotated[AsyncSession, Depends(get_session)],
                  body: _PinBody | None = None, pin: str | None = None) -> None:
    """Enrol a quick-unlock PIN. Send {"pin": "..."} in the JSON body; the
    query-string form is still accepted for older clients but leaks the PIN
    into server/proxy access logs."""
    pin = (body.pin if body else None) or pin or ""
    if not (pin.isdigit() and 4 <= len(pin) <= 12):
        raise HTTPException(422, "PIN must be 4-12 digits")
    if pin in ("0000", "1234", "1111", "123456", "000000"):
        raise HTTPException(422, "That PIN is too common - choose another")
    row = (await session.execute(select(User).where(User.id == user.id))).scalar_one()
    row.pin_hash = hash_pin(pin, row.id)


# --------------------------------------------------------------------------- #
# User administration
# --------------------------------------------------------------------------- #
@router.get("/users", response_model=list[UserOut])
async def list_users(session: Annotated[AsyncSession, Depends(get_session)],
                     _: Annotated[Principal, Depends(requires("user:manage"))]) -> list[User]:
    return list((await session.execute(select(User).order_by(User.username))).scalars().all())


@router.post("/users", response_model=UserOut, status_code=status.HTTP_201_CREATED)
async def create_user(body: UserCreate, request: Request,
                      session: Annotated[AsyncSession, Depends(get_session)],
                      admin: Annotated[Principal, Depends(requires("user:manage"))]) -> User:
    if await _load_user(session, body.username):
        raise HTTPException(status.HTTP_409_CONFLICT, "Username already exists")
    validate_password(body.password)
    user = User(username=body.username, full_name=body.full_name, unit=body.unit,
                service_number=body.service_number, role=Role(body.role).value,
                password_hash=hash_password(body.password), must_change_password=True)
    session.add(user)
    await session.flush()
    await audit.record(session, action="user.created", actor_id=admin.id,
                       entity_type="user", entity_id=user.id,
                       detail={"username": user.username, "role": user.role},
                       ip=_client_ip(request))
    return user


@router.patch("/users/{user_id}/role", response_model=UserOut)
async def set_role(user_id: str, role: Role, request: Request,
                   session: Annotated[AsyncSession, Depends(get_session)],
                   admin: Annotated[Principal, Depends(requires("user:manage"))]) -> User:
    row = (await session.execute(select(User).where(User.id == user_id))).scalar_one_or_none()
    if row is None:
        raise HTTPException(404, "User not found")
    if row.id == admin.id and role != Role.ADMINISTRATOR:
        raise HTTPException(422, "You cannot remove your own administrator role - "
                                 "have another administrator do it, so the system is "
                                 "never left without one.")
    old, row.role = row.role, role.value
    await audit.record(session, action="user.role_changed", actor_id=admin.id,
                       entity_type="user", entity_id=row.id,
                       detail={"from": old, "to": row.role}, ip=_client_ip(request))
    return row


@router.patch("/users/{user_id}/active", response_model=UserOut)
async def set_active(user_id: str, is_active: bool, request: Request,
                     session: Annotated[AsyncSession, Depends(get_session)],
                     admin: Annotated[Principal, Depends(requires("user:manage"))]) -> User:
    row = (await session.execute(select(User).where(User.id == user_id))).scalar_one_or_none()
    if row is None:
        raise HTTPException(404, "User not found")
    row.is_active = is_active
    row.failed_logins = 0
    row.locked_until = None
    await audit.record(session, action="user.active_changed", actor_id=admin.id,
                       entity_type="user", entity_id=row.id,
                       detail={"is_active": is_active}, ip=_client_ip(request))
    return row
