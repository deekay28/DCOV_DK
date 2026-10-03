"""DCOV API entrypoint."""
from __future__ import annotations

import logging
import logging.config
import time
import uuid
from collections import defaultdict, deque
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request, status
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.gzip import GZipMiddleware
from fastapi.responses import JSONResponse
from sqlalchemy.exc import SQLAlchemyError
from starlette.middleware.trustedhost import TrustedHostMiddleware

from app.api import auth, catalog, field_ops, insights
from app.core.config import settings
from app.core.database import dispose, init_models, session_scope
from app.services import repository

LOGGING = {
    "version": 1,
    "disable_existing_loggers": False,
    "formatters": {
        "json": {"format": '{"ts":"%(asctime)s","level":"%(levelname)s",'
                           '"logger":"%(name)s","msg":"%(message)s"}'},
        "plain": {"format": "%(asctime)s %(levelname)-8s %(name)s | %(message)s"},
    },
    "handlers": {
        "console": {"class": "logging.StreamHandler",
                    "formatter": "json" if settings.environment == "production" else "plain"},
        "file": {"class": "logging.handlers.RotatingFileHandler",
                 "filename": str(settings.report_dir.parent / "dcov.log"),
                 "maxBytes": 20_000_000, "backupCount": 10, "formatter": "json"},
    },
    "root": {"level": "DEBUG" if settings.debug else "INFO",
             "handlers": ["console", "file"]},
}
logging.config.dictConfig(LOGGING)
log = logging.getLogger("dcov")


@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_models()
    async with session_scope() as session:
        n = await repository.cache.rebuild(session)
    app.state.revoked_jti = set()
    app.state.rate_buckets = defaultdict(deque)
    log.info("DCOV %s ready - %d components indexed", settings.version, n)
    import os
    if not os.environ.get("DCOV_SECRET_KEY"):
        log.warning("DCOV_SECRET_KEY is not set - a random key is in use, so every "
                    "restart signs out every device. Set it for any real deployment.")
    if settings.environment == "production":
        log.info("accepting Host headers: %s", ", ".join(settings.trusted_hosts))
    yield
    await dispose()
    log.info("shutdown complete")


app = FastAPI(
    title=settings.app_name,
    version=settings.version,
    description=(
        "Component origin verification for unmanned systems.\n\n"
        "**Scope note.** DCOV reports what the component database says about a "
        "marking. A GREEN result means *no Chinese-origin record was found for "
        "this marking*, which is not the same as proof of non-Chinese origin: "
        "markings can be counterfeited, a package can be re-marked, and the "
        "database is only as current as its last import. Treat results as "
        "screening evidence supporting a trained inspector, never as a "
        "substitute for one."
    ),
    lifespan=lifespan,
    docs_url="/api/docs", redoc_url="/api/redoc", openapi_url="/api/openapi.json",
)

app.add_middleware(GZipMiddleware, minimum_size=1024)
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins,
    allow_credentials=True,
    allow_methods=["GET", "POST", "PATCH", "DELETE", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type", "X-Device-Id", "X-Request-Id"],
    max_age=600,
)
if settings.environment == "production" and "*" not in settings.trusted_hosts:
    app.add_middleware(TrustedHostMiddleware, allowed_hosts=settings.trusted_hosts)


@app.middleware("http")
async def security_and_logging(request: Request, call_next):
    rid = request.headers.get("x-request-id") or str(uuid.uuid4())
    start = time.perf_counter()

    # Fixed-window rate limit per client IP. Cheap, and enough to blunt
    # credential stuffing and scripted enumeration of the catalogue.
    ip = (request.headers.get("x-forwarded-for", "").split(",")[0].strip()
          or (request.client.host if request.client else "-"))
    bucket = request.app.state.rate_buckets[ip]
    now = time.monotonic()
    while bucket and now - bucket[0] > 60:
        bucket.popleft()
    if len(bucket) >= settings.rate_limit_per_minute:
        return JSONResponse(
            {"detail": "Too many requests - slow down", "request_id": rid},
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            headers={"Retry-After": "60"})
    bucket.append(now)

    try:
        response = await call_next(request)
    except Exception:
        log.exception("unhandled error on %s %s (rid=%s)",
                      request.method, request.url.path, rid)
        return JSONResponse(
            {"detail": "Internal error. The incident has been logged.",
             "request_id": rid},
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR)

    took = (time.perf_counter() - start) * 1000
    response.headers.update({
        "X-Request-Id": rid,
        "X-Response-Time-ms": f"{took:.1f}",
        "X-Content-Type-Options": "nosniff",
        "X-Frame-Options": "DENY",
        "Referrer-Policy": "no-referrer",
        "Cross-Origin-Opener-Policy": "same-origin",
        "Permissions-Policy": "camera=(self), geolocation=(self), microphone=()",
        "Content-Security-Policy":
            "default-src 'self'; img-src 'self' data: blob:; "
            "script-src 'self'; style-src 'self' 'unsafe-inline'; "
            "connect-src 'self'; frame-ancestors 'none'; base-uri 'none'",
    })
    if settings.force_https:
        response.headers["Strict-Transport-Security"] = \
            "max-age=63072000; includeSubDomains; preload"
    if took > 2000:
        log.warning("slow request %s %s took %.0fms (rid=%s)",
                    request.method, request.url.path, took, rid)
    return response


@app.exception_handler(RequestValidationError)
async def validation_handler(request: Request, exc: RequestValidationError):
    """Field-level messages an operator can act on, without echoing the payload."""
    problems = [{"field": ".".join(str(p) for p in e["loc"][1:]) or e["loc"][0],
                 "problem": e["msg"]} for e in exc.errors()]
    return JSONResponse({"detail": "The request could not be accepted",
                         "problems": problems},
                        status_code=status.HTTP_422_UNPROCESSABLE_ENTITY)


@app.exception_handler(SQLAlchemyError)
async def db_handler(request: Request, exc: SQLAlchemyError):
    log.exception("database error on %s", request.url.path)
    return JSONResponse({"detail": "A database error occurred. No changes were saved."},
                        status_code=status.HTTP_503_SERVICE_UNAVAILABLE)


API = "/api/v1"
app.include_router(auth.router, prefix=API)
app.include_router(catalog.router, prefix=API)
app.include_router(field_ops.router, prefix=API)
app.include_router(insights.router, prefix=API)


@app.get("/health", tags=["ops"])
async def health() -> dict:
    return {"status": "ok", "version": settings.version,
            "index": repository.cache.stats()}


@app.get("/ready", tags=["ops"])
async def ready() -> dict:
    from sqlalchemy import text
    async with session_scope() as s:
        await s.execute(text("SELECT 1"))
    return {"status": "ready", "components": repository.cache.stats()["rows"]}
