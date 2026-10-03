"""Chip-marking OCR.

Reading a laser-etched IC is not general OCR. The text is low-contrast, often
specular, frequently rotated, and the *useful* line is rarely the largest one -
a package typically carries a logo, a part number, a date code and a lot code,
and only the part number matters. This module therefore:

  1. normalises the image (deskew, glare suppression, CLAHE, denoise, sharpen)
  2. runs several preprocessing variants and several engines
  3. votes across the results per text line
  4. classifies each line as part number / date code / lot code / vendor
  5. returns ranked candidate markings, never a single guess

On mobile the same job is done on-device by Google ML Kit (see the Flutter
`OcrService`); this server path exists for desktop/web clients, for batch
re-processing of stored images, and as the higher-accuracy second opinion.
"""
from __future__ import annotations

import logging
import re
from dataclasses import dataclass, field
from typing import Any

log = logging.getLogger(__name__)

try:
    import cv2
    import numpy as np
    HAS_CV = True
except ImportError:  # pragma: no cover - server can run without vision extras
    HAS_CV = False


# --------------------------------------------------------------------------- #
@dataclass
class TextLine:
    text: str
    confidence: float
    box: tuple[int, int, int, int] | None = None
    engine: str = ""
    variant: str = ""
    # "word" = one token; "line" = a whole physical line of the package
    # marking with its inter-word spaces preserved (e.g. "CHN 302"). Line
    # entries are what the marking-consistency check reads; word entries are
    # what candidate ranking reads.
    level: str = "word"


@dataclass
class OcrResult:
    candidates: list[str] = field(default_factory=list)      # ranked markings
    lines: list[TextLine] = field(default_factory=list)
    full_text: str = ""
    best: str = ""
    best_confidence: float = 0.0
    classification: dict[str, list[str]] = field(default_factory=dict)
    engines_used: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    # Populated only when more than one package was segmented (multi-chip
    # mode): one summarize_for_api()-shaped dict per package, plus its box.
    chips: list[dict] = field(default_factory=list)
    # True when the frame evidently holds more than one component.
    multiple_parts: bool = False


# --------------------------------------------------------------------------- #
# Marking classification
# --------------------------------------------------------------------------- #
# A real part number: starts with 1-5 letters, contains at least one digit,
# 5-24 chars overall. 'STM32F302C8T6', 'ADIN1300BCPZ', 'MS1224', 'RTL8822CE'.
RE_PART = re.compile(r"^[A-Z]{1,5}[A-Z0-9\-/]{3,22}$")
# 4-digit YYWW date code, or a 3-4 char lot code - present on nearly every chip
# and never the identifier we want to search on.
RE_DATE = re.compile(r"^(19|20)?\d{2}(0[1-9]|[1-4]\d|5[0-3])$")
RE_LOT = re.compile(r"^[A-Z0-9]{2,6}$")
RE_COO = re.compile(r"\b(CHN|CHINA|TWN|TAIWAN|PHL|PHILIPPINES|MYS|MALAYSIA|KOR|KOREA|"
                    r"SGP|SINGAPORE|USA|JPN|JAPAN|FRA|ITA|MLT|MADE IN [A-Z]+)\b")
VENDOR_WORDS = {"STMICROELECTRONICS", "ST", "TI", "TEXAS", "NXP", "MICROCHIP", "ATMEL",
                "REALTEK", "BROADCOM", "ANALOG", "DEVICES", "MEDIATEK", "SANDISK",
                "MACRONIX", "WINBOND", "CIRRUS", "SILICON", "LABS", "NVIDIA", "XILINX",
                "MICRON", "ONSEMI", "DIODES", "ALLWINNER", "FORESEE", "MONOLITHIC"}
NOISE = {"E4", "CE", "FC", "ROHS", "PB", "LF", "GREEN", "ESD"}


def classify_marking(text: str) -> str:
    t = re.sub(r"\s+", "", text.upper())
    if not t:
        return "noise"
    if RE_COO.search(text.upper()):
        return "country_of_origin"
    if t in VENDOR_WORDS or any(t.startswith(v) and len(t) <= len(v) + 2 for v in VENDOR_WORDS):
        return "vendor"
    if t in NOISE:
        return "noise"
    if RE_DATE.fullmatch(t) and len(t) == 4:
        return "date_code"
    if RE_PART.fullmatch(t) and any(c.isdigit() for c in t) and len(t) >= 5:
        return "part_number"
    if RE_LOT.fullmatch(t):
        return "lot_code"
    return "other"


def score_candidate(text: str) -> float:
    """Higher = more likely to be the searchable part number."""
    t = re.sub(r"[^A-Z0-9]", "", text.upper())
    kind = classify_marking(text)
    base = {"part_number": 100.0, "other": 55.0, "lot_code": 25.0,
            "date_code": 5.0, "vendor": 10.0, "country_of_origin": 15.0,
            "noise": 0.0}[kind]
    if 8 <= len(t) <= 16:
        base += 12
    elif len(t) < 6:
        base -= 20
    letters = sum(c.isalpha() for c in t)
    digits = sum(c.isdigit() for c in t)
    if letters and digits:
        base += 8                      # alphanumeric mix is the norm for part numbers
    if digits and letters == 0:
        base -= 15
    return base


# --------------------------------------------------------------------------- #
# Image preprocessing
# --------------------------------------------------------------------------- #
def _variants(img: "np.ndarray") -> list[tuple[str, "np.ndarray"]]:
    """Produce several renderings; different engines win on different ones."""
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY) if img.ndim == 3 else img
    gray = _deskew(gray)
    gray = _suppress_glare(gray)

    clahe = cv2.createCLAHE(clipLimit=3.0, tileGridSize=(8, 8)).apply(gray)
    denoised = cv2.fastNlMeansDenoising(clahe, None, h=10, templateWindowSize=7,
                                        searchWindowSize=21)
    sharp = cv2.filter2D(denoised, -1,
                         np.array([[0, -1, 0], [-1, 5, -1], [0, -1, 0]], dtype=np.float32))
    otsu = cv2.threshold(sharp, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)[1]
    adaptive = cv2.adaptiveThreshold(sharp, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
                                     cv2.THRESH_BINARY, 31, 9)
    # Laser etching is usually *lighter* than the package; the inverse is what
    # a text detector trained on printed documents expects.
    return [("sharp", sharp), ("otsu", otsu), ("otsu_inv", cv2.bitwise_not(otsu)),
            ("adaptive", adaptive), ("clahe", clahe)]


def _deskew(gray: "np.ndarray") -> "np.ndarray":
    """Rotate so the marking lines are horizontal.

    Uses the glyph-blob angle (_text_angle), not Hough lines over all edges:
    the Hough version locked onto the package outline, PCB traces and image
    borders as readily as onto text, and on a 25-degree photo it "corrected"
    an already-level marking back off-level. Found with the rotated test
    images in tests/test_ocr_pipeline.py.
    """
    angle = _text_angle(gray)
    if angle is None or abs(angle) < 0.5:
        return gray
    return _rotate(gray, angle)


def _suppress_glare(gray: "np.ndarray") -> "np.ndarray":
    """Specular highlights from ring lights blow out whole characters. Detect
    saturated blobs and inpaint them from surrounding package texture."""
    _, mask = cv2.threshold(gray, 245, 255, cv2.THRESH_BINARY)
    if cv2.countNonZero(mask) < gray.size * 0.002:
        return gray
    mask = cv2.dilate(mask, np.ones((5, 5), np.uint8), iterations=1)
    return cv2.inpaint(gray, mask, 3, cv2.INPAINT_TELEA)


def detect_chip_regions(img: "np.ndarray", min_area_ratio: float = 0.01) -> list[tuple]:
    """Segment individual IC packages on a board so each is read separately.

    Without this, a photo of a whole PCB yields one soup of interleaved text
    lines from six different chips.
    """
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY) if img.ndim == 3 else img
    blur = cv2.GaussianBlur(gray, (5, 5), 0)
    edges = cv2.Canny(blur, 30, 120)
    closed = cv2.morphologyEx(edges, cv2.MORPH_CLOSE, np.ones((9, 9), np.uint8))
    contours, _ = cv2.findContours(closed, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    out = []
    total = gray.shape[0] * gray.shape[1]
    for c in contours:
        x, y, w, h = cv2.boundingRect(c)
        if w * h < total * min_area_ratio:
            continue
        ar = w / max(h, 1)
        if 0.25 <= ar <= 4.0:                       # IC packages are roughly rectangular
            out.append((x, y, w, h))
    out.sort(key=lambda b: -(b[2] * b[3]))
    return out[:12]


# --------------------------------------------------------------------------- #
# Engines
# --------------------------------------------------------------------------- #
class _Engine:
    name = "base"

    def available(self) -> bool:
        return False

    def read(self, image: "np.ndarray") -> list[TextLine]:
        raise NotImplementedError


class TesseractEngine(_Engine):
    name = "tesseract"
    # PSM 11 = sparse text; chip markings are not paragraphs.
    # The whitelist MUST contain a space and MUST be quoted: pytesseract splits
    # this string with shlex, and the previous unquoted form silently dropped
    # the trailing space from the whitelist. Without a space in the whitelist
    # Tesseract's LSTM glues multi-word lines together ("CHN 302" ->
    # "CHN302") and reports confidence 0 for them, so every lot-code and
    # country-of-origin line was discarded by the conf > 30 filter below -
    # found by running the pipeline on rendered test markings, see
    # tests/test_ocr_pipeline.py.
    CONFIG = ('--oem 1 --psm 11 '
              '-c "tessedit_char_whitelist=ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-/. "')

    def available(self) -> bool:
        try:
            import pytesseract  # noqa: F401
            return True
        except ImportError:
            return False

    def read(self, image):
        import pytesseract
        from pytesseract import Output
        data = pytesseract.image_to_data(image, config=self.CONFIG, output_type=Output.DICT)
        out = []
        physical: dict[tuple, list[tuple[int, str, float]]] = {}
        for i, txt in enumerate(data["text"]):
            txt = (txt or "").strip()
            conf = float(data["conf"][i])
            if txt and conf > 30:
                out.append(TextLine(txt, conf, (data["left"][i], data["top"][i],
                                                data["width"][i], data["height"][i]),
                                    self.name))
                key = (data["block_num"][i], data["par_num"][i], data["line_num"][i])
                physical.setdefault(key, []).append((data["left"][i], txt, conf))
        # Re-assemble physical lines (left-to-right) so "CHN 302" survives as
        # one line with its space - see TextLine.level.
        for words in physical.values():
            if len(words) < 2:
                continue
            words.sort()
            out.append(TextLine(" ".join(w for _, w, _ in words),
                                sum(c for _, _, c in words) / len(words),
                                None, self.name, level="line"))
        return out


class EasyOcrEngine(_Engine):
    name = "easyocr"
    _reader = None

    def available(self) -> bool:
        try:
            import easyocr  # noqa: F401
            return True
        except ImportError:
            return False

    def read(self, image):
        import easyocr
        if EasyOcrEngine._reader is None:
            from app.core.config import settings
            EasyOcrEngine._reader = easyocr.Reader(["en"], gpu=settings.ocr_gpu, verbose=False)
        out = []
        for box, txt, conf in EasyOcrEngine._reader.readtext(image, detail=1,
                                                             allowlist=None, paragraph=False):
            txt = (txt or "").strip()
            if txt and conf > 0.3:
                xs = [int(p[0]) for p in box]
                ys = [int(p[1]) for p in box]
                out.append(TextLine(txt, conf * 100,
                                    (min(xs), min(ys), max(xs) - min(xs), max(ys) - min(ys)),
                                    self.name))
        return out


ENGINES: list[_Engine] = [EasyOcrEngine(), TesseractEngine()]


# --------------------------------------------------------------------------- #
def physical_lines(lines: list[TextLine]) -> list[str]:
    """Distinct physical marking lines, spaces preserved, most-agreed first.

    Single-word lines (a part number alone on its line) come from word
    entries; multi-word lines come from the engine's line reconstruction.
    Words that already appear inside a multi-word line are not repeated.
    """
    multi: dict[str, list[TextLine]] = {}
    for ln in lines:
        if ln.level == "line":
            key = re.sub(r"\s+", " ", ln.text.upper()).strip()
            multi.setdefault(key, []).append(ln)
    covered = {w for k in multi for w in k.split()}
    out: list[tuple[float, str]] = []
    for key, group in multi.items():
        out.append((len({(g.engine, g.variant) for g in group}), key))
    singles: dict[str, set] = {}
    for ln in lines:
        if ln.level != "word":
            continue
        w = ln.text.upper().strip()
        if w and w not in covered:
            singles.setdefault(w, set()).add((ln.engine, ln.variant))
    out.extend((len(v), k) for k, v in singles.items())
    out.sort(key=lambda t: -t[0])
    return [k for _, k in out]


def merge_lines(lines: list[TextLine]) -> list[tuple[str, float, int]]:
    """Vote across engines/variants. A string read identically by two engines on
    two different preprocessings is far more trustworthy than one high-confidence
    read from one engine, so agreement count feeds the final score."""
    buckets: dict[str, list[TextLine]] = {}
    for ln in lines:
        if ln.level != "word":
            continue
        key = re.sub(r"[^A-Z0-9]", "", ln.text.upper())
        if len(key) < 2:
            continue
        buckets.setdefault(key, []).append(ln)
    merged = []
    for key, group in buckets.items():
        votes = len({(g.engine, g.variant) for g in group})
        avg = sum(g.confidence for g in group) / len(group)
        merged.append((key, avg + min(votes - 1, 4) * 6.0, votes))
    merged.sort(key=lambda t: -t[1])
    return merged


def read_markings(image_bytes: bytes, multi_chip: bool = False,
                  engines: list[str] | None = None) -> OcrResult:
    """Entry point. Returns ranked candidate markings for database lookup."""
    result = OcrResult()
    if not HAS_CV:
        result.warnings.append("OpenCV/numpy not installed - server OCR unavailable. "
                               "Use on-device ML Kit, or install the 'vision' extra.")
        return result

    buf = np.frombuffer(image_bytes, dtype=np.uint8)
    img = cv2.imdecode(buf, cv2.IMREAD_COLOR)
    if img is None:
        result.warnings.append("Image could not be decoded")
        return result

    # Upscale small crops - OCR accuracy collapses below ~20px glyph height.
    h, w = img.shape[:2]
    if max(h, w) < 900:
        scale = 900 / max(h, w)
        img = cv2.resize(img, None, fx=scale, fy=scale, interpolation=cv2.INTER_CUBIC)

    active = [e for e in ENGINES
              if e.available() and (engines is None or e.name in engines)]
    if not active:
        result.warnings.append("No OCR engine installed (need easyocr or pytesseract)")
        return result
    result.engines_used = [e.name for e in active]

    full = (0, 0, img.shape[1], img.shape[0])
    regions = detect_chip_regions(img) if multi_chip else [full]
    regions = regions or [full]
    if multi_chip and len(regions) > 1:
        result.warnings.append(f"{len(regions)} chip package(s) detected - each read separately")

    all_lines: list[TextLine] = []
    for (x, y, rw, rh) in regions:
        crop = img[y:y + rh, x:x + rw]
        lines = _read_region(crop, active, result.warnings)
        all_lines.extend(lines)
        if len(regions) > 1:
            sub = OcrResult(engines_used=result.engines_used)
            _finalise(sub, lines)
            if sub.best:
                result.chips.append({"box": [int(x), int(y), int(rw), int(rh)],
                                     **summarize_for_api(sub)})

    _finalise(result, all_lines)

    # Two different part-number-shaped readings in one frame means more than
    # one package is in view. The country/lot lines can then not be
    # attributed to either part, so say so instead of silently merging them -
    # found by running a two-chip board image through the pipeline: the CHN
    # line from one chip was being applied to the other chip's verdict.
    # Only full-length part numbers count: 5-7 character lot codes such as
    # "GQ23J" also have the part-number shape.
    parts = [p_ for p_ in result.classification.get("part_number", []) if len(p_) >= 8]
    distinct = []
    for p_ in parts:
        if all(similarity_ratio(p_, d) < 0.8 for d in distinct):
            distinct.append(p_)
    result.multiple_parts = len(distinct) > 1 or len(result.chips) > 1
    if result.multiple_parts and not result.chips:
        result.warnings.append(
            f"{len(distinct)} different part numbers were read in one photo "
            f"({', '.join(distinct[:4])}). Photograph one component at a time, or "
            f"use multi-chip mode, so each marking is verified on its own.")
    return result


def similarity_ratio(a: str, b: str) -> float:
    """Cheap 0-1 similarity for de-duplicating near-identical OCR readings."""
    from difflib import SequenceMatcher
    return SequenceMatcher(None, a, b).ratio()


def _run_engines(img: "np.ndarray", active: list[_Engine], warnings: list[str],
                 tag: str = "") -> list[TextLine]:
    out: list[TextLine] = []
    for vname, variant in _variants(img):
        for engine in active:
            try:
                for ln in engine.read(variant):
                    ln.variant = vname + tag
                    out.append(ln)
            except Exception as exc:            # one engine failing must not kill the read
                log.warning("OCR engine %s failed on %s: %s", engine.name, vname, exc)
                warnings.append(f"{engine.name} failed on '{vname}' variant")
    return out


def _has_part_number(lines: list[TextLine]) -> bool:
    return any(classify_marking(k) == "part_number" for k, _c, _v in merge_lines(lines))


def _read_region(crop: "np.ndarray", active: list[_Engine], warnings: list[str]) -> list[TextLine]:
    """Read one package. If nothing shaped like a part number comes back, the
    package is probably rotated beyond what Hough deskew handles (a chip shot
    sideways, or at 20-30 degrees) - retry at the common orientations and keep
    whichever orientation produced a part-number-shaped reading."""
    lines = _run_engines(crop, active, warnings)
    if _has_part_number(lines):
        return lines
    for angle in (90, 270, 180):
        rotated = _rotate(crop, angle)
        retry = _run_engines(rotated, active, warnings, tag=f"@rot{angle:.0f}")
        if _has_part_number(retry):
            warnings.append(f"marking read after rotating the image {angle:.0f} degrees")
            return retry
    return lines


def _rotate(img: "np.ndarray", angle: float) -> "np.ndarray":
    if angle in (90, 180, 270):
        code = {90: cv2.ROTATE_90_COUNTERCLOCKWISE, 180: cv2.ROTATE_180,
                270: cv2.ROTATE_90_CLOCKWISE}[int(angle)]
        return cv2.rotate(img, code)
    h, w = img.shape[:2]
    m = cv2.getRotationMatrix2D((w / 2, h / 2), angle, 1.0)
    cos, sin = abs(m[0, 0]), abs(m[0, 1])
    nw, nh = int(h * sin + w * cos), int(h * cos + w * sin)
    m[0, 2] += nw / 2 - w / 2
    m[1, 2] += nh / 2 - h / 2
    # Constant fill with the image's median tone: BORDER_REPLICATE smears the
    # edge pixels into long diagonal streaks that later stages read as lines.
    fill = float(np.median(img)) if img.ndim == 2 else tuple(
        float(v) for v in np.median(img.reshape(-1, img.shape[2]), axis=0))
    return cv2.warpAffine(img, m, (nw, nh), flags=cv2.INTER_CUBIC,
                          borderMode=cv2.BORDER_CONSTANT, borderValue=fill)


def _text_angle(img: "np.ndarray") -> float | None:
    """Skew of the marking lines, by projection-profile search.

    The etched glyphs are isolated with a white top-hat (thin bright strokes
    on a darker package), then the mask is rotated through -45..45 degrees;
    the angle at which the row-sum profile is most "peaky" (highest variance)
    is the one where the text lines are horizontal. Unlike Hough lines or
    blob rectangles this does not care about the package outline, PCB traces
    or image borders - only about where glyph pixels sit relative to each
    other. Returns the rotation to apply (degrees, CCW positive), or None
    when there is too little glyph signal to decide.
    """
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY) if img.ndim == 3 else img
    scale = 320 / max(gray.shape[:2])
    if scale < 1:
        gray = cv2.resize(gray, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
    k = max(7, min(gray.shape[:2]) // 10)
    tophat = cv2.morphologyEx(gray, cv2.MORPH_TOPHAT,
                              cv2.getStructuringElement(cv2.MORPH_RECT, (k, k)))
    _, mask = cv2.threshold(tophat, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    if cv2.countNonZero(mask) < mask.size * 0.005:
        return None
    h, w = mask.shape
    centre = (w / 2, h / 2)
    side = int((h * h + w * w) ** 0.5) + 2
    pad = cv2.copyMakeBorder(mask, (side - h) // 2, (side - h) // 2, (side - w) // 2,
                             (side - w) // 2, cv2.BORDER_CONSTANT, value=0)
    centre = (pad.shape[1] / 2, pad.shape[0] / 2)

    def score(angle: float) -> float:
        m = cv2.getRotationMatrix2D(centre, angle, 1.0)
        r = cv2.warpAffine(pad, m, (pad.shape[1], pad.shape[0]), flags=cv2.INTER_NEAREST)
        return float(np.var(r.sum(axis=1, dtype=np.float64)))

    coarse = max(np.arange(-45, 46, 1.5), key=score)
    fine = max(np.arange(coarse - 1.5, coarse + 1.51, 0.25), key=score)
    return float(fine)


def _finalise(result: OcrResult, all_lines: list[TextLine]) -> None:
    result.lines = all_lines
    merged = merge_lines(all_lines)
    # Newline-joined: each entry is one physical line of the package marking,
    # and app/services/marking.py reads the marking line by line (part-number
    # line vs country/lot lines). Built from physical_lines(), not from the
    # merged keys: merged keys are normalised (spaces stripped), so "CHN 302"
    # became "CHN302" and the country-of-origin token was invisible to the
    # marking check.
    result.full_text = "\n".join(physical_lines(all_lines))

    ranked = sorted(merged, key=lambda m: -(score_candidate(m[0]) * 0.7 + m[1] * 0.3))
    result.candidates = [m[0] for m in ranked[:12]]

    buckets: dict[str, list[str]] = {}
    for key, _conf, _votes in merged:
        buckets.setdefault(classify_marking(key), []).append(key)
    result.classification = buckets

    if result.candidates:
        result.best = result.candidates[0]
        result.best_confidence = round(
            next(m[1] for m in merged if m[0] == result.best), 1)
        if not buckets.get("part_number"):
            result.warnings.append(
                "No marking matched the shape of a part number - the best candidate "
                "may be a lot or date code. Confirm by eye or enter it manually.")
    else:
        result.warnings.append("No legible text found. Try macro mode, more light "
                               "off-axis to kill glare, or manual entry.")


def summarize_for_api(r: OcrResult) -> dict[str, Any]:
    return {
        "best": r.best,
        "best_confidence": r.best_confidence,
        "candidates": r.candidates,
        "full_text": r.full_text,
        "classification": r.classification,
        "engines_used": r.engines_used,
        "warnings": r.warnings,
        "line_count": len(r.lines),
        "multiple_parts": r.multiple_parts,
        "chips": r.chips,
    }
