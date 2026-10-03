"""Report generation: PDF (ReportLab), XLSX (openpyxl), CSV.

Reports are evidence. Each carries the generating user, the generation time, the
database revision it was drawn from, and a SHA-256 of its own body, so a printed
copy can be tied back to the exact database state that produced it.
"""
from __future__ import annotations

import csv
import hashlib
import io
from datetime import datetime, timezone
from typing import Any, Iterable

CLASSIFICATION_BANNER = "RESTRICTED - FOR OFFICIAL USE ONLY"

RESULT_LABEL = {
    "chinese": "CHINESE COMPONENT",
    "non_chinese": "NON-CHINESE",
    "unknown_origin": "ORIGIN NOT ESTABLISHED",
    "not_found": "NOT IN DATABASE",
}
RESULT_COLOR = {"chinese": "C00000", "non_chinese": "0B6623",
                "unknown_origin": "BF8F00", "not_found": "595959"}


def _stamp(meta: dict[str, Any]) -> dict[str, Any]:
    return {
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "generated_by": meta.get("generated_by", "unknown"),
        "db_revision": meta.get("db_revision", 0),
        "classification": CLASSIFICATION_BANNER,
        **meta,
    }


def body_digest(rows: Iterable[dict]) -> str:
    h = hashlib.sha256()
    for r in rows:
        h.update("|".join(f"{k}={v}" for k, v in sorted(r.items())).encode())
    return h.hexdigest()


# --------------------------------------------------------------------------- #
def to_csv(rows: list[dict], columns: list[str] | None = None) -> bytes:
    columns = columns or (list(rows[0].keys()) if rows else [])
    buf = io.StringIO()
    w = csv.DictWriter(buf, fieldnames=columns, extrasaction="ignore")
    w.writeheader()
    w.writerows(rows)
    return buf.getvalue().encode("utf-8-sig")


def _xlsx_safe(value: Any) -> Any:
    """openpyxl refuses to write a timezone-aware datetime at all
    (`ValueError: Excel does not support timezones in datetimes`) - Excel's
    own date/time serial format has no timezone concept, full stop. Every
    datetime this app hands to a report is UTC by convention (see
    app/models/entities.py's UTCDateTime type), so converting to UTC and
    dropping the tzinfo label preserves the correct wall-clock moment while
    satisfying openpyxl. Found by the first real pytest run, as a
    regression introduced by fixing a *different*, unrelated bug: making
    every datetime reliably timezone-aware (correct, and necessary for the
    audit hash chain and account lockout) broke this code path, which had
    been silently relying on values happening to already be naive.
    """
    if isinstance(value, datetime) and value.tzinfo is not None:
        return value.astimezone(timezone.utc).replace(tzinfo=None)
    return value


def to_xlsx(rows: list[dict], meta: dict, title: str,
            columns: list[str] | None = None) -> bytes:
    from openpyxl import Workbook
    from openpyxl.styles import Alignment, Font, PatternFill
    from openpyxl.utils import get_column_letter

    meta = _stamp(meta)
    columns = columns or (list(rows[0].keys()) if rows else [])
    wb = Workbook()
    ws = wb.active
    ws.title = title[:31] or "REPORT"

    ws.append([CLASSIFICATION_BANNER])
    ws["A1"].font = Font(name="Arial", bold=True, size=12, color="C00000")
    ws.append([title])
    ws["A2"].font = Font(name="Arial", bold=True, size=14)
    ws.append([f"Generated {meta['generated_at']} by {meta['generated_by']} | "
               f"database revision {meta['db_revision']} | {len(rows)} record(s)"])
    ws["A3"].font = Font(name="Arial", size=9, italic=True)
    ws.append([])

    head_row = ws.max_row + 1
    ws.append([c.replace("_", " ").upper() for c in columns])
    for c in ws[head_row]:
        c.font = Font(name="Arial", bold=True, color="FFFFFF", size=10)
        c.fill = PatternFill("solid", fgColor="1F3864")
        c.alignment = Alignment(wrap_text=True, vertical="center")

    for r in rows:
        ws.append([_xlsx_safe(r.get(c, "")) for c in columns])
        line = ws[ws.max_row]
        for cell in line:
            cell.font = Font(name="Arial", size=10)
            cell.alignment = Alignment(vertical="top", wrap_text=True)
        verdict = str(r.get("result") or r.get("is_chinese") or "")
        if verdict in ("chinese", "YES"):
            for cell in line:
                cell.fill = PatternFill("solid", fgColor="F8CBAD")
        elif verdict in ("unknown_origin", "UNKNOWN"):
            for cell in line:
                cell.fill = PatternFill("solid", fgColor="FFE699")

    for i, c in enumerate(columns, start=1):
        ws.column_dimensions[get_column_letter(i)].width = \
            50 if c in ("remarks", "component_name", "alternative_manufacturer") else 18
    ws.freeze_panes = ws.cell(row=head_row + 1, column=1)
    ws.auto_filter.ref = f"A{head_row}:{get_column_letter(len(columns))}{ws.max_row}"

    ws.append([])
    ws.append([f"Report body SHA-256: {body_digest(rows)}"])
    ws.cell(row=ws.max_row, column=1).font = Font(name="Arial", size=8, italic=True)

    out = io.BytesIO()
    wb.save(out)
    return out.getvalue()


# --------------------------------------------------------------------------- #
def to_pdf(rows: list[dict], meta: dict, title: str,
           columns: list[str] | None = None, notes: list[str] | None = None) -> bytes:
    from reportlab.lib import colors
    from reportlab.lib.pagesizes import A4, landscape
    from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
    from reportlab.lib.units import mm
    from reportlab.platypus import (BaseDocTemplate, Frame, PageTemplate, Paragraph,
                                    Spacer, Table, TableStyle)

    meta = _stamp(meta)
    columns = columns or (list(rows[0].keys()) if rows else [])
    styles = getSampleStyleSheet()
    cell = ParagraphStyle("cell", parent=styles["BodyText"], fontSize=7, leading=8.5)
    head = ParagraphStyle("head", parent=styles["BodyText"], fontSize=7.5, leading=9,
                          textColor=colors.white, fontName="Helvetica-Bold")
    digest = body_digest(rows)

    def decorate(canvas, doc):
        canvas.saveState()
        w, h = landscape(A4)
        canvas.setFont("Helvetica-Bold", 8)
        canvas.setFillColor(colors.HexColor("#C00000"))
        canvas.drawCentredString(w / 2, h - 10 * mm, CLASSIFICATION_BANNER)
        canvas.drawCentredString(w / 2, 8 * mm, CLASSIFICATION_BANNER)
        canvas.setFont("Helvetica", 6.5)
        canvas.setFillColor(colors.grey)
        canvas.drawString(12 * mm, 13 * mm, f"SHA-256 {digest[:32]}...")
        canvas.drawRightString(w - 12 * mm, 13 * mm, f"Page {doc.page}")
        canvas.restoreState()

    buf = io.BytesIO()
    doc = BaseDocTemplate(buf, pagesize=landscape(A4),
                          leftMargin=12 * mm, rightMargin=12 * mm,
                          topMargin=16 * mm, bottomMargin=18 * mm, title=title)
    frame = Frame(doc.leftMargin, doc.bottomMargin, doc.width, doc.height, id="body")
    doc.addPageTemplates([PageTemplate(id="main", frames=[frame], onPage=decorate)])

    story = [Paragraph(f"<b>{title}</b>", styles["Title"]),
             Paragraph(f"Generated {meta['generated_at']} by <b>{meta['generated_by']}</b> "
                       f"&nbsp;|&nbsp; database revision {meta['db_revision']} "
                       f"&nbsp;|&nbsp; {len(rows)} record(s)", styles["Normal"]),
             Spacer(1, 4 * mm)]
    for n in notes or []:
        story.append(Paragraph(n, styles["Normal"]))
    if notes:
        story.append(Spacer(1, 3 * mm))

    if not rows:
        story.append(Paragraph("<i>No records matched the selected filters.</i>",
                               styles["Normal"]))
    else:
        data = [[Paragraph(c.replace("_", " ").upper(), head) for c in columns]]
        for r in rows:
            data.append([Paragraph(str(r.get(c, ""))[:300], cell) for c in columns])
        table = Table(data, repeatRows=1, hAlign="LEFT")
        style = [
            ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#1F3864")),
            ("GRID", (0, 0), (-1, -1), 0.25, colors.HexColor("#9AA0A6")),
            ("VALIGN", (0, 0), (-1, -1), "TOP"),
            ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, colors.HexColor("#F5F6F8")]),
            ("TOPPADDING", (0, 0), (-1, -1), 2),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 2),
        ]
        for i, r in enumerate(rows, start=1):
            verdict = str(r.get("result") or r.get("is_chinese") or "")
            if verdict in ("chinese", "YES"):
                style.append(("BACKGROUND", (0, i), (-1, i), colors.HexColor("#F8CBAD")))
            elif verdict in ("unknown_origin", "UNKNOWN"):
                style.append(("BACKGROUND", (0, i), (-1, i), colors.HexColor("#FFE699")))
        table.setStyle(TableStyle(style))
        story.append(table)

    story += [Spacer(1, 5 * mm),
              Paragraph(f"<font size=6.5 color='#666666'>Report body SHA-256: {digest}<br/>"
                        f"This report reflects the component database at revision "
                        f"{meta['db_revision']}. Verdicts depend on database currency; "
                        f"confirm the database is synchronised before relying on a "
                        f"NON-CHINESE result.</font>", styles["Normal"])]
    doc.build(story)
    return buf.getvalue()


# --------------------------------------------------------------------------- #
# Report definitions
# --------------------------------------------------------------------------- #
REPORTS: dict[str, dict[str, Any]] = {
    "inspection": {
        "title": "Inspection Report",
        "columns": ["scanned_at", "raw_input", "normalized_input", "matched_component_id",
                    "component_name", "manufacturer", "country_of_origin", "result",
                    "criticality", "match_method", "match_score", "location_label", "remarks"],
    },
    "chinese_components": {
        "title": "Chinese-Origin Component Report",
        "columns": ["component_id", "component_name", "chip_number", "manufacturer",
                    "country_of_origin", "drone_subsystem", "criticality",
                    "alternative_manufacturer", "verification_source", "remarks"],
        "notes": ["Rows are ordered with CRITICAL subsystems first. A Chinese-origin part "
                  "in a CRITICAL subsystem requires escalation per the acceptance policy."],
    },
    "unknown_origin": {
        "title": "Unestablished-Origin Component Report",
        "columns": ["component_id", "component_name", "chip_number", "manufacturer",
                    "drone_subsystem", "criticality", "supplier", "remarks"],
        "notes": ["These components could not be assigned a country of origin from the "
                  "available evidence. They are neither cleared nor rejected."],
    },
    "statistics": {
        "title": "Component Statistics",
        "columns": ["metric", "value"],
    },
    "monthly": {
        "title": "Monthly Inspection Summary",
        "columns": ["month", "inspections", "scans", "chinese_hits", "unknown",
                    "not_found", "distinct_inspectors"],
    },
    "audit": {
        "title": "Audit Trail",
        "columns": ["sequence", "occurred_at", "actor_username", "action", "entity_type",
                    "entity_id", "ip_address", "hash"],
        "notes": ["The audit log is hash-chained: each entry's digest covers the previous "
                  "entry's digest. Chain verification status is stated below."],
    },
}


def build(report_key: str, rows: list[dict], meta: dict, fmt: str = "pdf") -> tuple[bytes, str, str]:
    """Return (payload, filename, media_type)."""
    spec = REPORTS.get(report_key)
    if spec is None:
        raise ValueError(f"Unknown report '{report_key}'. "
                         f"Available: {', '.join(REPORTS)}")
    title = spec["title"]
    cols = [c for c in spec["columns"] if any(c in r for r in rows)] or spec["columns"]
    ts = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    stem = f"DCOV_{report_key}_{ts}"

    if fmt == "csv":
        return to_csv(rows, cols), f"{stem}.csv", "text/csv"
    if fmt in ("xlsx", "excel"):
        return (to_xlsx(rows, meta, title, cols), f"{stem}.xlsx",
                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
    if fmt == "pdf":
        return (to_pdf(rows, meta, title, cols, spec.get("notes")),
                f"{stem}.pdf", "application/pdf")
    raise ValueError(f"Unknown format '{fmt}'. Use pdf, xlsx or csv.")
