"""Origin-decision rules - see ORIGIN_VERIFICATION_LOGIC.md.

Each test pins one rule that protects against a false GREEN (false negative
for Chinese origin) or an unsupported RED.
"""
from __future__ import annotations

import json
from pathlib import Path

import pytest

from app.services.marking import analyse, apply_to_verdict
from app.services.matching import (ComponentIndex, Matcher, origin_evidence,
                                   parse_label_barcode, verdict_for)

SEED = Path(__file__).resolve().parents[2] / "data" / "components_seed.json"


@pytest.fixture(scope="module")
def index():
    return ComponentIndex(json.loads(SEED.read_text()))


def _run(raw, index, ocr_text=""):
    r = Matcher().match(raw, index)
    v = verdict_for(r.component, r.score, r.method)
    c = r.component or {}
    m = analyse(ocr_text or raw, manufacturer=c.get("manufacturer"),
                part_key=c.get("chip_number") or c.get("part_number"),
                catalogue_is_chinese=c.get("is_chinese"))
    return r, apply_to_verdict(v, m)


# -- A/B: documented component-level origin --------------------------------
def test_documented_chinese_component_is_red_with_component_evidence(index):
    r, v = _run("STM32F302C8T6", index)
    assert v["banner"] == "RED" and v["origin_evidence"] == "component"
    assert "watchlist" in v["evidence_detail"].lower()


def test_documented_non_chinese_component_is_green_only_with_component_evidence(index):
    r, v = _run("ADF4350", index)
    assert v["banner"] == "GREEN"
    assert v["origin_evidence"] == "component"
    assert v["review_required"] is False
    assert v["policy_decision"].startswith("ACCEPTABLE")


# -- brand / OEM home country is not component origin -----------------------
def test_oem_home_country_alone_never_gives_green(index):
    rows = [r for r in index.rows if r["category"] == "OEM / LRU" and r["is_chinese"] == "NO"]
    assert rows, "seed should contain manufacturer-level rows"
    for row in rows:
        v = verdict_for(row, 100.0, "normalized")
        assert v["banner"] == "YELLOW", row["component_name"]
        assert v["origin_evidence"] == "manufacturer"


def test_chinese_oem_stays_red_but_says_it_is_manufacturer_level(index):
    row = next(r for r in index.rows if r["category"] == "OEM / LRU" and r["is_chinese"] == "YES")
    v = verdict_for(row, 100.0, "normalized")
    assert v["banner"] == "RED"
    assert "MANUFACTURER" in v["headline"]


# -- G: unknown origin --------------------------------------------------------
def test_unknown_origin_is_yellow_requires_review(index):
    row = next(r for r in index.rows if r["is_chinese"] == "UNKNOWN")
    v = verdict_for(row, 100.0, "normalized")
    assert v["banner"] == "YELLOW" and v["review_required"]
    assert origin_evidence(row)[0] == "none"


# -- C / F: uncertain identification never yields a clean pass ---------------
@pytest.mark.parametrize("method", ["fuzzy", "prefix", "ocr_folded", "ocr_folded_stripped"])
def test_uncertain_match_methods_cannot_produce_green(index, method):
    row = next(r for r in index.rows if r["chip_number"] == "ADF4350")
    v = verdict_for(row, 95.0, method)
    assert v["banner"] == "YELLOW"
    assert "REVIEW" in v["headline"]


def test_uncertain_match_to_chinese_part_stays_red_but_flags_review(index):
    row = next(r for r in index.rows if r["chip_number"] == "STM32F302C8T6")
    v = verdict_for(row, 88.0, "prefix")
    assert v["banner"] == "RED" and v["review_required"]
    assert "PROBABLE" in v["headline"]


def test_multi_glyph_ocr_misread_is_review_not_green(index):
    # "MX25L12833F" read with S for 5 and I for 1 - resolves only by folding
    r, v = _run("MX2SLI2833F", index)
    assert r.method == "ocr_folded"
    assert v["banner"] == "YELLOW"


def test_single_glyph_ocr_repair_is_still_trusted(index):
    r, v = _run("STM32F3O2C8T6", index)
    assert r.method == "ocr_corrected"
    assert v["banner"] == "RED"


# -- unit marking outranks the catalogue -------------------------------------
def test_chn_marking_on_non_chinese_catalogue_part_turns_red(index):
    r, v = _run("ADF4350", index, ocr_text="ADF4350\nCHN 2219")
    assert v["banner"] == "RED"
    assert v["origin_evidence"] == "unit_marking"


# -- D: unknown component ------------------------------------------------------
def test_not_in_catalogue_is_grey(index):
    r, v = _run("SN74LVC1G08", index)
    assert v["banner"] == "GREY" and v["review_required"]


# -- barcode prefix is never origin evidence ---------------------------------
def test_gs1_prefix_is_not_used_for_origin(index):
    # 690-699 is the China GS1 prefix range. An EAN-13 that is not in the
    # catalogue must come back GREY, not RED.
    r, v = _run("6901234567892", index)
    assert v["banner"] == "GREY"


# -- H: reel / bag label barcodes --------------------------------------------
def test_ecia_label_payload_is_parsed_to_manufacturer_part_number():
    raw = "[)>\x1e06\x1dPCUST-01\x1d1PSTM32F302C8T6\x1d1TGQ23J\x1d4LCN\x1dQ100\x1e\x04"
    f = parse_label_barcode(raw)
    assert f["mpn"] == "STM32F302C8T6" and f["label_coo"] == "CN" and f["lot"] == "GQ23J"


def test_label_coo_is_reported_but_does_not_decide_the_verdict(index):
    # Non-Chinese catalogue part, label claims CN: verdict follows the
    # catalogue (GREEN), the claim is shown in the notes.
    raw = "[)>\x1e06\x1d1PADF4350\x1d4LCN\x1e\x04"
    r, v = _run(raw, index)
    assert r.method == "label_mpn"
    assert v["banner"] == "GREEN"
    assert any("4L" in n for n in r.notes)


def test_single_field_code128_label(index):
    r, v = _run("1PMX25L12833F", index)
    assert r.component and r.component["chip_number"] == "MX25L12833F"


def test_plain_text_is_not_mistaken_for_a_label():
    assert parse_label_barcode("STM32F302C8T6") == {}
    assert parse_label_barcode("1P", allow_single_field=True) == {}


# -- E: multiple records disagreeing on origin --------------------------------
def test_conflicting_records_are_not_silently_resolved():
    rows = [
        {"component_id": "A", "chip_number": "XYZ12345", "is_chinese": "YES",
         "country_of_origin": "China", "confidence_score": "90"},
        {"component_id": "B", "chip_number": "XYZ12345", "is_chinese": "NO",
         "country_of_origin": "USA", "confidence_score": "90"},
    ]
    r = Matcher().match("XYZ12345", ComponentIndex(rows))
    assert r.method == "conflict" and r.component is None


# -- "Unknown" is not a country ----------------------------------------------
def test_explicit_unknown_country_is_not_derived_as_non_chinese():
    from app.services.importer import derive_is_chinese
    assert derive_is_chinese("Unknown", "", "UNKNOWN") == "UNKNOWN"
    assert derive_is_chinese("N/A") == "UNKNOWN"
    assert derive_is_chinese("Taiwan") == "NO"
    assert derive_is_chinese("Unknown", "COO China") == "YES"


def test_record_with_unknown_country_never_green():
    row = {"component_id": "X", "chip_number": "ABC12345", "is_chinese": "NO",
           "country_of_origin": "Unknown", "confidence_score": "95",
           "verification_source": "teardown"}
    assert verdict_for(row, 100.0, "normalized")["banner"] == "YELLOW"


def test_seeded_server_catalogue_keeps_unknown_records_unknown(client, admin_headers):
    d = client.get("/api/v1/dashboard", headers=admin_headers).json()
    seed = json.loads(SEED.read_text())
    assert d["unknown_origin"] == sum(1 for r in seed if r["is_chinese"] == "UNKNOWN")
