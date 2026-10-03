"""Marking-consistency analysis - the anti-remarking layer.

The matching cascade answers "which catalogue part is this marking?". It
trusts the printed part number by design, which is exactly what a remarked
("blacktopped") chip is built to exploit: a vendor sands off the original
surface and lasers a new number or a new country code.

This module asks a different question: "do the fields printed on this unit
agree with each other and with what the catalogue says?". It never looks up
the part again - it reads the *other* lines of the marking (country-of-origin
code, assembly-site code, wafer-fab code) and reports:

  * the unit's own physical origin marking (a unit marked CHN is Chinese-
    assembled whatever the catalogue says about the part number in general);
  * contradictions between fields (a China-only assembly-site code next to a
    non-China country code is a classic remark signature);
  * fields that are expected but missing.

It is deliberately dependency-free (no app/framework imports) so it can be
tested anywhere and ported verbatim to the Dart offline engine.

Every code in the tables below carries its source. Only add a code you can
cite - a guessed mapping here turns into a false accusation in the field.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field

# --------------------------------------------------------------------------- #
# Reference tables

# 3-letter country-of-origin codes printed on the package.
# Source: "Chinese Components FINAL.xlsx", sheet COMMON CHINESE, COO marking
# table (HQ TG EME source document).
COUNTRY_CODES: dict[str, str] = {
    "CHN": "China",
    "PHL": "Philippines",
    "SGP": "Singapore",
    "MYS": "Malaysia",
    "TWN": "Taiwan",
    "KOR": "Republic of Korea",
    "FRA": "France",
    "ITA": "Italy",
    "USA": "USA",
    "MLT": "Malta",
}
CHINA_CODES = {"CHN"}
CHINA_WORDS = ("MADE IN CHINA", "PRC")

# Manufacturer-scoped site codes. Only applied when the matched component's
# manufacturer matches, so a two-letter token on an unrelated chip can never
# trigger a finding.
#   kind = "assembly":  back-end assembly/test site. The country-of-origin
#                       code printed on the package should agree with it.
#   kind = "diffusion": front-end wafer fab. May legitimately differ from the
#                       assembly country, so it never produces a contradiction
#                       - but a China fab is still origin-relevant.
SITE_CODES: dict[str, dict[str, dict]] = {
    "STMICROELECTRONICS": {
        "GK": {"kind": "assembly", "country": "CHN", "site": "ST Shenzhen (China)",
               "source": "ST PCN EMBEDDED PROCESSING/26/16389 and /16018"},
        "Y5": {"kind": "diffusion", "country": "CHN", "site": "HHGrace WuXi Fab 7 (China)",
               "source": "ST PCN EMBEDDED PROCESSING/26/16388"},
        "2E": {"kind": "diffusion", "country": "CHN", "site": "HHGrace WuXi Fab 9 (China)",
               "source": "ST PCN EMBEDDED PROCESSING/26/16388"},
    },
}

# Manufacturers known to print a country-of-origin code on their packages.
PRINTS_COUNTRY_CODE = {"STMICROELECTRONICS"}

MANUFACTURER_ALIASES = {
    "STMICROELECTRONICS": "STMICROELECTRONICS",
    "ST MICROELECTRONICS": "STMICROELECTRONICS",
    "ST MICRO": "STMICROELECTRONICS",
    "ST": "STMICROELECTRONICS",
}

SEVERITY_RANK = {"info": 0, "yellow": 1, "red": 2}


# --------------------------------------------------------------------------- #
@dataclass
class MarkingFinding:
    code: str
    severity: str          # info | yellow | red
    message: str

    def as_dict(self) -> dict:
        return {"code": self.code, "severity": self.severity, "message": self.message}


@dataclass
class MarkingAnalysis:
    country_code: str | None = None
    country: str | None = None
    site_codes: list[str] = field(default_factory=list)
    findings: list[MarkingFinding] = field(default_factory=list)

    @property
    def worst(self) -> str:
        if not self.findings:
            return "info"
        return max((f.severity for f in self.findings), key=SEVERITY_RANK.__getitem__)


def canonical_manufacturer(name: str | None) -> str:
    n = re.sub(r"\s+", " ", (name or "").upper().replace(".", "")).strip()
    if n in MANUFACTURER_ALIASES:
        return MANUFACTURER_ALIASES[n]
    for alias, canon in MANUFACTURER_ALIASES.items():
        if len(alias) > 2 and alias in n:
            return canon
    return n


def _tokens(line: str) -> list[str]:
    return [t for t in re.split(r"[^A-Z0-9]+", line.upper()) if t]


def _norm(s: str) -> str:
    return re.sub(r"[^A-Z0-9]", "", s.upper())


def analyse(marking_text: str, *, manufacturer: str | None = None,
            part_key: str | None = None, catalogue_is_chinese: str | None = None) -> MarkingAnalysis:
    """Analyse the full marking text read off one package.

    marking_text          every line read from the chip (OCR text, or what an
                          inspector typed), newline-separated.
    manufacturer          manufacturer of the catalogue match, if any - scopes
                          which site-code table applies.
    part_key              normalised part number that was matched - the line
                          containing it is excluded from country/site parsing,
                          because a part number can contain letter runs that
                          look like codes.
    catalogue_is_chinese  YES / NO / UNKNOWN from the matched record.
    """
    out = MarkingAnalysis()
    raw_lines = [l for l in re.split(r"[\r\n|]+", marking_text or "") if l.strip()]
    pk = _norm(part_key or "")
    # Manufacturers often abbreviate the part line (ST prints "32G491KCU6", not
    # "STM32G491KCU6"), so match on either end of the key, not just its prefix.
    probes = {pk[:6], pk[-6:]} if len(pk) >= 6 else ({pk} if pk else set())
    # Drop the part-number *tokens*, not whole lines: OCR or a typed entry may
    # put the whole marking on one line ("32G491KCU6 GQ 21U 9R CHN 30 2B1"),
    # and the country code must still be found there.
    def _without_part(line: str) -> str:
        return " ".join(t for t in _tokens(line) if not any(p and p in t for p in probes))
    lines = [l for l in (_without_part(r) for r in raw_lines) if l]
    manu = canonical_manufacturer(manufacturer)
    site_table = SITE_CODES.get(manu, {})
    upper_text = " ".join(raw_lines).upper()

    # --- country of origin ------------------------------------------------- #
    for line in lines:
        for tok in _tokens(line):
            if tok in COUNTRY_CODES and out.country_code is None:
                out.country_code, out.country = tok, COUNTRY_CODES[tok]
    if out.country_code is None and any(w in upper_text for w in CHINA_WORDS):
        out.country_code, out.country = "CHN", "China"

    # --- site codes (manufacturer-scoped, whole tokens only) -------------- #
    for line in lines:
        for tok in _tokens(line):
            if tok in site_table and tok not in out.site_codes:
                out.site_codes.append(tok)

    # --- findings ---------------------------------------------------------- #
    cat = (catalogue_is_chinese or "UNKNOWN").upper()
    if out.country_code in CHINA_CODES:
        if cat == "NO":
            out.findings.append(MarkingFinding(
                "unit_marked_china_catalogue_non_chinese", "red",
                "This unit is marked CHN (China) although the catalogue lists this part "
                "as non-Chinese. The marking on the unit itself governs: treat as Chinese "
                "and update the catalogue if this source is supplied this way."))
        else:
            out.findings.append(MarkingFinding(
                "unit_marked_china", "red",
                "Country-of-origin code on the package reads CHN (China)."))
    elif out.country_code and cat == "YES":
        out.findings.append(MarkingFinding(
            "country_code_disagrees_with_catalogue", "yellow",
            f"Package is marked {out.country_code} ({out.country}) but this part has been "
            "recorded as Chinese-origin. Either a different assembly site or a remarked "
            "package - the catalogue verdict is kept; verify with the manufacturer."))

    for code in out.site_codes:
        info = site_table[code]
        if info["kind"] == "assembly":
            if out.country_code and out.country_code != info["country"]:
                china_involved = "CHN" in (out.country_code, info["country"])
                out.findings.append(MarkingFinding(
                    "site_code_contradicts_country_code", "red" if china_involved else "yellow",
                    f"Assembly-site code {code} = {info['site']}, but the package country "
                    f"code is {out.country_code}. These cannot both be original - "
                    f"possible remarked package. (Code source: {info['source']})"))
            elif out.country_code is None and info["country"] in CHINA_CODES:
                out.findings.append(MarkingFinding(
                    "china_assembly_site_code", "red",
                    f"Assembly-site code {code} = {info['site']}, but no country code was "
                    f"read. (Code source: {info['source']})"))
        elif info["kind"] == "diffusion" and info["country"] in CHINA_CODES:
            out.findings.append(MarkingFinding(
                "china_wafer_fab_code", "yellow",
                f"Wafer-fab code {code} = {info['site']}. The die was fabricated in China even "
                "if assembled elsewhere - origin policy decision required. "
                f"(Code source: {info['source']})"))

    if (out.country_code is None and manu in PRINTS_COUNTRY_CODE and len(raw_lines) >= 3):
        out.findings.append(MarkingFinding(
            "country_code_missing", "yellow",
            "This manufacturer normally prints a country-of-origin code, but none was read "
            "from an otherwise complete marking. Either the photo/OCR missed it or it has "
            "been removed - inspect the package surface."))
    return out


# --------------------------------------------------------------------------- #
RED_FROM_MARKING = {
    "result": "chinese", "banner": "RED", "headline": "CHINESE ORIGIN MARKED ON PACKAGE",
    "alert": True, "vibrate": True, "sound": "warning",
}


def apply_to_verdict(verdict: dict, analysis: MarkingAnalysis) -> dict:
    """Tighten (never relax) a catalogue verdict using the marking analysis.

    * any red finding     -> RED, regardless of the catalogue
    * any yellow finding  -> a GREEN verdict becomes YELLOW; RED stays RED
    * info / no findings  -> unchanged
    A marking check can only make a verdict stricter. Absence of a suspicious
    marking is never evidence that a part is clean.
    """
    if verdict.get("result") == "not_found":
        return verdict                      # nothing to compare against
    from app.services.matching import policy_decision  # local: keep module dependency-free at import
    worst = analysis.worst
    v = dict(verdict)
    if worst == "red" and v.get("result") != "chinese":
        keep = {k: v[k] for k in ("criticality", "criticality_policy", "confidence") if k in v}
        v = {**RED_FROM_MARKING, **keep,
             "action": "Marking evidence overrides the catalogue - quarantine the part"}
        if keep.get("criticality") == "CRITICAL":
            v["escalate"] = True
            v["escalation_note"] = "Chinese-origin marking on a CRITICAL subsystem part"
    elif worst == "yellow" and v.get("result") == "non_chinese":
        v.update(result="unknown_origin", banner="YELLOW", headline="MARKING INCONSISTENT",
                 action="Package marking raises an origin question - verify before fitting",
                 alert=False)
    if worst in ("red", "yellow"):
        red = [f.message for f in analysis.findings if f.severity == worst]
        v["origin_evidence"] = "unit_marking" if worst == "red" else v.get("origin_evidence", "none")
        v["evidence_detail"] = " ".join(red[:2]) or v.get("evidence_detail", "")
        v["review_required"] = True
        v["policy_decision"] = policy_decision(v["result"], v.get("criticality", ""),
                                               v.get("criticality_policy", ""))
    return v