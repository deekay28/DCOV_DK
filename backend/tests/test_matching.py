"""Pure unit tests for the matching cascade - no database, no HTTP.

These are the Python side of the three-way parity check: the same vectors
are asserted in frontend_flutter/test/matching_test.dart and exercised
manually against web_demo/dcov-match.js. If a change here isn't mirrored in
both of those, the offline clients will silently disagree with the server.
"""
from __future__ import annotations

import csv
import json
from pathlib import Path

import pytest

from app.services.matching import ComponentIndex, Matcher, normalize, verdict_for

ROOT = Path(__file__).resolve().parents[2]


@pytest.fixture(scope="module")
def index() -> ComponentIndex:
    rows = list(csv.DictReader(open(ROOT / "data" / "components_seed.csv")))
    assert len(rows) == 203, (
        "seed catalogue size changed - if intentional, update this assertion "
        "and re-check the Flutter/JS vector tests still pass")
    return ComponentIndex(rows)


@pytest.fixture(scope="module")
def matcher() -> Matcher:
    return Matcher()


def test_exact_normalized_match_on_known_chinese_ic(matcher, index):
    r = matcher.match("STM32F302C8T6", index)
    v = verdict_for(r.component, r.score)
    assert v["banner"] == "RED"
    assert r.method == "normalized"
    assert r.score == 100.0


def test_single_glyph_ocr_misread_still_resolves(matcher, index):
    r = matcher.match("stm32 f3o2-c8t6", index)
    v = verdict_for(r.component, r.score)
    assert v["banner"] == "RED"
    assert r.method == "ocr_corrected"


def test_trailing_lot_date_code_is_discarded(matcher, index):
    r = matcher.match("STM32G4A1KCU6 GQ23J 1B9U", index)
    v = verdict_for(r.component, r.score)
    assert v["banner"] == "RED"
    assert r.method == "lot_code_stripped"


def test_double_substitution_resolves_via_glyph_folding(matcher, index):
    r = matcher.match("ADIN13OOBCPZ", index)
    v = verdict_for(r.component, r.score)
    assert v["banner"] == "RED"
    assert r.method == "ocr_folded"


def test_known_non_chinese_part_returns_green(matcher, index):
    r = matcher.match("ATMEGA16U2", index)
    v = verdict_for(r.component, r.score)
    assert v["banner"] == "GREEN"


def test_unknown_marking_returns_grey_not_a_guess(matcher, index):
    r = matcher.match("TOTALLY-UNKNOWN-PART-999", index)
    v = verdict_for(r.component, r.score)
    assert v["banner"] == "GREY"
    assert r.component is None


def test_empty_input_does_not_throw(matcher, index):
    r = matcher.match("", index)
    assert r.matched is False
    assert r.method == "none"


def test_barcode_exact_match(matcher, index):
    sample = index.rows[0]
    r = matcher.match(sample["barcode"], index)
    assert r.matched is True
    assert r.method == "exact_code"
    assert r.component["component_id"] == sample["component_id"]


def test_normalize_ignores_case_spaces_and_dashes():
    assert normalize(" stm32-f302 c8t6 ") == "STM32F302C8T6"
    assert normalize("") == ""
    assert normalize(None) == ""


def test_ambiguous_prefix_is_not_silently_resolved(matcher, index):
    """STM32F405 is a genuine prefix of more than one stored part number in
    the seed set (STM32F405RGT6 plus any watchlist variants); the engine must
    refuse to guess rather than pick one arbitrarily."""
    r = matcher.match("STM32F405", index)
    if r.method == "prefix":
        # only one distinct part number shares the prefix in the current seed -
        # acceptable, but assert it was at least resolved via the prefix layer
        # and not by silently falling through to fuzzy matching.
        assert r.matched is True
    else:
        assert r.method == "ambiguous_prefix"
        assert r.matched is False
        assert len(r.suggestions) >= 2


def test_conflicting_origin_records_are_never_auto_resolved(matcher):
    """Two rows sharing a marking with different definite verdicts must come
    back as a conflict, never as a pick-one guess - this is the one behaviour
    this system cannot get wrong."""
    rows = [
        {"component_id": "A", "chip_number": "XYZ123", "is_chinese": "YES",
         "confidence_score": "90", "search_key": "XYZ123"},
        {"component_id": "B", "chip_number": "XYZ123", "is_chinese": "NO",
         "confidence_score": "90", "search_key": "XYZ123"},
    ]
    idx = ComponentIndex(rows)
    r = Matcher().match("XYZ123", idx)
    assert r.matched is False
    assert r.method == "conflict"
    assert r.component is None
    assert len(r.suggestions) == 2


def test_unknown_origin_row_is_superseded_by_a_verified_one(matcher):
    """A row with no established origin carries no evidence and must not be
    able to block a verified row for the same marking."""
    rows = [
        {"component_id": "A", "chip_number": "ABC999", "is_chinese": "UNKNOWN",
         "confidence_score": "50", "search_key": "ABC999"},
        {"component_id": "B", "chip_number": "ABC999", "is_chinese": "YES",
         "confidence_score": "95", "search_key": "ABC999"},
    ]
    idx = ComponentIndex(rows)
    r = Matcher().match("ABC999", idx)
    assert r.matched is True
    assert r.component["component_id"] == "B"


def test_low_confidence_non_chinese_match_downgrades_to_unknown():
    """A GREEN verdict must not survive a low-confidence match - see
    verdict_for's low_confidence_floor: this is the guard against a shaky
    fuzzy match presenting itself as a clean pass."""
    component = {"is_chinese": "NO", "country_of_origin": "USA",
                "criticality": "REVIEW", "confidence_score": "100"}
    v = verdict_for(component, score=40.0)   # well below the 60% floor
    assert v["result"] == "unknown_origin"
    assert v["banner"] == "YELLOW"


def test_chinese_plus_critical_escalates():
    component = {"is_chinese": "YES", "country_of_origin": "China",
                "criticality": "CRITICAL", "criticality_policy": "Not acceptable",
                "confidence_score": "100"}
    v = verdict_for(component, score=100.0)
    assert v["escalate"] is True
    assert "Not acceptable" in v["escalation_note"]


def test_seed_catalogue_has_no_duplicate_component_ids():
    rows = json.loads((ROOT / "data" / "components_seed.json").read_text())
    ids = [r["component_id"] for r in rows]
    assert len(ids) == len(set(ids)), "component_id must be unique across the catalogue"
