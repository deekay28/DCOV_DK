"""Database import wizard.

Design rule: **an import never mutates the live table until it is committed.**
Upload -> parse -> map columns -> validate -> diff against live -> preview ->
commit (transactional, with a revision snapshot per row) -> rollback available.

Supported inputs: .xlsx/.xlsm, .csv/.tsv, .json, .sql (INSERT statements).
"""
from __future__ import annotations

import csv
import hashlib
import io
import json
import re
from dataclasses import dataclass, field
from difflib import SequenceMatcher
from pathlib import Path
from typing import Any

from app.services.matching import normalize, normalize_manufacturer

CANONICAL_FIELDS = [
    "component_id", "component_name", "part_number", "chip_number", "manufacturer",
    "manufacturer_country", "country_of_origin", "is_chinese", "category",
    "drone_subsystem", "criticality", "criticality_policy", "alternative_manufacturer",
    "military_grade", "barcode", "qr_code", "function", "remarks", "image_path",
    "datasheet_url", "supplier", "verified_by", "verification_source", "confidence_score",
]

# Header synonyms seen in real inspection worksheets, including the abbreviations
# used in the source workbook ("SUB COMPONENT / CHIP NO", "COO", "Mfr").
SYNONYMS: dict[str, list[str]] = {
    "component_id": ["component id", "comp id", "id", "ser no", "ser", "sl no"],
    "component_name": ["component name", "name of item", "item", "main component",
                       "nomenclature", "description", "sys/ sub sys"],
    "part_number": ["part number", "part no", "pn", "model no", "model/make", "model"],
    "chip_number": ["chip number", "chip no", "chip", "sub component / chip no",
                    "chinese component chip name", "sub component", "ic ref",
                    "chinese ic ref", "marking"],
    "manufacturer": ["manufacturer", "mfr", "oem", "make", "manufacturer of component",
                     "vendor", "supplier name"],
    "manufacturer_country": ["manufacturer country", "mfr country", "oem country"],
    "country_of_origin": ["country of origin", "coo", "origin", "country",
                          "country of origin (coo)"],
    "is_chinese": ["chinese", "chinese (yes/no)", "is chinese", "chinese origin"],
    "category": ["category", "type", "component category"],
    "drone_subsystem": ["drone subsystem", "sub sys", "subsystem", "drone system",
                        "sub system where typically likely to be found",
                        "sub sys where typically likely to be found"],
    "criticality": ["criticality", "critical", "critical/non critical"],
    "alternative_manufacturer": ["alternative manufacturer", "alternative", "alternate",
                                 "alternative parts", "substitute"],
    "military_grade": ["military grade", "mil grade", "mil spec"],
    "barcode": ["barcode", "bar code", "ean", "upc"],
    "qr_code": ["qr code", "qr"],
    "function": ["function", "purpose", "role"],
    "remarks": ["remarks", "notes", "any other details", "comment", "observation",
                "photograph / remarks"],
    "image_path": ["image", "photograph", "photo", "image path"],
    "datasheet_url": ["datasheet", "datasheet url", "spec sheet"],
    "supplier": ["supplier", "procured from", "source"],
    "verified_by": ["verified by", "inspector", "checked by"],
    "verification_source": ["verification source", "evidence", "source"],
    "confidence_score": ["confidence score", "confidence", "conf %"],
    "criticality_policy": ["criticality policy", "policy", "acceptance policy"],
}

# System-managed columns: accepted in a file, never imported, never folded into
# remarks. The server owns these timestamps.
IGNORED_HEADERS = {"date added", "last updated", "created at", "updated at",
                   "revision", "search key", "id", "row", "photograph"}

REQUIRED = ["component_name"]
CHINA_PHRASES = ("MADE IN CHINA", "COO CHINA", "COO: CHINA", "ORIGIN CHINA", "PRC")
CHINA_COUNTRIES = ("CHINA", "PRC", "HONG KONG", "MACAU", "SHENZHEN", "CHN")


# --------------------------------------------------------------------------- #
@dataclass
class ParsedFile:
    rows: list[dict[str, Any]]
    columns: list[str]
    file_format: str
    sha256: str
    sheet_names: list[str] = field(default_factory=list)


@dataclass
class RowIssue:
    row_number: int
    field: str
    severity: str          # error | warning
    message: str
    value: str = ""


@dataclass
class StagedImport:
    batch_id: str
    filename: str
    file_format: str
    columns: list[str]
    mapping: dict[str, str]
    unmapped: list[str]
    new_rows: list[dict] = field(default_factory=list)
    updated_rows: list[dict] = field(default_factory=list)   # {"before","after","changed"}
    unchanged: int = 0
    duplicates: list[dict] = field(default_factory=list)
    invalid: list[RowIssue] = field(default_factory=list)
    missing_in_file: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)


# --------------------------------------------------------------------------- #
# Parsing
# --------------------------------------------------------------------------- #
def sha256_of(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def parse_file(data: bytes, filename: str, sheet: str | None = None) -> ParsedFile:
    ext = Path(filename).suffix.lower()
    digest = sha256_of(data)
    if ext in (".xlsx", ".xlsm", ".xltx"):
        return _parse_xlsx(data, digest, sheet)
    if ext in (".csv", ".tsv", ".txt"):
        return _parse_csv(data, digest, "\t" if ext == ".tsv" else None)
    if ext == ".json":
        return _parse_json(data, digest)
    if ext == ".sql":
        return _parse_sql(data, digest)
    raise ValueError(f"Unsupported file type '{ext}'. Use .xlsx, .csv, .json or .sql")


def _parse_xlsx(data: bytes, digest: str, sheet: str | None) -> ParsedFile:
    from openpyxl import load_workbook
    wb = load_workbook(io.BytesIO(data), data_only=True, read_only=True)
    names = wb.sheetnames
    ws = wb[sheet] if sheet and sheet in names else _best_sheet(wb)
    rows_iter = ws.iter_rows(values_only=True)

    # Real worksheets often carry a merged title row above the header. Find the
    # first row that looks like a header (>=2 non-empty cells, mostly text).
    header: list[str] = []
    for raw in rows_iter:
        cells = ["" if c is None else str(c).strip() for c in raw]
        filled = [c for c in cells if c]
        if len(filled) >= 2 and sum(c.replace(".", "").isdigit() for c in filled) < len(filled) / 2:
            header = cells
            break
    if not header:
        raise ValueError("No header row found in worksheet")

    out: list[dict] = []
    for raw in rows_iter:
        cells = ["" if c is None else str(c).strip() for c in raw]
        if not any(cells):
            continue
        out.append({h: (cells[i] if i < len(cells) else "")
                    for i, h in enumerate(header) if h})
    wb.close()
    return ParsedFile(out, [h for h in header if h], "xlsx", digest, names)


def _best_sheet(wb) -> Any:
    """Pick the sheet with the most data rows - defends against a workbook whose
    first tab is a cover page."""
    return max(wb.worksheets, key=lambda w: (w.max_row or 0) * (w.max_column or 0))


def _parse_csv(data: bytes, digest: str, delim: str | None) -> ParsedFile:
    text = data.decode("utf-8-sig", errors="replace")
    if delim is None:
        try:
            delim = csv.Sniffer().sniff(text[:8192], delimiters=",;\t|").delimiter
        except csv.Error:
            delim = ","
    reader = csv.DictReader(io.StringIO(text), delimiter=delim)
    rows = [{(k or "").strip(): (v or "").strip() for k, v in r.items()} for r in reader]
    return ParsedFile(rows, [c.strip() for c in (reader.fieldnames or [])], "csv", digest)


def _parse_json(data: bytes, digest: str) -> ParsedFile:
    doc = json.loads(data.decode("utf-8"))
    if isinstance(doc, dict):
        doc = doc.get("components") or doc.get("data") or doc.get("rows") or []
    if not isinstance(doc, list):
        raise ValueError("JSON must be a list of objects, or an object with a 'components' list")
    rows = [{str(k).strip(): ("" if v is None else str(v)) for k, v in r.items()} for r in doc]
    cols = list({k for r in rows for k in r})
    return ParsedFile(rows, cols, "json", digest)


_INSERT_RE = re.compile(
    r"INSERT\s+INTO\s+[`\"\[]?(\w+)[`\"\]]?\s*\(([^)]+)\)\s*VALUES\s*(.+?);",
    re.IGNORECASE | re.DOTALL)


def _parse_sql(data: bytes, digest: str) -> ParsedFile:
    """Reads INSERT statements only. DDL/DML of any other kind is ignored rather
    than executed - a .sql upload must never be able to run arbitrary SQL."""
    text = data.decode("utf-8", errors="replace")
    rows: list[dict] = []
    cols: list[str] = []
    for m in _INSERT_RE.finditer(text):
        cols = [c.strip().strip('`"[]') for c in m.group(2).split(",")]
        for tup in re.findall(r"\(((?:[^()']|'(?:''|[^'])*')*)\)", m.group(3)):
            vals = _split_sql_values(tup)
            if len(vals) == len(cols):
                rows.append(dict(zip(cols, vals)))
    if not rows:
        raise ValueError("No INSERT statements found. Only INSERT is honoured in .sql imports.")
    return ParsedFile(rows, cols, "sql", digest)


def _split_sql_values(tup: str) -> list[str]:
    out, buf, in_str, i = [], [], False, 0
    while i < len(tup):
        ch = tup[i]
        if in_str:
            if ch == "'":
                if i + 1 < len(tup) and tup[i + 1] == "'":
                    buf.append("'")
                    i += 2
                    continue
                in_str = False
            else:
                buf.append(ch)
        elif ch == "'":
            in_str = True
        elif ch == ",":
            out.append("".join(buf).strip())
            buf = []
        else:
            buf.append(ch)
        i += 1
    out.append("".join(buf).strip())
    return ["" if v.upper() == "NULL" else v for v in out]


# --------------------------------------------------------------------------- #
# Column mapping
# --------------------------------------------------------------------------- #
def _clean_header(h: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"[_\-]+", " ", h.strip().lower())).strip()


def auto_map_columns(columns: list[str]) -> tuple[dict[str, str], list[str]]:
    """Return (source_header -> canonical_field, unmapped_headers).

    Exact synonym first, then a fuzzy pass at >=0.82 so 'Manufctr Country' still
    lands. The wizard shows this mapping and lets the operator override it.
    """
    mapping: dict[str, str] = {}
    taken: set[str] = set()
    cleaned = {c: _clean_header(c) for c in columns}

    for col, cl in cleaned.items():
        for canon, syns in SYNONYMS.items():
            if canon in taken:
                continue
            if cl == canon.replace("_", " ") or cl in syns:
                mapping[col] = canon
                taken.add(canon)
                break

    for col, cl in cleaned.items():
        if col in mapping:
            continue
        best, best_score = None, 0.0
        for canon, syns in SYNONYMS.items():
            if canon in taken:
                continue
            for cand in [canon.replace("_", " ")] + syns:
                s = SequenceMatcher(None, cl, cand).ratio()
                if s > best_score:
                    best, best_score = canon, s
        if best and best_score >= 0.82:
            mapping[col] = best
            taken.add(best)

    unmapped = [c for c in columns
                if c not in mapping and _clean_header(c) not in IGNORED_HEADERS]
    return mapping, unmapped


# --------------------------------------------------------------------------- #
# Validation and derivation
# --------------------------------------------------------------------------- #
UNKNOWN_COUNTRY_VALUES = frozenset({
    "UNKNOWN", "UNK", "N/A", "NA", "-", "--", "?", "TBD", "TBC", "NOT KNOWN",
    "NOT ESTABLISHED", "NONE", "NIL", "UNDETERMINED"})


def derive_is_chinese(country: str, remarks: str = "", declared: str = "") -> str:
    d = (declared or "").strip().upper()
    if d in ("YES", "Y", "TRUE", "1"):
        return "YES"
    if d in ("NO", "N", "FALSE", "0"):
        return "NO"
    blob = f"{country} {remarks}".upper()
    if any(p in blob for p in CHINA_PHRASES):
        return "YES"
    cu = (country or "").strip().upper()
    # "Unknown"/"N/A"/"-" are statements that origin is NOT established. They
    # used to fall through to "NO" (any non-empty, non-Chinese country), which
    # turned all 16 unknown-origin seed records into non-Chinese GREENs on the
    # server while the offline app (reading the seed's own UNKNOWN) showed
    # YELLOW for the same marking. Found by checking the dashboard counters
    # against the seed file.
    if not cu or cu in UNKNOWN_COUNTRY_VALUES:
        return "UNKNOWN"
    if any(tok in cu for tok in CHINA_COUNTRIES):
        return "YES"
    return "NO"


def stable_component_id(row: dict) -> str:
    key = normalize(row.get("chip_number") or row.get("part_number") or row.get("component_name"))
    mfr = normalize_manufacturer(row.get("manufacturer"))
    prefix = "CHIP" if row.get("chip_number") else "COMP"
    h = hashlib.sha1(f"{key}|{mfr}".encode()).hexdigest()[:8].upper()
    return f"{prefix}-{h}"


def apply_mapping(raw: dict, mapping: dict[str, str]) -> dict:
    out = {f: "" for f in CANONICAL_FIELDS}
    extras: dict[str, str] = {}
    for src, val in raw.items():
        if _clean_header(src) in IGNORED_HEADERS and src not in mapping:
            continue
        canon = mapping.get(src)
        if canon:
            out[canon] = (val or "").strip()
        elif (val or "").strip():
            extras[src] = val.strip()
    if extras:
        note = "; ".join(f"{k}: {v}" for k, v in extras.items())
        out["remarks"] = f"{out['remarks']} | {note}".strip(" |") if out["remarks"] else note
    return out


def validate_row(row: dict, n: int) -> list[RowIssue]:
    issues: list[RowIssue] = []
    for f in REQUIRED:
        if not row.get(f):
            issues.append(RowIssue(n, f, "error", "required field is empty"))
    if not (row.get("part_number") or row.get("chip_number")):
        issues.append(RowIssue(n, "part_number", "error",
                               "row has neither a part number nor a chip number, "
                               "so it can never be matched by a scan"))
    conf = row.get("confidence_score", "")
    if conf:
        try:
            if not 0 <= float(conf) <= 100:
                raise ValueError
        except ValueError:
            issues.append(RowIssue(n, "confidence_score", "error",
                                   "must be a number between 0 and 100", str(conf)))
    if row.get("military_grade") and row["military_grade"].upper() not in ("YES", "NO", ""):
        issues.append(RowIssue(n, "military_grade", "warning",
                               "expected YES or NO; value ignored", row["military_grade"]))
    if row.get("barcode") and not re.fullmatch(r"[A-Za-z0-9\-._/ ]{4,64}", row["barcode"]):
        issues.append(RowIssue(n, "barcode", "warning",
                               "unusual characters for a barcode payload", row["barcode"]))
    if not row.get("country_of_origin") and not row.get("remarks"):
        issues.append(RowIssue(n, "country_of_origin", "warning",
                               "no origin evidence - row will import as UNKNOWN (yellow banner)"))
    return issues


# --------------------------------------------------------------------------- #
# Diff against the live table
# --------------------------------------------------------------------------- #
COMPARE_FIELDS = ["component_name", "part_number", "chip_number", "manufacturer",
                  "manufacturer_country", "country_of_origin", "is_chinese", "category",
                  "drone_subsystem", "alternative_manufacturer", "military_grade",
                  "barcode", "qr_code", "function", "remarks", "datasheet_url",
                  "supplier", "verified_by", "verification_source", "confidence_score"]


def stage_import(parsed: ParsedFile, existing: dict[str, dict], batch_id: str,
                 filename: str, mapping: dict[str, str] | None = None) -> StagedImport:
    """`existing` maps component_id -> live row. Nothing is written here."""
    mapping, unmapped = (mapping, [c for c in parsed.columns if c not in (mapping or {})]) \
        if mapping else auto_map_columns(parsed.columns)

    staged = StagedImport(batch_id, filename, parsed.file_format, parsed.columns,
                          mapping, unmapped)

    if unmapped:
        staged.warnings.append(
            f"{len(unmapped)} column(s) could not be mapped and will be folded into "
            f"remarks: {', '.join(unmapped[:8])}")
    missing_canon = [f for f in ("country_of_origin", "manufacturer")
                     if f not in mapping.values()]
    if missing_canon:
        staged.warnings.append(
            f"No column mapped to {', '.join(missing_canon)} - affected rows will "
            f"import with UNKNOWN origin and show a yellow banner on scan.")

    seen_ids: dict[str, int] = {}
    file_ids: set[str] = set()

    for n, raw in enumerate(parsed.rows, start=2):
        row = apply_mapping(raw, mapping)
        issues = validate_row(row, n)
        if any(i.severity == "error" for i in issues):
            staged.invalid.extend(issues)
            continue
        staged.invalid.extend(i for i in issues if i.severity == "warning")

        row["is_chinese"] = derive_is_chinese(row["country_of_origin"], row["remarks"],
                                              row["is_chinese"])
        row["manufacturer"] = normalize_manufacturer(row["manufacturer"])
        row["search_key"] = normalize(row["chip_number"] or row["part_number"])
        row["confidence_score"] = float(row["confidence_score"] or 100)
        if not row["component_id"]:
            row["component_id"] = stable_component_id(row)

        cid = row["component_id"]
        if cid in seen_ids:
            staged.duplicates.append({"row": n, "first_seen_row": seen_ids[cid],
                                      "component_id": cid,
                                      "component_name": row["component_name"]})
            continue
        seen_ids[cid] = n
        file_ids.add(cid)

        live = existing.get(cid)
        if live is None:
            staged.new_rows.append(row)
            continue

        changed = {f: {"from": str(live.get(f, "")), "to": str(row.get(f, ""))}
                   for f in COMPARE_FIELDS
                   if str(live.get(f, "") or "") != str(row.get(f, "") or "") and row.get(f, "")}
        if changed:
            staged.updated_rows.append({"component_id": cid, "after": row, "changed": changed,
                                        "component_name": row["component_name"]})
        else:
            staged.unchanged += 1

    staged.missing_in_file = [cid for cid in existing if cid not in file_ids]
    if staged.missing_in_file:
        staged.warnings.append(
            f"{len(staged.missing_in_file)} live component(s) are absent from this file. "
            f"They are retained unless you tick 'soft-delete missing rows'.")

    # Origin flips are the single highest-risk edit in this system: a component
    # that was RED becoming GREEN silently is exactly what an adversary would want.
    flips = [u for u in staged.updated_rows if "is_chinese" in u["changed"]]
    if flips:
        staged.warnings.append(
            f"{len(flips)} component(s) change origin verdict in this import "
            f"(e.g. {flips[0]['component_id']}: "
            f"{flips[0]['changed']['is_chinese']['from']} -> "
            f"{flips[0]['changed']['is_chinese']['to']}). Review each before committing.")
    return staged


def summarize(staged: StagedImport) -> dict:
    return {
        "batch_id": staged.batch_id,
        "filename": staged.filename,
        "file_format": staged.file_format,
        "detected_columns": staged.columns,
        "column_mapping": staged.mapping,
        "unmapped_columns": staged.unmapped,
        "rows_total": len(staged.new_rows) + len(staged.updated_rows) + staged.unchanged
                      + len(staged.duplicates),
        "rows_new": len(staged.new_rows),
        "rows_updated": len(staged.updated_rows),
        "rows_unchanged": staged.unchanged,
        "rows_duplicate": len(staged.duplicates),
        "rows_invalid": len([i for i in staged.invalid if i.severity == "error"]),
        "rows_missing_in_file": len(staged.missing_in_file),
        "sample_new": staged.new_rows[:10],
        "sample_updated": staged.updated_rows[:10],
        "validation_errors": [i.__dict__ for i in staged.invalid[:200]],
        "warnings": staged.warnings,
    }
