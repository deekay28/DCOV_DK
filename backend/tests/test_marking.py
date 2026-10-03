"""Marking-consistency (anti-remark) layer. Pure functions - no app or DB."""
from app.services.marking import analyse, apply_to_verdict

GREEN = {"result": "non_chinese", "banner": "GREEN", "headline": "NON-CHINESE COMPONENT",
         "criticality": "CRITICAL", "confidence": 100.0}
RED = {"result": "chinese", "banner": "RED", "headline": "CHINESE COMPONENT DETECTED",
       "criticality": "CRITICAL", "confidence": 100.0}
ST = "STMICROELECTRONICS"


def test_real_pdf_marking_reads_china_country_code():
    # Lines as recovered by enhancement from the HQ TG EME document photo.
    text = "32G491KCU6\nGQ 21U 9R\nCHN 30 2B1"
    a = analyse(text, manufacturer=ST, part_key="STM32G491KCU6", catalogue_is_chinese="YES")
    assert a.country_code == "CHN"
    assert [f.code for f in a.findings] == ["unit_marked_china"]


def test_unit_marked_china_overrides_a_non_chinese_catalogue_entry():
    # STM32G484 is catalogued Philippines / non-Chinese; this unit says CHN.
    a = analyse("32G484CEU6\nGQ 22X 7A\nCHN 31 4C2", manufacturer=ST,
                part_key="STM32G484", catalogue_is_chinese="NO")
    assert a.findings[0].code == "unit_marked_china_catalogue_non_chinese"
    v = apply_to_verdict(GREEN, a)
    assert v["banner"] == "RED" and v["result"] == "chinese"
    assert v["escalate"] is True            # CRITICAL subsystem


def test_china_assembly_site_code_with_foreign_country_code_is_a_remark_signature():
    a = analyse("32G484CEU6\nGK 22X 7A\nPHL 31 4C2", manufacturer=ST,
                part_key="STM32G484", catalogue_is_chinese="NO")
    assert a.country_code == "PHL"
    assert any(f.code == "site_code_contradicts_country_code" and f.severity == "red"
               for f in a.findings)
    assert apply_to_verdict(GREEN, a)["banner"] == "RED"


def test_consistent_non_china_marking_leaves_green_alone():
    a = analyse("32G484CEU6\nGQ 22X 7A\nPHL 31 4C2", manufacturer=ST,
                part_key="STM32G484", catalogue_is_chinese="NO")
    assert a.findings == []
    assert apply_to_verdict(GREEN, a) == GREEN


def test_china_wafer_fab_code_downgrades_green_to_yellow_not_red():
    a = analyse("32G484CEU6\nY5 22X 7A\nPHL 31 4C2", manufacturer=ST,
                part_key="STM32G484", catalogue_is_chinese="NO")
    assert [f.severity for f in a.findings] == ["yellow"]
    assert apply_to_verdict(GREEN, a)["banner"] == "YELLOW"


def test_foreign_code_on_a_part_recorded_as_chinese_never_relaxes_red():
    a = analyse("32G491KCU6\nGQ 21U 9R\nMYS 30 2B1", manufacturer=ST,
                part_key="STM32G491KCU6", catalogue_is_chinese="YES")
    assert a.findings[0].code == "country_code_disagrees_with_catalogue"
    assert apply_to_verdict(RED, a)["banner"] == "RED"


def test_missing_country_code_on_a_complete_st_marking_is_flagged():
    a = analyse("32G484CEU6\nGQ 22X 7A\n31 4C2", manufacturer=ST,
                part_key="STM32G484", catalogue_is_chinese="NO")
    assert [f.code for f in a.findings] == ["country_code_missing"]
    assert apply_to_verdict(GREEN, a)["banner"] == "YELLOW"


def test_site_codes_are_scoped_to_the_manufacturer():
    # "GK" means ST Shenzhen only on an ST part - on anyone else's chip it is noise.
    a = analyse("TPS62130\nGK 4A\nPHL", manufacturer="Texas Instruments",
                part_key="TPS62130", catalogue_is_chinese="NO")
    assert a.site_codes == [] and a.findings == []


def test_single_line_typed_input_produces_no_false_alarms():
    a = analyse("STM32G484", manufacturer=ST, part_key="STM32G484", catalogue_is_chinese="NO")
    assert a.findings == []


def test_not_found_verdict_is_never_rewritten():
    a = analyse("XYZ123\nCHN", manufacturer=None, part_key=None, catalogue_is_chinese=None)
    nf = {"result": "not_found", "banner": "GREY", "headline": "COMPONENT NOT FOUND"}
    assert apply_to_verdict(nf, a) == nf


def test_whole_marking_on_one_line_still_finds_the_country_code():
    a = analyse("32G484CEU6 GQ 22X 7A CHN 31 4C2", manufacturer=ST,
                part_key="STM32G484", catalogue_is_chinese="NO")
    assert a.country_code == "CHN"
    assert apply_to_verdict(GREEN, a)["banner"] == "RED"
