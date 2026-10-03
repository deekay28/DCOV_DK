"""Unit tests for the import wizard's pure functions - parsing, mapping,
origin derivation and diffing. No database, no HTTP; see test_catalog_api.py
for the end-to-end stage -> commit -> rollback flow through the API."""
from __future__ import annotations

from app.services import importer as I


def test_auto_map_handles_source_workbook_headers():
    columns = ["SER NO", "MAIN COMPONENT", "SUB COMPONENT / CHIP NO", "OEM",
              "COUNTRY OF ORIGIN", "PHOTOGRAPH / REMARKS"]
    mapping, unmapped = I.auto_map_columns(columns)
    assert mapping["SUB COMPONENT / CHIP NO"] == "chip_number"
    assert mapping["OEM"] == "manufacturer"
    assert mapping["COUNTRY OF ORIGIN"] == "country_of_origin"
    assert mapping["PHOTOGRAPH / REMARKS"] == "remarks"
    assert mapping["SER NO"] == "component_id"
    assert unmapped == []


def test_auto_map_is_fuzzy_for_near_miss_headers():
    mapping, _ = I.auto_map_columns(["Manufctr Country", "Chip No."])
    assert mapping["Manufctr Country"] == "manufacturer_country"
    assert mapping["Chip No."] == "chip_number"


def test_derive_is_chinese_from_explicit_flag():
    assert I.derive_is_chinese("India", "", "YES") == "YES"
    assert I.derive_is_chinese("China", "", "NO") == "NO"      # explicit flag wins


def test_derive_is_chinese_from_country_text():
    assert I.derive_is_chinese("China") == "YES"
    assert I.derive_is_chinese("Hong Kong") == "YES"
    assert I.derive_is_chinese("India") == "NO"
    assert I.derive_is_chinese("") == "UNKNOWN"


def test_derive_is_chinese_from_remarks_phrase():
    assert I.derive_is_chinese("", "COO China, marking worn") == "YES"
    assert I.derive_is_chinese("", "Made in China") == "YES"
    assert I.derive_is_chinese("Taiwan", "Non-critical") == "NO"


def test_stable_component_id_is_deterministic_and_manufacturer_sensitive():
    row_a = {"chip_number": "STM32F302C8T6", "manufacturer": "STMicroelectronics"}
    # same chip, manufacturer written with punctuation/casing differences that
    # normalize_manufacturer's suffix-stripping (not alias resolution) handles
    row_b = {"chip_number": "stm32-f302 c8t6", "manufacturer": "st microelectronics"}
    row_c = {"chip_number": "STM32F302C8T6", "manufacturer": "Some Other Vendor"}
    row_d = {"chip_number": "STM32F302C8T6", "manufacturer": "ST Micro"}   # alias table
    assert I.stable_component_id(row_a) == I.stable_component_id(row_b)
    assert I.stable_component_id(row_a) != I.stable_component_id(row_c)
    assert I.stable_component_id(row_a) == I.stable_component_id(row_d), (
        "ST Micro' should resolve to the same identity as 'STMicroelectronics' "
        "via DEFAULT_MANUFACTURER_ALIASES")


def test_validate_row_flags_missing_identifier():
    issues = I.validate_row({"component_name": "Widget", "part_number": "",
                             "chip_number": "", "confidence_score": ""}, n=5)
    fields = {i.field for i in issues}
    assert "part_number" in fields
    assert all(i.severity == "error" for i in issues if i.field == "part_number")


def test_validate_row_flags_out_of_range_confidence():
    issues = I.validate_row({"component_name": "Widget", "part_number": "X1",
                             "confidence_score": "150"}, n=1)
    assert any(i.field == "confidence_score" and i.severity == "error" for i in issues)


def test_stage_import_classifies_new_updated_and_unchanged():
    parsed = I.ParsedFile(
        rows=[
            {"component_name": "Part A", "part_number": "PN-A", "country_of_origin": "China"},
            {"component_name": "Part B (renamed)", "part_number": "PN-B", "country_of_origin": "India"},
        ],
        columns=["component_name", "part_number", "country_of_origin"],
        file_format="csv", sha256="deadbeef")
    existing_b_id = I.stable_component_id({"part_number": "PN-B", "chip_number": "",
                                          "manufacturer": ""})
    existing = {existing_b_id: {"component_id": existing_b_id, "component_name": "Part B",
                                "part_number": "PN-B", "chip_number": "", "manufacturer": "",
                                "country_of_origin": "India", "is_chinese": "NO"}}
    staged = I.stage_import(parsed, existing, "batch-1", "test.csv")
    assert len(staged.new_rows) == 1
    assert staged.new_rows[0]["part_number"] == "PN-A"
    assert len(staged.updated_rows) == 1
    assert staged.updated_rows[0]["changed"]["component_name"]["to"] == "Part B (renamed)"


def test_stage_import_warns_on_origin_verdict_flip():
    cid = I.stable_component_id({"part_number": "PN-X", "chip_number": "", "manufacturer": ""})
    parsed = I.ParsedFile(
        rows=[{"component_name": "Part X", "part_number": "PN-X", "country_of_origin": "China"}],
        columns=["component_name", "part_number", "country_of_origin"],
        file_format="csv", sha256="abc123")
    existing = {cid: {"component_id": cid, "component_name": "Part X", "part_number": "PN-X",
                      "chip_number": "", "manufacturer": "", "country_of_origin": "USA",
                      "is_chinese": "NO"}}
    staged = I.stage_import(parsed, existing, "batch-2", "test.csv")
    assert any("change origin verdict" in w for w in staged.warnings)


def test_stage_import_is_idempotent_on_replay():
    """Staging the same file twice against its own committed output must
    report everything unchanged - this is what makes a repeated import safe."""
    row = {"component_name": "Part Y", "part_number": "PN-Y", "country_of_origin": "India"}
    parsed = I.ParsedFile(rows=[row], columns=list(row), file_format="csv", sha256="x")
    first = I.stage_import(parsed, {}, "b1", "t.csv")
    assert len(first.new_rows) == 1
    committed = {r["component_id"]: r for r in first.new_rows}
    second = I.stage_import(parsed, committed, "b2", "t.csv")
    assert len(second.new_rows) == 0
    assert len(second.updated_rows) == 0
    assert second.unchanged == 1


def test_parse_sql_only_reads_insert_statements():
    payload = (b"DROP TABLE components;\n"
              b"INSERT INTO components (part_number, manufacturer) "
              b"VALUES ('PN-1', 'Acme'), ('PN-2', 'O''Brien Ltd');\n")
    parsed = I._parse_sql(payload, "digest")
    assert len(parsed.rows) == 2
    assert parsed.rows[1]["manufacturer"] == "O'Brien Ltd"   # escaped quote handled
