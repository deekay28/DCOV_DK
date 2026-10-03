# DCOV — Origin Verification Logic

How DCOV decides identity, origin and verdict. Implemented identically in
`backend/app/services/matching.py` + `marking.py` (server),
`frontend_flutter/lib/services/matching.dart` + `marking.dart` (offline app)
and `web_demo/dcov-match.js` (demo). Python↔JS parity is enforced by
`backend/tests/test_engine_parity.py`; Dart by `test/matching_test.dart`.

**Principle:** DCOV reports what documented evidence says. It never infers
origin from language, brand name, seller, packaging, appearance or barcode
prefix. When evidence is insufficient the answer is *REQUIRES MANUAL REVIEW*,
never a guess.

## 1. Database fields used

| Field | Role |
|---|---|
| `chip_number`, `part_number` → `search_key` | identity (normalised A–Z0–9) |
| `barcode`, `qr_code` | exact coded identity (DCOV-issued labels) |
| `manufacturer` (alias-canonicalised) | OEM; scopes the site-code table |
| `country_of_origin` | documented origin ("Unknown", "N/A", "-" … = not established) |
| `is_chinese` | YES / NO / UNKNOWN, derived from the documented country at import |
| `category`, `verification_source`, `verified_by` | **evidence tier** (§3) |
| `confidence_score` | record confidence; capped with match score |
| `drone_subsystem`, `criticality`, `criticality_policy` | policy (§6), from `data/source/policy.json` |

## 2. Identity — the matching cascade

| # | Method | Score | Certain? |
|---|---|---|---|
| 1 | `exact_code` — raw payload equals a stored barcode/QR | 100 | yes |
| 1b | `label_mpn` — reel/bag label (ANSI MH10.8.2 / ECIA): field **1P** looked up | via cascade | as inner method |
| 2 | `normalized` — case/space/dash-insensitive part number | 100 | yes |
| 3 | `lot_code_stripped` — trailing lot/date code discarded | 96 | yes |
| 4 | `ocr_corrected` — one confusable glyph repaired (O↔0, I↔1 …) | 94 | yes |
| 5 | `ocr_folded`, `ocr_folded_stripped` — several glyphs folded | 90 / 87 | **no** |
| 6 | `prefix` — partial marking, single most-specific record | 88 | **no** |
| 7 | `fuzzy` — Damerau-Levenshtein ≥ 82 %, clear winner | 82–99 | **no** |
| — | `ambiguous_prefix`, `ambiguous_fuzzy`, `conflict` | — | no match returned |

Several records for one marking: agreeing origins → highest-confidence record;
UNKNOWN records yield to documented ones; **disagreeing origins → `conflict`,
no component selected** (manual adjudication). Every result carries the method,
score, notes and a step-by-step trace (shown in the app).

## 3. Evidence hierarchy (strongest first)

| Tier | Meaning | Source |
|---|---|---|
| `unit_marking` | the package itself carries a country-of-origin code (e.g. `CHN`) or a China-only assembly-site code | OCR/typed marking lines, `marking.py` tables (each code cites its source, e.g. ST PCNs) |
| `component` | origin documented for this component | teardown worksheet, identification worksheet, watchlist, curated import |
| `manufacturer` | only the OEM/manufacturer's home country is recorded | rows with `category = "OEM / LRU"` or source "OEM landscape" |
| `none` | no documented origin | `is_chinese = UNKNOWN` or country empty/"Unknown" |

**Not evidence (never used):** barcode/GS1 prefix (690–699 etc.), language on
packaging, brand name, seller, appearance. Reel-label **4L** country is shown to
the inspector as a *label claim* but never decides a verdict.

## 4. Verdict rules

1. No component → **GREY** `COMPONENT NOT FOUND` (queued for review on the server).
2. `is_chinese = YES` → **RED** `CHINESE COMPONENT DETECTED`.
3. `is_chinese = NO` **and** a real country → **GREEN** `NON-CHINESE COMPONENT`.
4. Otherwise → **YELLOW** `ORIGIN NOT FOUND`.
5. Effective confidence = min(record confidence, match score); < 60 % turns a GREEN into **YELLOW** `ORIGIN NOT CONFIRMED`.
6. GREEN resting only on `manufacturer` evidence → **YELLOW** `OEM NON-CHINESE - COMPONENT ORIGIN NOT DOCUMENTED`.
7. RED resting only on `manufacturer` evidence → stays **RED**, headline `CHINESE MANUFACTURER - COMPONENT ORIGIN PRESUMED CHINESE`.
8. Uncertain method (§2) + GREEN → **YELLOW** `IDENTITY UNCERTAIN - REQUIRES MANUAL REVIEW`.
9. Uncertain method + RED → stays **RED**, headline `PROBABLE CHINESE COMPONENT - CONFIRM MARKING`, review required.
10. Marking check (only ever tightens): red finding (unit marked CHN, China assembly site, site/country contradiction involving China) → **RED** `CHINESE ORIGIN MARKED ON PACKAGE`; yellow finding (non-China COO on a Chinese record, China wafer fab, missing COO where the maker always prints one) → GREEN becomes **YELLOW** `MARKING INCONSISTENT`. Absence of a suspicious marking is never evidence of a clean part.

`review_required` is true for every result except a GREEN reached by a certain method on component-level evidence.

## 5. Chinese / non-Chinese / unknown determination at import

`derive_is_chinese(country, remarks, declared)` (`importer.py`):
explicit YES/NO wins → "Made in China"/"COO China"/"PRC" in country or remarks → YES →
empty or Unknown-like country (`UNKNOWN, N/A, NA, -, ?, TBD, NONE, …`) → **UNKNOWN** →
country containing CHINA/PRC/HONG KONG/MACAU/SHENZHEN/CHN → YES → else NO.

Fixed in this release: "Unknown" previously fell through to **NO**, so 16 seed
records displayed GREEN on the server (YELLOW offline). Existing databases are
repaired with `python -m app.cli reclassify_unknown`.

## 6. Policy

From `data/source/policy.json` via each record's `criticality` and
`criticality_policy`:

| Result | CRITICAL | NON-CRITICAL | unclassified |
|---|---|---|---|
| chinese | NOT ACCEPTABLE (+ escalate) | PERMITTED BY POLICY (Chinese origin recorded) | REFER TO INSPECTING AUTHORITY |
| non_chinese | ACCEPTABLE | ACCEPTABLE | ACCEPTABLE |
| unknown_origin | REQUIRES MANUAL REVIEW | ← | ← |
| not_found | NOT IN CATALOGUE – REQUIRES MANUAL REVIEW | ← | ← |

The banner colour reports origin; the policy line reports acceptability. A
Chinese part in a non-critical subsystem is RED *and* "PERMITTED BY POLICY".

## 7. False-positive protections (wrongly calling a part Chinese)

- Origin never from barcode prefix, brand, language or label 4L.
- Conflicting records are not resolved automatically.
- Country/site codes are only parsed from lines other than the part-number line (a part number such as `…CHN…` cannot trigger).
- Site-code tables are manufacturer-scoped and every code cites a source.
- A photo with two packages: each package verified separately; a COO line is never attributed to another package (was a real bug, fixed).
- Uncertain RED says "PROBABLE … CONFIRM MARKING".

## 8. False-negative protections (missing a Chinese part)

- No GREEN from manufacturer-level evidence, uncertain matches, low confidence, or "Unknown" countries.
- Package COO marking overrides a non-Chinese catalogue record.
- UNKNOWN never becomes NO at import.
- Server verdict (live catalogue) supersedes the device copy online; offline the device uses the last synced catalogue (cached), not the older bundled seed.
- Not-found parts are GREY, never GREEN, and auto-queued for the database manager.

## 9. Sufficient evidence for each outcome

- **GREEN** requires all of: certain identity method, component-level documented non-Chinese country, effective confidence ≥ 60 %, no yellow/red marking finding.
- **RED** requires any of: catalogue `is_chinese = YES` (any tier), or a red marking finding on the unit.
- Everything else is **YELLOW** or **GREY** = manual review.
