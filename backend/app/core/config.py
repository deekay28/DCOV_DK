"""Runtime configuration. Every value is overridable by environment variable."""
from __future__ import annotations

import secrets
from functools import lru_cache
from pathlib import Path

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

ROOT = Path(__file__).resolve().parents[3]


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_prefix="DCOV_", extra="ignore")

    app_name: str = "DCOV - Drone Component Origin Verification"
    version: str = "1.0.0"
    environment: str = "production"
    debug: bool = False

    # --- database -----------------------------------------------------------
    # SQLite for a standalone/field server; PostgreSQL or MySQL for the hub.
    #   sqlite+aiosqlite:///./dcov.sqlite
    #   postgresql+asyncpg://dcov:pass@db:5432/dcov
    #   mysql+asyncmy://dcov:pass@db:3306/dcov
    database_url: str = f"sqlite+aiosqlite:///{ROOT / 'data' / 'dcov.sqlite'}"
    sql_echo: bool = False
    pool_size: int = 20
    max_overflow: int = 10

    # --- auth ---------------------------------------------------------------
    # Unset => random per process: every restart invalidates every issued
    # token (devices must sign in again). Set DCOV_SECRET_KEY for any real
    # deployment - scripts/run_lan_server.sh generates and persists one.
    secret_key: str = Field(default_factory=lambda: secrets.token_urlsafe(48))
    algorithm: str = "HS256"
    access_token_minutes: int = 30
    refresh_token_days: int = 7
    inactivity_logout_minutes: int = 15
    bcrypt_rounds: int = 12
    pbkdf2_rounds: int = 260_000
    # "bcrypt" (default, needs the compiled `bcrypt` package) or
    # "pbkdf2_sha256" (pure Python - use this on Termux/Android, or anywhere
    # a native/Rust build toolchain isn't available or wanted).
    password_scheme: str = "bcrypt"
    max_failed_logins: int = 5
    lockout_minutes: int = 15

    # --- storage ------------------------------------------------------------
    upload_dir: Path = ROOT / "var" / "uploads"
    report_dir: Path = ROOT / "var" / "reports"
    backup_dir: Path = ROOT / "var" / "backups"
    max_upload_mb: int = 50

    # --- matching -----------------------------------------------------------
    fuzzy_threshold: int = 82          # below this a match is not auto-accepted
    fuzzy_candidate_limit: int = 25
    low_confidence_floor: int = 60     # below this the verdict is downgraded

    # --- security -----------------------------------------------------------
    cors_origins: list[str] = ["http://localhost:3000", "http://localhost:8080"]
    # Host headers accepted in production (TrustedHostMiddleware). The old
    # hard-coded list (*.local, localhost, 127.0.0.1) rejected every request
    # from a phone addressing the server by its LAN IP or a real domain with
    # "400 Invalid host header". Set to your domain / LAN IP, e.g.
    #   DCOV_TRUSTED_HOSTS='["dcov.example.org"]'  or  '["192.168.1.20"]'
    # "*" disables the check (acceptable on an isolated field LAN only).
    trusted_hosts: list[str] = ["*.local", "localhost", "127.0.0.1"]
    force_https: bool = True
    rate_limit_per_minute: int = 120
    audit_hash_chain: bool = True      # tamper-evident audit log

    # --- ocr ----------------------------------------------------------------
    ocr_engines: list[str] = ["easyocr", "tesseract"]
    ocr_gpu: bool = False
    tesseract_cmd: str | None = None

    @field_validator("upload_dir", "report_dir", "backup_dir")
    @classmethod
    def _mkdir(cls, v: Path) -> Path:
        v.mkdir(parents=True, exist_ok=True)
        return v


@lru_cache
def get_settings() -> Settings:
    return Settings()


settings = get_settings()
