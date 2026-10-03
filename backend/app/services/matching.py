"""Text normalisation, OCR error correction and the component matching engine.

The matching cascade, cheapest first:

  1. exact       - raw string equals a stored barcode / QR payload / part number
  2. normalized  - A-Z0-9 form equals the stored search_key            (index hit)
  3. corrected   - normalized form after OCR confusion-set repair      (index hit)
  4. prefix      - stored key is a prefix of the read, or vice versa   (index hit)
  5. fuzzy       - Damerau-Levenshtein + token ratio over a candidate set

Every layer returns a 0-100 score. Anything below settings.fuzzy_threshold is
returned as a *suggestion* rather than a match, so the inspector confirms it
rather than the app asserting it.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from functools import lru_cache

from app.core.config import settings

# --------------------------------------------------------------------------- #
# Normalisation
# --------------------------------------------------------------------------- #
_NON_ALNUM = re.compile(r"[^A-Z0-9]")
_NOISE_PREFIXES = ("DCOV:", "URN:DCOV:", "HTTP://", "HTTPS://")

# Glyphs an OCR engine confuses on laser-etched, low-contrast IC packages.
# Applied *both* ways when generating candidate spellings.
CONFUSIONS: dict[str, str] = {
    "O": "0", "Q": "0", "D": "0", "I": "1", "L": "1", "|": "1", "T": "7",
    "Z": "2", "S": "5", "B": "8", "G": "6", "U": "V", "C": "G", "E": "F",
}
REVERSE_CONFUSIONS = {v: k for k, v in CONFUSIONS.items()}


def normalize(value: str | None) -> str:
    """'stm32 f302-c8t6 ' -> 'STM32F302C8T6'. Idempotent."""
    if not value:
        return ""
    v = value.strip().upper()
    for p in _NOISE_PREFIXES:
        if v.startswith(p):
            v = v[len(p):]
    return _NON_ALNUM.sub("", v)


def normalize_manufacturer(name: str | None, aliases: dict[str, str] | None = None) -> str:
    """Canonical manufacturer key: uppercased, punctuation and legal-entity
    suffixes stripped, then resolved through an alias table so 'ST Micro',
    'STMicro' and 'ST Microelectronics Inc.' all collapse to one identity.

    `aliases` defaults to DEFAULT_MANUFACTURER_ALIASES (below) rather than an
    empty table, so every call site gets alias resolution for free unless it
    deliberately opts out. This table is embedded in code rather than loaded
    from data/source/policy.json at runtime: that file lives outside `app/`
    and is not copied into the Docker image (see deploy/Dockerfile.backend),
    so a path-based load would work in dev and silently no-op in production -
    worse than not having the feature at all.
    """
    if not name:
        return ""
    key = re.sub(r"\s+", " ", re.sub(r"[.,]", "", name.strip())).upper()
    key = re.sub(r"\b(INC|LTD|LIMITED|PVT|CORP|CORPORATION|GMBH|CO|LLC|SA|BV|AG)\b", "", key).strip()
    key = re.sub(r"\s+", " ", key)
    table = DEFAULT_MANUFACTURER_ALIASES if aliases is None else aliases
    return table.get(key, key)


# Kept in sync by hand with data/source/policy.json's manufacturer_aliases -
# that file is the ETL's source of truth for the seed data; this constant is
# what the running application actually uses. If you add an alias to one,
# add it to the other.
DEFAULT_MANUFACTURER_ALIASES: dict[str, str] = {
    "ST MICROELECTRONICS": "STMICROELECTRONICS",
    "ST MICRO": "STMICROELECTRONICS",
    "STMICRO": "STMICROELECTRONICS",
    "ANALOG DEVICES INC": "ANALOG DEVICES",
    "ADI": "ANALOG DEVICES",
    "TI": "TEXAS INSTRUMENTS",
    "NVIDIA CORPORATION": "NVIDIA",
    "REALTEK SEMICONDUCTOR": "REALTEK",
    "MACRONIX (MXIC)": "MACRONIX",
    "WESTERN DIGITAL": "SANDISK",
    "HOBBYWING": "HOBBY WING",
    "MEDIATEK INC": "MEDIATEK",
    "SHENZHEN STCOMM": "STCOMM",
}


# --------------------------------------------------------------------------- #
# Distributor / manufacturer reel-label barcodes
# --------------------------------------------------------------------------- #
# Component reels, trays and bags carry labels encoded with ANSI MH10.8.2 data
# identifiers (the ECIA EIGP-114 2D label, and many 1D Code128 labels): a
# DataMatrix/PDF417 payload "[)>RS06GS1PSTM32F302C8T6GS1TGQ23J...RS EOT", or a
# single Code128 field "1PSTM32F302C8T6". The field we can look up is 1P, the
# manufacturer part number. 4L is the country of origin *declared on the
# label*: it is reported to the inspector but never decides a verdict on its
# own - packaging is not proof of where the die inside was made.
_DI_FIELDS = (("30P", "alt_part"), ("1P", "mpn"), ("4L", "label_coo"), ("1T", "lot"),
              ("10D", "date_code"), ("9D", "date_code"), ("1K", "order"), ("Q", "qty"),
              ("P", "customer_part"), ("K", "po"))
_SEP = re.compile(r"[\x1d\x1e\x04]")


def parse_label_barcode(raw: str, allow_single_field: bool = False) -> dict[str, str]:
    """Extract data-identifier fields from a reel/bag label payload.

    Returns {} when the payload is not a recognisable label. A bare single
    field ("1PSTM32...") is only parsed when allow_single_field is set, because
    a real part number could itself begin with those characters - the matcher
    only tries that after a direct lookup of the raw value failed.
    """
    s = (raw or "").strip()
    structured = s.startswith("[)>") or bool(_SEP.search(s))
    if not structured and not allow_single_field:
        return {}
    if s.startswith("[)>"):
        s = s[3:]
    parts = [p.strip() for p in _SEP.split(s) if p.strip()]
    if not structured:
        parts = [s]
    out: dict[str, str] = {}
    for p in parts:
        if re.fullmatch(r"\d{2}", p):          # format header, e.g. "06"
            continue
        for di, name in _DI_FIELDS:
            if p.upper().startswith(di) and len(p) > len(di):
                out.setdefault(name, p[len(di):].strip())
                break
    if "mpn" not in out:
        return {}
    return out


def ocr_variants(text: str, max_variants: int = 64) -> list[str]:
    """Generate plausible re-readings by flipping one confusable glyph at a time."""
    base = normalize(text)
    out = [base]
    for i, ch in enumerate(base):
        for table in (CONFUSIONS, REVERSE_CONFUSIONS):
            if ch in table:
                cand = base[:i] + table[ch] + base[i + 1:]
                if cand not in out:
                    out.append(cand)
                    if len(out) >= max_variants:
                        return out
    return out


# Conservative one-way fold used to build a second index key. Every glyph in a
# confusion class collapses to one representative, so a marking misread in
# several places at once still lands on the right bucket. Deliberately excludes
# aggressive pairs (D/0, C/G, U/V, E/F) that would collide distinct part families.
FOLD_MAP = str.maketrans({"O": "0", "Q": "0", "I": "1", "L": "1",
                          "S": "5", "B": "8", "Z": "2", "G": "6", "T": "7"})


def fold_key(value: str) -> str:
    """Canonical glyph-class form. 'ADIN13OOBCPZ' and 'ADIN1300BCPZ' both fold to
    'AD1N13008CP2', so a double misread still resolves."""
    return normalize(value).translate(FOLD_MAP)


def truncations(key: str, floor: int = 6) -> list[str]:
    """Progressively shorter leading substrings - handles a lot/date code that
    OCR ran together with the part number ('STM32G4A1KCU6GQ23J1B9U')."""
    return [key[:i] for i in range(len(key) - 1, floor - 1, -1)]


# --------------------------------------------------------------------------- #
# Distance metrics (pure Python - no native deps, so it runs identically on the
# server and inside the Flutter client's Dart port).
# --------------------------------------------------------------------------- #
def damerau_levenshtein(a: str, b: str, cap: int | None = None) -> int:
    if a == b:
        return 0
    if not a:
        return len(b)
    if not b:
        return len(a)
    if cap is not None and abs(len(a) - len(b)) > cap:
        return cap + 1

    prev2: list[int] = []
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i] + [0] * len(b)
        best = cur[0]
        for j, cb in enumerate(b, 1):
            cost = 0 if ca == cb else 1
            val = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            if i > 1 and j > 1 and ca == b[j - 2] and a[i - 2] == cb:
                val = min(val, prev2[j - 2] + cost)
            cur[j] = val
            best = min(best, val)
        if cap is not None and best > cap:
            return cap + 1
        prev2, prev = prev, cur
    return prev[-1]


def similarity(a: str, b: str) -> float:
    """0-100 similarity, biased toward matching leading characters.

    Part numbers carry family information in their prefix (STM32F4 vs STM32G0),
    so a mismatch at position 3 matters far more than one at position 12.
    """
    if not a or not b:
        return 0.0
    if a == b:
        return 100.0
    dist = damerau_levenshtein(a, b)
    base = (1 - dist / max(len(a), len(b))) * 100
    prefix = 0
    for ca, cb in zip(a, b):
        if ca != cb:
            break
        prefix += 1
    prefix_ratio = prefix / max(len(a), len(b))
    return round(base * 0.75 + prefix_ratio * 100 * 0.25, 2)


# --------------------------------------------------------------------------- #
@dataclass(slots=True)
class Candidate:
    component_id: str
    score: float
    method: str
    payload: dict = field(default_factory=dict)


@dataclass(slots=True)
class MatchResult:
    matched: bool
    method: str = "none"
    score: float = 0.0
    component: dict | None = None
    suggestions: list[Candidate] = field(default_factory=list)
    normalized_input: str = ""
    notes: list[str] = field(default_factory=list)


class Matcher:
    """Stateless over an injected index; safe to share across requests."""

    def __init__(self, threshold: int | None = None):
        self.threshold = threshold or settings.fuzzy_threshold

    # -- layers ------------------------------------------------------------- #
    def match(self, raw: str, index: "ComponentIndex") -> MatchResult:
        raw = (raw or "").strip()
        key = normalize(raw)
        notes: list[str] = []
        if not key:
            return MatchResult(False, normalized_input="", notes=["empty input"])

        # 1. exact on barcode / QR payload
        hit = index.by_barcode(raw) or index.by_qr(raw)
        if hit:
            return MatchResult(True, "exact_code", 100.0, hit, normalized_input=key)

        # 1b. structured reel/bag label: look up the manufacturer part number
        label = parse_label_barcode(raw)
        if label:
            return self._from_label(label, index, notes)

        # 2. normalized key
        hits = index.by_key(key)
        if hits:
            return self._resolve(hits, key, "normalized", 100.0, notes)

        # 2a. single-field Code128 label ("1PSTM32F302C8T6"), only once the raw
        #     value itself is known not to be a catalogue part number
        label = parse_label_barcode(raw, allow_single_field=True)
        if label and index.by_key(normalize(label["mpn"])):
            return self._from_label(label, index, notes)

        # 2b. lot/date code read together with the part number
        for trunc in truncations(key):
            hits = index.by_key(trunc)
            if hits:
                notes.append(f"trailing lot/date code discarded: {key} -> {trunc}")
                return self._resolve(hits, trunc, "lot_code_stripped", 96.0, notes)

        # 3a. single-glyph OCR confusion repair
        for variant in ocr_variants(key)[1:]:
            hits = index.by_key(variant)
            if hits:
                notes.append(f"OCR correction applied: {key} -> {variant}")
                return self._resolve(hits, variant, "ocr_corrected", 94.0, notes)

        # 3b. multi-glyph repair via the folded glyph-class key
        folded = fold_key(key)
        hits = index.by_fold(folded)
        if hits:
            notes.append(f"resolved through glyph-class folding ({key} ~ {folded}) - "
                         f"verify the marking by eye before accepting")
            return self._resolve(hits, key, "ocr_folded", 90.0, notes)
        for trunc in truncations(folded):
            hits = index.by_fold(trunc)
            if hits:
                notes.append(f"glyph-class folding after discarding a trailing code ({key})")
                return self._resolve(hits, key, "ocr_folded_stripped", 87.0, notes)

        # 4. prefix containment (partially readable marking). Prefer the most
        #    specific stored key, i.e. the longest one consistent with the read.
        if len(key) >= 5:
            pref = index.by_prefix(key)
            if pref:
                longest = max(len(p["search_key"]) for p in pref)
                best = [p for p in pref if len(p["search_key"]) == longest]
                notes.append("matched on partial marking (prefix)")
                if len({p["search_key"] for p in best}) == 1:
                    return self._resolve(best, key, "prefix", 88.0, notes)
                notes[-1] = f"{len(best)} distinct part numbers share this prefix - confirm manually"
                return MatchResult(
                    False, "ambiguous_prefix", 0.0, None,
                    [Candidate(c["component_id"], 85.0, "prefix", c) for c in best[:10]],
                    key, notes)

        # 5. fuzzy over a blocked candidate set
        cands = self._fuzzy(key, index)
        if cands and cands[0].score >= self.threshold:
            best = cands[0]
            if len(cands) > 1 and cands[1].score >= best.score - 2:
                notes.append("two near-equal fuzzy candidates - inspector confirmation required")
                return MatchResult(False, "ambiguous_fuzzy", best.score, None, cands[:5], key, notes)
            return MatchResult(True, "fuzzy", best.score, best.payload, cands[1:5], key, notes)

        return MatchResult(False, "none", cands[0].score if cands else 0.0, None,
                           cands[:5], key, notes)

    def _from_label(self, label: dict[str, str], index: "ComponentIndex",
                    notes: list[str]) -> MatchResult:
        mpn = label["mpn"]
        notes.append(f"reel/bag label barcode: manufacturer part number (1P) = {mpn}")
        if label.get("label_coo"):
            notes.append(f"label declares country of origin (4L) = {label['label_coo']} - "
                         f"packaging claim only, not used to decide the verdict")
        if label.get("lot") or label.get("date_code"):
            notes.append("label lot/date: " + " / ".join(
                v for v in (label.get("lot"), label.get("date_code")) if v))
        # The part number then goes through the normal cascade (exact first),
        # so a misprinted or truncated label is still handled conservatively.
        inner = self.match(mpn, index)
        inner.notes = notes + inner.notes
        if inner.method in ("normalized",):
            inner.method = "label_mpn"
        return inner

    def _resolve(self, hits: list[dict], key: str, method: str, score: float,
                 notes: list[str]) -> MatchResult:
        """Several rows can share a part number (different vendors / assemblies).

        Policy: if they agree on origin, return the highest-confidence row. If
        they disagree, refuse to guess and surface all of them - a Chinese and a
        non-Chinese row for the same marking is exactly the case an inspector
        must adjudicate by hand.
        """
        hits = list({h["component_id"]: h for h in hits}.values())
        if len(hits) == 1:
            return MatchResult(True, method, score, hits[0], normalized_input=key, notes=notes)

        # A row whose origin was never established carries no evidence, so it
        # cannot contradict a row that has one. Collapse those out first.
        definite = [h for h in hits if (h.get("is_chinese") or "UNKNOWN").upper() != "UNKNOWN"]
        if definite and len(definite) < len(hits):
            notes.append(f"{len(hits) - len(definite)} record(s) with unestablished origin "
                         f"superseded by verified record(s)")
            hits = definite

        verdicts = {(h.get("is_chinese") or "UNKNOWN").upper() for h in hits}
        if len(verdicts) == 1:
            best = max(hits, key=lambda h: float(h.get("confidence_score") or 0))
            notes.append(f"{len(hits)} records share this marking; all agree on origin")
            return MatchResult(True, method, score, best,
                               [Candidate(h["component_id"], score, method, h) for h in hits[1:]],
                               key, notes)
        notes.append(f"CONFLICT: {len(hits)} records share this marking with differing origin "
                     f"verdicts ({', '.join(sorted(verdicts))}). Manual adjudication required.")
        return MatchResult(False, "conflict", score, None,
                           [Candidate(h["component_id"], score, method, h) for h in hits],
                           key, notes)

    def _fuzzy(self, key: str, index: "ComponentIndex") -> list[Candidate]:
        out: list[Candidate] = []
        for comp in index.candidates(key, limit=settings.fuzzy_candidate_limit * 8):
            ck = comp.get("search_key") or normalize(comp.get("chip_number") or comp.get("part_number"))
            if not ck:
                continue
            s = similarity(key, ck)
            if s >= 55:
                out.append(Candidate(comp["component_id"], s, "fuzzy", comp))
        out.sort(key=lambda c: -c.score)
        return out[:settings.fuzzy_candidate_limit]


# --------------------------------------------------------------------------- #
class ComponentIndex:
    """In-memory index. Built once at startup and refreshed on import commit.

    203 seed rows fit trivially; at the 1M-row target the same interface is
    backed by the SQL indexes instead (see SqlComponentIndex in repository.py),
    with the n-gram block below replaced by a trigram GIN / FTS5 query.
    """

    def __init__(self, components: list[dict]):
        self.rows = components
        self._by_key: dict[str, list[dict]] = {}
        self._by_barcode: dict[str, dict] = {}
        self._by_qr: dict[str, dict] = {}
        self._by_fold: dict[str, list[dict]] = {}
        self._blocks: dict[str, set[int]] = {}
        for i, c in enumerate(components):
            key = c.get("search_key") or normalize(c.get("chip_number") or c.get("part_number"))
            c["search_key"] = key
            if key:
                self._by_key.setdefault(key, []).append(c)
                self._by_fold.setdefault(key.translate(FOLD_MAP), []).append(c)
                for gram in self._grams(key):
                    self._blocks.setdefault(gram, set()).add(i)
            if c.get("barcode"):
                self._by_barcode[c["barcode"].strip().upper()] = c
            if c.get("qr_code"):
                self._by_qr[c["qr_code"].strip().upper()] = c

    @staticmethod
    def _grams(key: str, n: int = 3) -> set[str]:
        return {key[i:i + n] for i in range(max(1, len(key) - n + 1))}

    def by_key(self, key: str) -> list[dict]:
        return self._by_key.get(key, [])

    def by_fold(self, folded: str) -> list[dict]:
        return self._by_fold.get(folded, [])

    def by_barcode(self, raw: str) -> dict | None:
        return self._by_barcode.get(raw.strip().upper())

    def by_qr(self, raw: str) -> dict | None:
        return self._by_qr.get(raw.strip().upper())

    def by_prefix(self, key: str) -> list[dict]:
        out = []
        for k, rows in self._by_key.items():
            if k.startswith(key) or key.startswith(k):
                out.extend(rows)
        return out

    def candidates(self, key: str, limit: int = 200) -> list[dict]:
        """Trigram blocking - only score rows sharing at least one 3-gram."""
        counts: dict[int, int] = {}
        for gram in self._grams(key):
            for idx in self._blocks.get(gram, ()):
                counts[idx] = counts.get(idx, 0) + 1
        ranked = sorted(counts.items(), key=lambda kv: -kv[1])[:limit]
        return [self.rows[i] for i, _ in ranked]


@lru_cache(maxsize=1)
def _empty_index() -> ComponentIndex:
    return ComponentIndex([])


# --------------------------------------------------------------------------- #
# Verdict
# --------------------------------------------------------------------------- #
CHINESE_TOKENS = ("CHINA", "PRC", "HONG KONG", "MACAU", "SHENZHEN", "CHN", "CN")


# Match methods that identify a component *probably* rather than exactly. A
# verdict reached through one of these must never be presented as a clean
# pass: the inspector confirms the marking by eye first.
UNCERTAIN_METHODS = frozenset({"fuzzy", "prefix", "ocr_folded", "ocr_folded_stripped"})

# Catalogue sources that record only the country of the manufacturer/OEM's
# headquarters, not where this component was made. A brand's home country is
# not evidence of a component's origin (see ORIGIN_VERIFICATION_LOGIC.md).
MANUFACTURER_LEVEL_SOURCES = ("OEM LANDSCAPE",)
MANUFACTURER_LEVEL_CATEGORIES = ("OEM / LRU",)


def origin_evidence(component: dict | None) -> tuple[str, str]:
    """Classify what the catalogue's origin claim for this record rests on.

    Returns (tier, human-readable detail). Tiers, strongest first:
      component     - origin documented for this component (teardown,
                      identification worksheet, watchlist, curated import)
      manufacturer  - only the OEM/manufacturer's home country is recorded
      none          - no origin established
    ('unit_marking' - the package's own COO code - is assigned by
    app/services/marking.py, which outranks all of these.)
    """
    if not component:
        return "none", ""
    src = (component.get("verification_source") or "").strip()
    country = (component.get("country_of_origin") or "").strip()
    is_cn = (component.get("is_chinese") or "UNKNOWN").upper()
    by = (component.get("verified_by") or "").strip()
    if is_cn not in ("YES", "NO") or not country or country.upper() == "UNKNOWN":
        return "none", "The catalogue record has no documented country of origin."
    cat = (component.get("category") or "").strip().upper()
    if cat in MANUFACTURER_LEVEL_CATEGORIES or any(t in src.upper() for t in MANUFACTURER_LEVEL_SOURCES):
        return "manufacturer", (f"Manufacturer/OEM home country only ({country}); source: "
                                f"{src or 'not recorded'}. This is not the component's "
                                f"documented place of manufacture.")
    return "component", (f"Catalogue record: {country}; source: {src or 'not recorded'}"
                         + (f"; verified by {by}" if by else "") + ".")


def policy_decision(result: str, criticality: str, criticality_policy: str = "") -> str:
    """The configured policy's decision, as text for the result screen. Comes
    from the record's criticality/criticality_policy (data/source/policy.json
    via the catalogue) - nothing here is decided independently of that."""
    crit = (criticality or "").upper()
    pol = (criticality_policy or "").strip()
    if result == "chinese":
        if crit == "CRITICAL":
            return "NOT ACCEPTABLE" + (f" - {pol}" if pol else " in a CRITICAL subsystem")
        if crit == "NON-CRITICAL":
            return "PERMITTED BY POLICY" + (f" - {pol}" if pol else "") + \
                " (Chinese origin recorded; non-critical subsystem)"
        return "REFER TO INSPECTING AUTHORITY - subsystem not classified in the policy matrix"
    if result == "non_chinese":
        return "ACCEPTABLE - no Chinese-origin evidence for this marking"
    if result == "unknown_origin":
        return "REQUIRES MANUAL REVIEW - origin or identity not established"
    return "NOT IN CATALOGUE - REQUIRES MANUAL REVIEW"


def verdict_for(component: dict | None, score: float = 100.0,
                method: str | None = None) -> dict:
    """Map a matched component onto one of the four banner states.

    `method` is the match method that found the component. It is optional
    only for backward compatibility; callers that know it must pass it, since
    an uncertain match (see UNCERTAIN_METHODS) may not produce a GREEN.
    """
    if component is None:
        return {"result": "not_found", "banner": "GREY",
                "headline": "COMPONENT NOT FOUND",
                "action": "Capture images and save for review",
                "origin_evidence": "none", "evidence_detail": "",
                "review_required": True,
                "policy_decision": policy_decision("not_found", "")}

    is_cn = (component.get("is_chinese") or "UNKNOWN").upper()
    origin = (component.get("country_of_origin") or "").strip()
    if origin.upper() in ("UNKNOWN", "UNK", "N/A", "NA", "-", "?", "TBD", "NONE"):
        origin = ""   # an explicit "Unknown" is not an origin
    crit = (component.get("criticality") or "REVIEW").upper()
    conf = float(component.get("confidence_score") or 0)
    effective = min(conf, score)
    tier, detail = origin_evidence(component)
    uncertain = (method or "") in UNCERTAIN_METHODS

    if is_cn == "YES":
        res = {"result": "chinese", "banner": "RED",
               "headline": "CHINESE COMPONENT DETECTED",
               "alert": True, "vibrate": True, "sound": "warning"}
    elif is_cn == "NO" and origin:
        res = {"result": "non_chinese", "banner": "GREEN",
               "headline": "NON-CHINESE COMPONENT", "alert": False}
    else:
        res = {"result": "unknown_origin", "banner": "YELLOW",
               "headline": "ORIGIN NOT FOUND",
               "action": "Needs verification - refer to database manager", "alert": False}

    # A low-confidence match must not be presented as a clean pass.
    if effective < settings.low_confidence_floor and res["result"] == "non_chinese":
        res = {"result": "unknown_origin", "banner": "YELLOW",
               "headline": "ORIGIN NOT CONFIRMED",
               "action": f"Match confidence {effective:.0f}% is below the "
                         f"{settings.low_confidence_floor}% floor - verify manually",
               "alert": False}

    # Brand/OEM home country is not component origin: never a GREEN on that alone.
    if res["result"] == "non_chinese" and tier == "manufacturer":
        res = {"result": "unknown_origin", "banner": "YELLOW",
               "headline": "OEM NON-CHINESE - COMPONENT ORIGIN NOT DOCUMENTED",
               "action": "Only the manufacturer's home country is on record. Confirm the "
                         "component's country of manufacture (package COO marking, "
                         "datasheet or supplier certificate of conformance).",
               "alert": False}

    # An approximate identification is never a clean pass, and a RED reached
    # through one says so rather than asserting a definite identity.
    if uncertain and res["result"] == "non_chinese":
        res = {"result": "unknown_origin", "banner": "YELLOW",
               "headline": "IDENTITY UNCERTAIN - REQUIRES MANUAL REVIEW",
               "action": f"Matched by '{method}' at {score:.0f}%. Compare the marking on "
                         f"the part with the catalogue record before accepting.",
               "alert": False}
    if res["result"] == "chinese" and tier == "manufacturer":
        # Kept RED - the conservative direction - but labelled for what it is.
        res["headline"] = "CHINESE MANUFACTURER - COMPONENT ORIGIN PRESUMED CHINESE"
        res["action"] = ("The catalogue records a Chinese manufacturer/OEM, not this unit's "
                         "place of manufacture. Treat as Chinese-origin unless documented "
                         "otherwise.")

    if uncertain and res["result"] == "chinese":
        res["headline"] = "PROBABLE CHINESE COMPONENT - CONFIRM MARKING"
        res["action"] = (f"Matched by '{method}' at {score:.0f}%. Treat as Chinese-origin "
                         f"until the marking is confirmed by eye.")

    res["criticality"] = crit
    res["criticality_policy"] = component.get("criticality_policy") or ""
    res["confidence"] = round(effective, 1)
    res["origin_evidence"] = tier
    res["evidence_detail"] = detail
    res["review_required"] = uncertain or res["result"] != "non_chinese"
    res["policy_decision"] = policy_decision(res["result"], crit, res["criticality_policy"])
    if res["result"] == "chinese" and crit == "CRITICAL":
        res["escalate"] = True
        res["escalation_note"] = (component.get("criticality_policy")
                                  or "Chinese origin not acceptable in this subsystem")
    return res
