"""Async engine/session factory. One code path for SQLite, PostgreSQL and MySQL."""
from __future__ import annotations

import logging
from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager

from sqlalchemy import event, text
from sqlalchemy.ext.asyncio import (AsyncEngine, AsyncSession, async_sessionmaker,
                                    create_async_engine)
from fastapi import HTTPException

from app.core.config import settings
from app.models.entities import Base

log = logging.getLogger(__name__)
_is_sqlite = settings.database_url.startswith("sqlite")

engine: AsyncEngine = create_async_engine(
    settings.database_url,
    echo=settings.sql_echo,
    pool_pre_ping=True,
    **({} if _is_sqlite else {"pool_size": settings.pool_size,
                              "max_overflow": settings.max_overflow}),
)

SessionLocal = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)


@event.listens_for(engine.sync_engine, "connect")
def _sqlite_pragmas(dbapi_conn, _record) -> None:
    """WAL + enforced foreign keys. WAL is what makes concurrent field writes
    (a scan landing while a report is being generated) not block each other."""
    if not _is_sqlite:
        return
    cur = dbapi_conn.cursor()
    cur.execute("PRAGMA journal_mode=WAL")
    cur.execute("PRAGMA foreign_keys=ON")
    cur.execute("PRAGMA synchronous=NORMAL")
    cur.execute("PRAGMA busy_timeout=5000")
    cur.close()


async def get_session() -> AsyncGenerator[AsyncSession, None]:
    async with SessionLocal() as session:
        try:
            yield session
        except HTTPException:
            # A deliberately-raised HTTPException (401 on a bad password,
            # 404, 409, 423, etc.) is FastAPI's normal mechanism for
            # returning a non-2xx response - it is not the same thing as an
            # unexpected server error, and treating it as one here was a
            # real, serious bug: every failed login raises HTTPException(401)
            # by design (see auth.py's _reject()), and the blanket
            # `except Exception: rollback` below was silently discarding the
            # very failed-login-counter increment and audit log entry that
            # _reject() had just written, on every single failed login,
            # forever. Found via account lockout never actually triggering:
            # the failed_logins counter reset to nothing on every request,
            # because the "failure" response that told the client the
            # password was wrong was ALSO rolling back the record of that
            # failure ever happening. A deliberate error response should
            # still commit whatever legitimate state change went with it.
            await session.commit()
            raise
        except Exception:
            # A genuinely unexpected exception (a real bug, a DB error) -
            # here, rollback is correct: don't persist a partial write from
            # a code path that broke midway through.
            await session.rollback()
            raise
        else:
            await session.commit()


@asynccontextmanager
async def session_scope() -> AsyncGenerator[AsyncSession, None]:
    async with SessionLocal() as session:
        try:
            yield session
            await session.commit()
        except Exception:
            await session.rollback()
            raise


async def init_models() -> None:
    """Create tables if absent. In production, prefer `alembic upgrade head`;
    this exists so a field laptop can bootstrap with no migration tooling."""
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
        if _is_sqlite:
            await conn.execute(text(
                "CREATE VIRTUAL TABLE IF NOT EXISTS components_fts USING fts5("
                "component_name, part_number, chip_number, manufacturer, remarks, "
                "content='components', content_rowid='rowid')"))
    log.info("schema ready (%s)", "sqlite" if _is_sqlite else "server")


async def dispose() -> None:
    await engine.dispose()
