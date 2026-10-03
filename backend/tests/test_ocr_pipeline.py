"""The real OCR pipeline (Tesseract + OpenCV), end to end, on rendered chip
markings - see tests/chip_images.py for what these images are and are not.

Skipped automatically where the vision extras or the tesseract binary are not
installed, so the core suite still runs on a minimal server.
"""
from __future__ import annotations

import json
import shutil
from pathlib import Path

import pytest

cv2 = pytest.importorskip("cv2")
pytest.importorskip("pytesseract")
if shutil.which("tesseract") is None:  # pragma: no cover
    pytest.skip("tesseract binary not installed", allow_module_level=True)

from app.services.marking import analyse, apply_to_verdict  # noqa: E402
from app.services.matching import ComponentIndex, Matcher, verdict_for  # noqa: E402
from app.services.ocr import read_markings  # noqa: E402

from .chip_images import board, chip, jpeg  # noqa: E402

SEED = Path(__file__).resolve().parents[2] / "data" / "components_seed.json"
INDEX = ComponentIndex(json.loads(SEED.read_text()))


def chain(img_bytes, multi=False):
    r = read_markings(img_bytes, multi_chip=multi)
    m = Matcher().match(r.best, INDEX) if r.best else None
    comp = m.component if m else None
    v = verdict_for(comp, m.score if m else 0, m.method if m else None)
    c = comp or {}
    mk = analyse(r.full_text, manufacturer=c.get("manufacturer"),
                 part_key=c.get("chip_number") or c.get("part_number"),
                 catalogue_is_chinese=c.get("is_chinese"))
    return r, m, apply_to_verdict(v, mk), mk


def test_chinese_part_with_coo_line():
    r, m, v, mk = chain(jpeg(chip(["ST", "STM32F302C8T6", "GQ23J 1B9U", "CHN 302"])))
    assert r.best == "STM32F302C8T6"
    assert mk.country_code == "CHN", r.full_text   # was dropped before the whitelist fix
    assert v["banner"] == "RED"


def test_non_chinese_part_reads_country_line():
    r, m, v, mk = chain(jpeg(chip(["MX25L12833F", "TWN 2219"])))
    assert m.component["chip_number"] == "MX25L12833F"
    assert mk.country_code == "TWN"
    assert v["banner"] == "GREEN"


def test_unknown_part_is_grey():
    r, m, v, _ = chain(jpeg(chip(["SN74LVC1G08", "TI 2231"])))
    assert r.best == "SN74LVC1G08"
    assert v["banner"] == "GREY"


@pytest.mark.parametrize("angle", [8, 25, -30, 90, 180, -90])
def test_rotated_package_is_read(angle):
    # 25 degrees used to crash (OpenCV 5 HoughLinesP shape) and then misread
    r, m, v, mk = chain(jpeg(chip(["STM32F302C8T6", "CHN 302"], rotate=angle)))
    assert r.best == "STM32F302C8T6", (angle, r.candidates, r.warnings)
    assert v["banner"] == "RED"


def test_low_light_and_noise():
    r, *_ = chain(jpeg(chip(["ADF4350", "PHL 2219"], brightness=0.35)))
    assert r.best == "ADF4350"
    r, *_ = chain(jpeg(chip(["EFR32FG13P231HG", "USA"], noise=25)))
    assert r.best == "EFR32FG13P231HG"


def test_small_glyphs():
    r, *_ = chain(jpeg(chip(["EFR32FG13P231HG", "USA"], glyph=14)))
    assert r.best == "EFR32FG13P231HG"


def test_heavy_blur_never_gives_a_clean_green():
    r, m, v, _ = chain(jpeg(chip(["MX25L12833F", "TWN 2219"], blur=4.0)))
    assert v["banner"] != "GREEN" or r.best == "MX25L12833F"


def test_saturating_glare_degrades_to_not_found_not_to_a_wrong_answer():
    r, m, v, _ = chain(jpeg(chip(["ADF4350BCPZ", "PHL 2219"], glare=True)))
    assert v["banner"] in ("GREY", "YELLOW") or (m and m.component
                                                 and m.component["chip_number"].startswith("ADF4350"))


def test_two_chips_on_one_board_are_verified_separately():
    img = board([chip(["STM32F302C8T6", "CHN"]), chip(["MX25L12833F", "TWN"], seed=3)])
    r = read_markings(jpeg(img), multi_chip=True)
    assert r.multiple_parts
    bests = {c["best"] for c in r.chips}
    assert {"STM32F302C8T6", "MX25L12833F"} <= bests
    for c in r.chips:   # COO line stays with its own package
        if c["best"] == "MX25L12833F":
            assert "CHN" not in c["full_text"]


def test_two_chips_without_multi_mode_are_flagged():
    img = board([chip(["STM32F302C8T6", "CHN"]), chip(["MX25L12833F", "TWN"], seed=3)])
    r = read_markings(jpeg(img), multi_chip=False)
    assert r.multiple_parts
    assert any("different part numbers" in w for w in r.warnings)


def test_garbage_image_does_not_crash():
    r = read_markings(b"not an image")
    assert r.best == "" and r.warnings
