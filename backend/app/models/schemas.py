"""Pydantic v2 API contracts. These are also the input-validation layer:
anything not declared here never reaches the database."""
from __future__ import annotations

import re
from datetime import datetime
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

SAFE_TEXT = re.compile(r"^[^\x00-\x08\x0b\x0c\x0e-\x1f<>]*$")
Verdict = Literal["YES", "NO", "UNKNOWN"]
Banner = Literal["RED", "GREEN", "YELLOW", "GREY"]
InputMode = Literal["barcode", "qr", "ocr", "manual"]


class ORMModel(BaseModel):
    model_config = ConfigDict(from_attributes=True)


def _no_control_chars(v: str) -> str:
    if v and not SAFE_TEXT.match(v):
        raise ValueError("field contains control characters or angle brackets")
    return v


Text255 = Annotated[str, Field(max_length=255)]


# --------------------------------------------------------------------------- #
# Auth
# --------------------------------------------------------------------------- #
class LoginRequest(BaseModel):
    username: Annotated[str, Field(min_length=3, max_length=64,
                                   pattern=r"^[A-Za-z0-9._-]+$")]
    password: Annotated[str, Field(min_length=8, max_length=256)]
    device_id: Annotated[str, Field(max_length=128)] = ""
    device_model: Text255 = ""


class PinLoginRequest(BaseModel):
    username: Annotated[str, Field(min_length=3, max_length=64)]
    pin: Annotated[str, Field(min_length=4, max_length=12, pattern=r"^\d+$")]
    device_id: Annotated[str, Field(max_length=128)]


class BiometricLoginRequest(BaseModel):
    """The device signs a server-issued nonce with the key enrolled at setup.

    The biometric itself never leaves the secure enclave - only the signature does.
    """
    username: Annotated[str, Field(min_length=3, max_length=64)]
    device_id: Annotated[str, Field(max_length=128)]
    nonce: str
    signature: str


class TokenPair(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    expires_in: int
    role: str
    must_change_password: bool = False


class UserCreate(BaseModel):
    username: Annotated[str, Field(min_length=3, max_length=64,
                                   pattern=r"^[A-Za-z0-9._-]+$")]
    password: Annotated[str, Field(min_length=12, max_length=256)]
    full_name: Text255 = ""
    service_number: Annotated[str, Field(max_length=64)] = ""
    unit: Text255 = ""
    role: Literal["administrator", "database_manager", "inspector", "viewer"] = "viewer"


class UserOut(ORMModel):
    id: str
    username: str
    full_name: str
    unit: str
    role: str
    is_active: bool
    last_login: datetime | None = None


class PasswordChange(BaseModel):
    current_password: str
    new_password: Annotated[str, Field(min_length=12, max_length=256)]


# --------------------------------------------------------------------------- #
# Components
# --------------------------------------------------------------------------- #
class ComponentBase(BaseModel):
    component_name: Annotated[str, Field(min_length=1, max_length=255)]
    part_number: Annotated[str, Field(max_length=128)] = ""
    chip_number: Annotated[str, Field(max_length=128)] = ""
    manufacturer: Annotated[str, Field(max_length=128)] = ""
    manufacturer_country: Annotated[str, Field(max_length=64)] = ""
    country_of_origin: Annotated[str, Field(max_length=64)] = ""
    category: Annotated[str, Field(max_length=64)] = ""
    drone_subsystem: Annotated[str, Field(max_length=64)] = ""
    alternative_manufacturer: str = ""
    military_grade: Literal["YES", "NO"] = "NO"
    barcode: Annotated[str, Field(max_length=64)] = ""
    qr_code: Text255 = ""
    function: Text255 = ""
    remarks: str = ""
    datasheet_url: Annotated[str, Field(max_length=512)] = ""
    supplier: Text255 = ""
    verified_by: Annotated[str, Field(max_length=128)] = ""
    verification_source: Text255 = ""
    confidence_score: Annotated[float, Field(ge=0, le=100)] = 100.0

    _clean = field_validator("component_name", "remarks", "supplier",
                             mode="after")(_no_control_chars)

    @field_validator("part_number", "chip_number", mode="after")
    @classmethod
    def _one_identifier(cls, v: str) -> str:
        return v.strip()


class ComponentCreate(ComponentBase):
    component_id: Annotated[str, Field(max_length=64)] = ""


class ComponentUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")
    component_name: Text255 | None = None
    manufacturer: Annotated[str, Field(max_length=128)] | None = None
    country_of_origin: Annotated[str, Field(max_length=64)] | None = None
    drone_subsystem: Annotated[str, Field(max_length=64)] | None = None
    alternative_manufacturer: str | None = None
    remarks: str | None = None
    datasheet_url: Annotated[str, Field(max_length=512)] | None = None
    verified_by: Annotated[str, Field(max_length=128)] | None = None
    verification_source: Text255 | None = None
    confidence_score: Annotated[float, Field(ge=0, le=100)] | None = None
    change_reason: Annotated[str, Field(min_length=3, max_length=500)]


class ComponentOut(ORMModel):
    id: str
    component_id: str
    component_name: str
    part_number: str
    chip_number: str
    manufacturer: str
    manufacturer_country: str
    country_of_origin: str
    is_chinese: Verdict
    category: str
    drone_subsystem: str
    criticality: str
    criticality_policy: str
    alternative_manufacturer: str
    military_grade: str
    barcode: str
    qr_code: str
    function: str
    remarks: str
    image_path: str
    datasheet_url: str
    supplier: str
    verified_by: str
    verification_source: str
    confidence_score: float
    revision: int
    updated_at: datetime


class ComponentPage(BaseModel):
    items: list[ComponentOut]
    total: int
    page: int
    page_size: int


# --------------------------------------------------------------------------- #
# Scan
# --------------------------------------------------------------------------- #
class ScanRequest(BaseModel):
    """One lookup. `raw_input` is whatever the scanner, OCR or the operator's
    keyboard produced - normalisation happens server-side so that the offline
    client and the hub can never disagree on how a marking was interpreted."""
    client_uuid: Annotated[str, Field(max_length=36)]
    input_mode: InputMode
    raw_input: Annotated[str, Field(min_length=1, max_length=512)]
    ocr_text: str = ""
    barcode_symbology: Annotated[str, Field(max_length=32)] = ""
    inspection_id: str | None = None
    device_id: Annotated[str, Field(max_length=128)] = ""
    device_model: Text255 = ""
    app_version: Annotated[str, Field(max_length=32)] = ""
    latitude: Annotated[float, Field(ge=-90, le=90)] | None = None
    longitude: Annotated[float, Field(ge=-180, le=180)] | None = None
    location_label: Text255 = ""
    duration_ms: Annotated[int, Field(ge=0, le=600000)] = 0
    scanned_at: datetime | None = None
    remarks: str = ""
    # Server-relative path returned by POST /scan/ocr (image_path) when the
    # photo was uploaded for OCR first and the inspector then confirmed or
    # corrected the marking. Links the stored photograph to this scan record.
    image_ref: Annotated[str, Field(max_length=200)] = ""


class SuggestionOut(BaseModel):
    component_id: str
    component_name: str
    manufacturer: str
    country_of_origin: str
    is_chinese: Verdict
    score: float


class MarkingFindingOut(BaseModel):
    """One anti-remark observation from app/services/marking.py."""
    code: str
    severity: Literal["info", "yellow", "red"]
    message: str


class ScanResult(BaseModel):
    scan_id: str
    client_uuid: str
    result: Literal["chinese", "non_chinese", "unknown_origin", "not_found"]
    banner: Banner
    headline: str
    criticality: str = ""
    escalate: bool = False
    escalation_note: str = ""
    action: str = ""
    alert: bool = False
    vibrate: bool = False
    sound: str = ""
    match_method: str
    match_score: float
    confidence: float
    normalized_input: str
    notes: list[str] = []
    marking_findings: list[MarkingFindingOut] = []
    # What the origin claim rests on (component | manufacturer | unit_marking
    # | none), in words, and the configured policy's decision. See
    # ORIGIN_VERIFICATION_LOGIC.md. Defaults keep older clients working.
    origin_evidence: str = "none"
    evidence_detail: str = ""
    review_required: bool = True
    policy_decision: str = ""
    component: ComponentOut | None = None
    suggestions: list[SuggestionOut] = []
    inspected_at: datetime


class BatchScanRequest(BaseModel):
    scans: Annotated[list[ScanRequest], Field(min_length=1, max_length=500)]


# --------------------------------------------------------------------------- #
# Inspections
# --------------------------------------------------------------------------- #
class InspectionCreate(BaseModel):
    title: Text255 = ""
    platform: Annotated[str, Field(max_length=128)] = ""
    serial_number: Annotated[str, Field(max_length=128)] = ""
    location: Text255 = ""
    latitude: float | None = None
    longitude: float | None = None
    remarks: str = ""
    inspector_id: str | None = None


class InspectionSign(BaseModel):
    verdict: Literal["clear", "chinese_found", "inconclusive"]
    remarks: Annotated[str, Field(max_length=4000)] = ""
    confirm: Literal[True]


class InspectionOut(ORMModel):
    id: str
    inspection_number: str
    title: str
    platform: str
    serial_number: str
    inspector_id: str
    location: str
    status: str
    verdict: str
    remarks: str
    signature: str | None
    signed_at: datetime | None
    started_at: datetime
    completed_at: datetime | None


# --------------------------------------------------------------------------- #
# Import
# --------------------------------------------------------------------------- #
class ImportPreview(BaseModel):
    batch_id: str
    filename: str
    file_format: str
    detected_columns: list[str]
    column_mapping: dict[str, str]
    unmapped_columns: list[str]
    rows_total: int
    rows_new: int
    rows_updated: int
    rows_unchanged: int
    rows_duplicate: int
    rows_invalid: int
    rows_missing_in_file: int
    sample_new: list[dict]
    sample_updated: list[dict]
    validation_errors: list[dict]
    warnings: list[str]


class ImportCommit(BaseModel):
    batch_id: str
    apply_updates: bool = True
    apply_new: bool = True
    soft_delete_missing: bool = False
    confirm: Literal[True]


class ImportSummary(BaseModel):
    batch_id: str
    status: str
    rows_new: int
    rows_updated: int
    rows_unchanged: int
    rows_deleted: int
    rows_invalid: int
    committed_at: datetime | None


# --------------------------------------------------------------------------- #
# Sync / dashboard
# --------------------------------------------------------------------------- #
class SyncPush(BaseModel):
    device_id: Annotated[str, Field(max_length=128)]
    scans: Annotated[list[ScanRequest], Field(max_length=1000)] = []
    since_revision: int = 0


class SyncConflict(BaseModel):
    client_uuid: str
    reason: str
    server_value: dict | None = None
    client_value: dict | None = None
    resolution: str


class SyncPull(BaseModel):
    db_revision: int
    components_changed: list[ComponentOut]
    components_deleted: list[str]
    conflicts: list[SyncConflict]
    server_time: datetime


class DashboardStats(BaseModel):
    total_components: int
    chinese_components: int
    non_chinese_components: int
    unknown_origin: int
    pending_verification: int
    critical_chinese: int
    scans_today: int
    scans_7d: int
    chinese_hits_7d: int
    open_inspections: int
    recently_scanned: list[dict]
    recently_imported: list[dict]
    recent_alerts: list[dict]
    db_revision: int
    last_import_at: datetime | None
