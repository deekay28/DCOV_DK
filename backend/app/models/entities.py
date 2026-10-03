"""SQLAlchemy 2.0 ORM model. Portable across SQLite, PostgreSQL and MySQL."""
from __future__ import annotations

import uuid
from datetime import datetime, timezone

from sqlalchemy import (Boolean, DateTime, Float, ForeignKey, Index, Integer,
                        String, Text, TypeDecorator, UniqueConstraint)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def uid() -> str:
    return str(uuid.uuid4())


class UTCDateTime(TypeDecorator):
    """`DateTime(timezone=True)` that actually stays timezone-aware across a
    round trip through SQLite.

    SQLite has no native timezone-aware datetime type - this is documented
    SQLAlchemy behaviour, not a bug in SQLAlchemy: a value written as aware
    UTC is stored as a plain string and comes back *naive* on a fresh query,
    in a different session than the one that wrote it. Every datetime this
    app writes is UTC by convention (see utcnow() above), so the fix is to
    always re-attach tzinfo=UTC to whatever comes back, rather than leaving
    every comparison and every hash computation downstream to remember to
    normalize it themselves - which is exactly how two separate real bugs
    were found here: the audit hash chain reported "intact: False" on
    perfectly untampered rows the moment they were re-queried (a fresh
    SELECT returned a naive `occurred_at` that hashed differently from the
    aware one used when the row was first written), and account lockout
    raised an unhandled TypeError ("can't compare offset-naive and
    offset-aware datetimes") comparing a freshly-reloaded `locked_until`
    against `utcnow()`. Both were the same root cause in two unrelated
    places; this type fixes it once, for every datetime column below,
    instead of patching call sites as each one is discovered.
    """
    impl = DateTime(timezone=True)
    cache_ok = True

    def process_bind_param(self, value, dialect):
        if value is not None and value.tzinfo is not None:
            value = value.astimezone(timezone.utc)
        return value

    def process_result_value(self, value, dialect):
        if value is not None and value.tzinfo is None:
            value = value.replace(tzinfo=timezone.utc)
        return value


class Base(DeclarativeBase):
    pass


class TimestampMixin:
    created_at: Mapped[datetime] = mapped_column(UTCDateTime(), default=utcnow)
    updated_at: Mapped[datetime] = mapped_column(UTCDateTime(), default=utcnow,
                                                 onupdate=utcnow)


# --------------------------------------------------------------------------- #
class User(Base, TimestampMixin):
    __tablename__ = "users"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uid)
    username: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    full_name: Mapped[str] = mapped_column(String(128), default="")
    service_number: Mapped[str] = mapped_column(String(64), default="")
    unit: Mapped[str] = mapped_column(String(128), default="")
    email: Mapped[str | None] = mapped_column(String(255), unique=True, nullable=True)
    password_hash: Mapped[str] = mapped_column(String(128))
    pin_hash: Mapped[str | None] = mapped_column(String(128), nullable=True)
    biometric_public_key: Mapped[str | None] = mapped_column(Text, nullable=True)
    role: Mapped[str] = mapped_column(String(32), default="viewer", index=True)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True)
    must_change_password: Mapped[bool] = mapped_column(Boolean, default=True)
    failed_logins: Mapped[int] = mapped_column(Integer, default=0)
    locked_until: Mapped[datetime | None] = mapped_column(UTCDateTime(), nullable=True)
    last_login: Mapped[datetime | None] = mapped_column(UTCDateTime(), nullable=True)
    # JSON list of device_ids that have completed a full password (or
    # biometric) login. PIN login checks membership here rather than
    # accepting a device_id at face value - see auth.py login_pin/_issue.
    # A PIN is 4-12 digits; without this, "bound to a device" would be a
    # comment, not a control.
    trusted_device_ids: Mapped[str] = mapped_column(Text, default="[]")


class Component(Base, TimestampMixin):
    __tablename__ = "components"
    __table_args__ = (
        Index("ix_components_search_key", "search_key"),
        Index("ix_components_origin", "is_chinese", "criticality"),
        Index("ix_components_mfr_part", "manufacturer", "part_number"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uid)
    component_id: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    component_name: Mapped[str] = mapped_column(String(255), index=True)
    part_number: Mapped[str] = mapped_column(String(128), default="", index=True)
    chip_number: Mapped[str] = mapped_column(String(128), default="", index=True)
    # normalised A-Z0-9 form of chip_number/part_number - the exact-match fast path
    search_key: Mapped[str] = mapped_column(String(128), default="")

    manufacturer: Mapped[str] = mapped_column(String(128), default="", index=True)
    manufacturer_country: Mapped[str] = mapped_column(String(64), default="")
    country_of_origin: Mapped[str] = mapped_column(String(64), default="", index=True)
    is_chinese: Mapped[str] = mapped_column(String(8), default="UNKNOWN", index=True)

    category: Mapped[str] = mapped_column(String(64), default="", index=True)
    drone_subsystem: Mapped[str] = mapped_column(String(64), default="", index=True)
    criticality: Mapped[str] = mapped_column(String(16), default="REVIEW")
    criticality_policy: Mapped[str] = mapped_column(Text, default="")

    alternative_manufacturer: Mapped[str] = mapped_column(Text, default="")
    military_grade: Mapped[str] = mapped_column(String(8), default="NO")
    barcode: Mapped[str] = mapped_column(String(64), default="", index=True)
    qr_code: Mapped[str] = mapped_column(String(255), default="")
    function: Mapped[str] = mapped_column(String(255), default="")
    remarks: Mapped[str] = mapped_column(Text, default="")
    image_path: Mapped[str] = mapped_column(String(512), default="")
    datasheet_url: Mapped[str] = mapped_column(String(512), default="")
    supplier: Mapped[str] = mapped_column(String(255), default="")

    verified_by: Mapped[str] = mapped_column(String(128), default="")
    verification_source: Mapped[str] = mapped_column(String(255), default="")
    confidence_score: Mapped[float] = mapped_column(Float, default=100.0)
    pending_verification: Mapped[bool] = mapped_column(Boolean, default=False, index=True)

    revision: Mapped[int] = mapped_column(Integer, default=1)
    is_deleted: Mapped[bool] = mapped_column(Boolean, default=False, index=True)
    source_batch_id: Mapped[str | None] = mapped_column(String(36), nullable=True, index=True)


class ComponentRevision(Base):
    """Full row-level version history - supports diff, rollback and import undo."""
    __tablename__ = "component_revisions"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uid)
    component_pk: Mapped[str] = mapped_column(String(36), index=True)
    component_id: Mapped[str] = mapped_column(String(64), index=True)
    revision: Mapped[int] = mapped_column(Integer)
    operation: Mapped[str] = mapped_column(String(16))            # create|update|delete|restore
    snapshot_json: Mapped[str] = mapped_column(Text)
    changed_fields: Mapped[str] = mapped_column(Text, default="[]")
    batch_id: Mapped[str | None] = mapped_column(String(36), nullable=True, index=True)
    actor_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    created_at: Mapped[datetime] = mapped_column(UTCDateTime(), default=utcnow)


class ImportBatch(Base):
    __tablename__ = "import_batches"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uid)
    filename: Mapped[str] = mapped_column(String(255))
    file_sha256: Mapped[str] = mapped_column(String(64), index=True)
    file_format: Mapped[str] = mapped_column(String(16))          # xlsx|csv|json|sql
    status: Mapped[str] = mapped_column(String(16), default="staged")  # staged|committed|rolled_back|failed
    rows_total: Mapped[int] = mapped_column(Integer, default=0)
    rows_new: Mapped[int] = mapped_column(Integer, default=0)
    rows_updated: Mapped[int] = mapped_column(Integer, default=0)
    rows_unchanged: Mapped[int] = mapped_column(Integer, default=0)
    rows_deleted: Mapped[int] = mapped_column(Integer, default=0)
    rows_duplicate: Mapped[int] = mapped_column(Integer, default=0)
    rows_invalid: Mapped[int] = mapped_column(Integer, default=0)
    summary_json: Mapped[str] = mapped_column(Text, default="{}")
    error_log: Mapped[str] = mapped_column(Text, default="")
    actor_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    created_at: Mapped[datetime] = mapped_column(UTCDateTime(), default=utcnow)
    committed_at: Mapped[datetime | None] = mapped_column(UTCDateTime(), nullable=True)


class Inspection(Base, TimestampMixin):
    __tablename__ = "inspections"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uid)
    inspection_number: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    title: Mapped[str] = mapped_column(String(255), default="")
    platform: Mapped[str] = mapped_column(String(128), default="")   # drone type / tail no
    serial_number: Mapped[str] = mapped_column(String(128), default="")
    inspector_id: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"), index=True)
    location: Mapped[str] = mapped_column(String(255), default="")
    latitude: Mapped[float | None] = mapped_column(Float, nullable=True)
    longitude: Mapped[float | None] = mapped_column(Float, nullable=True)
    started_at: Mapped[datetime] = mapped_column(UTCDateTime(), default=utcnow)
    completed_at: Mapped[datetime | None] = mapped_column(UTCDateTime(), nullable=True)
    status: Mapped[str] = mapped_column(String(24), default="open")  # open|completed|escalated
    verdict: Mapped[str] = mapped_column(String(24), default="pending")  # clear|chinese_found|inconclusive
    remarks: Mapped[str] = mapped_column(Text, default="")
    signature: Mapped[str | None] = mapped_column(String(64), nullable=True)
    signed_at: Mapped[datetime | None] = mapped_column(UTCDateTime(), nullable=True)

    scans: Mapped[list[ScanRecord]] = relationship(back_populates="inspection")


class ScanRecord(Base):
    """One scan event: barcode, QR, OCR chip read, or manual entry."""
    __tablename__ = "scan_records"
    __table_args__ = (Index("ix_scan_time_result", "scanned_at", "result"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uid)
    client_uuid: Mapped[str] = mapped_column(String(36), unique=True, index=True)  # offline idempotency
    inspection_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("inspections.id"),
                                                      nullable=True, index=True)
    user_id: Mapped[str] = mapped_column(String(36), index=True)

    input_mode: Mapped[str] = mapped_column(String(16))     # barcode|qr|ocr|manual
    raw_input: Mapped[str] = mapped_column(String(512), default="")
    normalized_input: Mapped[str] = mapped_column(String(512), default="", index=True)
    ocr_text: Mapped[str] = mapped_column(Text, default="")
    barcode_symbology: Mapped[str] = mapped_column(String(32), default="")

    matched_component_id: Mapped[str | None] = mapped_column(String(64), nullable=True, index=True)
    match_method: Mapped[str] = mapped_column(String(24), default="")  # exact|normalized|fuzzy|alias|none
    match_score: Mapped[float] = mapped_column(Float, default=0.0)
    result: Mapped[str] = mapped_column(String(24), index=True)  # chinese|non_chinese|unknown_origin|not_found
    criticality: Mapped[str] = mapped_column(String(16), default="")

    device_id: Mapped[str] = mapped_column(String(128), default="")
    device_model: Mapped[str] = mapped_column(String(128), default="")
    app_version: Mapped[str] = mapped_column(String(32), default="")
    latitude: Mapped[float | None] = mapped_column(Float, nullable=True)
    longitude: Mapped[float | None] = mapped_column(Float, nullable=True)
    location_label: Mapped[str] = mapped_column(String(255), default="")
    image_paths: Mapped[str] = mapped_column(Text, default="[]")
    duration_ms: Mapped[int] = mapped_column(Integer, default=0)
    remarks: Mapped[str] = mapped_column(Text, default="")
    scanned_at: Mapped[datetime] = mapped_column(UTCDateTime(), default=utcnow, index=True)
    synced_at: Mapped[datetime | None] = mapped_column(UTCDateTime(), nullable=True)

    inspection: Mapped[Inspection | None] = relationship(back_populates="scans")


class PendingComponent(Base):
    """'Not found' captures queued for a database manager to adjudicate."""
    __tablename__ = "pending_components"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uid)
    raw_input: Mapped[str] = mapped_column(String(512))
    normalized_input: Mapped[str] = mapped_column(String(512), index=True)
    ocr_text: Mapped[str] = mapped_column(Text, default="")
    suggested_matches: Mapped[str] = mapped_column(Text, default="[]")
    image_paths: Mapped[str] = mapped_column(Text, default="[]")
    reported_by: Mapped[str] = mapped_column(String(36))
    hit_count: Mapped[int] = mapped_column(Integer, default=1)
    status: Mapped[str] = mapped_column(String(16), default="open")  # open|accepted|rejected
    resolution_note: Mapped[str] = mapped_column(Text, default="")
    created_at: Mapped[datetime] = mapped_column(UTCDateTime(), default=utcnow)


class AuditLog(Base):
    """Append-only, hash-chained. Never UPDATE or DELETE a row here."""
    __tablename__ = "audit_log"
    __table_args__ = (UniqueConstraint("sequence", name="uq_audit_sequence"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uid)
    # NOT database-autoincremented, despite appearances - the table's real
    # primary key/rowid is `id` above (a UUID string), and SQLite only
    # auto-populates an integer column when it IS the rowid. This column is
    # assigned explicitly in Python by app/services/audit.py's record()
    # function (last sequence + 1) - see the comment there for the bug this
    # was, and the concurrency caveat that comes with computing it in
    # Python rather than at the database layer.
    sequence: Mapped[int] = mapped_column(Integer, index=True)
    actor_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    actor_username: Mapped[str] = mapped_column(String(64), default="")
    action: Mapped[str] = mapped_column(String(64), index=True)
    entity_type: Mapped[str] = mapped_column(String(64), default="")
    entity_id: Mapped[str] = mapped_column(String(64), default="")
    detail_json: Mapped[str] = mapped_column(Text, default="{}")
    ip_address: Mapped[str] = mapped_column(String(64), default="")
    user_agent: Mapped[str] = mapped_column(String(255), default="")
    occurred_at: Mapped[datetime] = mapped_column(UTCDateTime(), default=utcnow, index=True)
    prev_hash: Mapped[str] = mapped_column(String(64), default="0" * 64)
    hash: Mapped[str] = mapped_column(String(64))


class SyncState(Base):
    """Per-device high-water marks for offline reconciliation."""
    __tablename__ = "sync_state"

    device_id: Mapped[str] = mapped_column(String(128), primary_key=True)
    user_id: Mapped[str] = mapped_column(String(36))
    last_pull_at: Mapped[datetime | None] = mapped_column(UTCDateTime(), nullable=True)
    last_push_at: Mapped[datetime | None] = mapped_column(UTCDateTime(), nullable=True)
    db_revision: Mapped[int] = mapped_column(Integer, default=0)
    pending_conflicts: Mapped[str] = mapped_column(Text, default="[]")
