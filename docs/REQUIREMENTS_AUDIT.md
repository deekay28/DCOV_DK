# DCOV — Requirements Audit

Checked against the original spec, section by section, on 2026-08-08.
**"Done" here means I traced it to real code and, where I had a runnable
interpreter for that language, executed the logic in this sandbox — not
that I ran the actual app.** I have no Flutter SDK, no Docker, and no
network in the environment this was written in (see `DEPLOY.md` and
`FLUTTER_TESTING.md` for what that did and didn't let me verify at each
stage). Every ❌ and 🟡 below is a real gap, not a hedge.

**Update — the first real `flutter analyze` run happened** (on the user's
own machine, guided step by step through Flutter/Android SDK setup on
Windows). Result: **5 real errors, 2 warnings, 8 info-level items**, all
now fixed. Worth recording exactly what they were, because it's a genuine
data point on how much static tracing without a compiler can and can't
catch:

- **Caught by tracing, before this run:** every cross-file import/symbol
  reference (verified programmatically), every brace/paren/bracket
  balance, every backend module import resolving, every pytest fixture
  defined, third-party package APIs checked against live docs
  (`share_plus`, `file_picker`, `DropdownButtonFormField`, `ColorScheme`).
- **Only the compiler caught:** a class named `Matcher` colliding with
  `package:matcher`'s own `Matcher` (ambiguous_import - needed a rename to
  `ComponentMatcher`); a real null-safety bug in `api_client.dart`'s `_u()`
  helper (a cascade on a nullable receiver that would have thrown at
  runtime the first time any endpoint was called with no query
  parameters); a `file_picker` version resolved by pub's actual solver
  using instance access (`FilePicker.platform.pickFiles`) rather than the
  static access the pinned-version docs implied; the stock
  `test/widget_test.dart` that `flutter create .` generates, referencing a
  `MyApp` class that doesn't exist in this app; plus a handful of
  genuinely cosmetic items (a dead null-aware `?? false`, an unused
  constant, deprecated `withOpacity`, doc-comment formatting).

That's a real, useful ratio: the tracing-only approach caught the large
majority of what mattered and missed exactly the class of thing it
structurally can't see — cross-package symbol collisions and a version the
pub solver picks at resolve time, not read time.

**Update — the backend's own first real `pytest` run happened too**, on
the same machine, once the Flutter toolchain work above was underway. It
took several rounds to get clean, and every round found something real,
never a false alarm:

- A `passlib` `CryptContext` scheme list with a literal duplicate entry
  (`settings.password_scheme` could equal one of the two hardcoded
  fallback schemes already in the list) - broke every single test that
  touched auth, since this raises at import time.
- Four routes (`logout`, `password`, `pin`, `delete_component`) missing an
  explicit `response_model=None` - FastAPI infers a response model from a
  `-> None` return annotation in a way that fails its own "a body-less
  status code can't have a response model" check, at route registration
  time. This broke `app.main` import entirely, which is why the first
  fix's fallout looked like "everything is broken" rather than one bug.
- `AuditLog.sequence`, declared `autoincrement=True` but not actually the
  table's primary key/rowid - a no-op on SQLite. Every audit-logged action
  failed a NOT NULL constraint, including login itself.
- A systemic SQLite limitation affecting all 16 `DateTime(timezone=True)`
  columns: a value written as timezone-aware comes back *naive* on a fresh
  query, in a different session than the one that wrote it. This broke the
  audit hash chain (a freshly-inserted, untampered row reported
  "intact: False" the moment it was re-queried) and account lockout
  (comparing a naive `locked_until` against an aware `utcnow()` raised an
  unhandled `TypeError`). Fixed once, at the type level
  (`UTCDateTime`), rather than patched at each comparison site as found.
- That same fix broke `openpyxl` export in turn - Excel's date format has
  no timezone concept at all, and `openpyxl` refuses a timezone-aware
  `datetime` outright. Fixed by normalizing to naive UTC specifically at
  the report-writing boundary, not by reverting the real fix above.
- `get_session()`'s blanket `except Exception: rollback()` was silently
  discarding legitimate state changes (a failed-login counter increment,
  an audit log entry) any time the request's own response was a
  deliberately-raised `HTTPException` - which is FastAPI's normal
  mechanism for a 401/404/409/etc., not an error. Every failed login was
  quietly erasing the record that it had happened.
- And finally, one bug that traced back to the *test* rather than the
  app: a hardcoded 3-character wrong-password fixture that Pydantic's own
  `min_length=8` rejected before the request ever reached the login
  logic - meaning the account-lockout test had never once exercised
  lockout at all, across every round of the debugging above.

All 56 backend tests pass as of this update. Worth being honest about the
shape of that last bug in particular: three consecutive, real,
independently-necessary fixes were made while chasing a test failure that
turned out to have nothing to do with any of them. The fixes were still
correct and still needed - they just weren't what was breaking that one
test. Only printing the actual per-request status codes (rather than
continuing to reason about the application code from first principles)
surfaced the real cause.

Legend: ✅ done and verified · 🟡 partially done, or done but unverified ·
❌ not done · — not applicable, with reason

---

## Objective

| Requirement | Status | Evidence |
|---|---|---|
| Import/maintain a component database | ✅ | `backend/app/services/importer.py`, `app/api/catalog.py` |
| Read an Excel database | ✅ | `.xlsx`/`.xlsm` parsing in `importer.parse_file`; `data/DCOV_Sample_Database.xlsx` is one |
| Scan barcodes and QR codes | ✅ | `mobile_scanner` in `verify_screen.dart`; backend `input_mode='barcode'/'qr'` |
| Read chip markings via OCR | 🟡 | Server OCR (`app/services/ocr.py`, EasyOCR/Tesseract ensemble) is real and tested for its non-CV logic (classification, scoring). **No on-device OCR** — offline chip-photo capture falls back to manual entry, by design, stated in `README.md` |
| Search the database | ✅ | Six-layer matching cascade, `app/services/matching.py`, cross-verified in Python/JS/Dart |
| Identify country of origin | ✅ | `country_of_origin` field, derived verdict logic |
| Indicate Chinese/non-Chinese | ✅ | Four-banner verdict system (RED/GREEN/YELLOW/GREY) |
| Generate reports | ✅ | PDF/XLSX/CSV, 6 report types, see Reports section below |
| Maintain inspection history | ✅ | `ScanRecord`/`Inspection` tables, audited; on-device history log in the app |
| Fast, reliable in field conditions | 🟡 | Matching is O(1)-ish for exact/normalized hits; **no load test performed** at any scale — see Performance section |

---

## Technology stack

| Spec'd | Status |
|---|---|
| Flutter, single codebase | ✅ `frontend_flutter/` — Android/iOS/Windows/macOS/Linux/web from one `lib/` |
| Material Design 3 | 🟡 Uses Flutter's Material widgets; not verified against an M3-specific checklist |
| Dark/light mode | ✅ `theme/dcov_theme.dart`, toggle in Settings and top bar |
| FastAPI backend | ✅ `backend/app/main.py` |
| JWT auth | ✅ `app/core/security.py` |
| SQLite (offline) | ✅ default `DCOV_DATABASE_URL` |
| PostgreSQL/MySQL (server) | 🟡 PostgreSQL wired and used in `docker-compose.yml`; MySQL driver (`asyncmy`) is in `requirements.txt` but never exercised against a real MySQL instance |
| Google ML Kit / Tesseract / OpenCV / EasyOCR | 🟡 Tesseract+EasyOCR+OpenCV wired server-side (`requirements-vision.txt`); **ML Kit (on-device) not integrated** |
| Barcode: QR/128/39/EAN-13/UPC/DataMatrix/PDF417 | 🟡 `mobile_scanner` (ZXing/ML Kit under the hood) supports all of these natively; **not individually tested per symbology** |

---

## Database import

| Requirement | Status | Evidence |
|---|---|---|
| Excel / CSV / JSON / SQL import | ✅ | `importer.parse_file` handles all four; `.sql` deliberately `INSERT`-only, see `ADMIN_MANUAL.md` |
| Import wizard | ✅ | Stage → preview → commit, `POST /database/import/stage`+`/commit` |
| Validation | ✅ | `validate_row`, tested in `tests/test_importer.py` |
| Duplicate detection | ✅ | `stage_import`'s `seen_ids`/duplicates tracking |
| Merge existing records | ✅ | Field-level diff against live catalogue, per-field before/after in the preview |
| Rollback import | ✅ | `POST /database/import/{batch_id}/rollback`, replays `ComponentRevision` snapshots; tested end to end in `test_catalog_api.py` |

## Database fields

All fields from the spec's example list exist on the `Component` model
(`component_id`, `manufacturer`, `manufacturer_country`, `component_name`,
`part_number`, `chip_number`, `barcode`, `qr_code`, `category`,
`drone_subsystem`, `country_of_origin`, `is_chinese`,
`alternative_manufacturer`, `military_grade`, `remarks`, `image_path`,
`datasheet_url`, `supplier`, timestamps, `verified_by`,
`verification_source`, `confidence_score`) — ✅, see
`backend/app/models/entities.py`.

---

## Dashboard

| Requirement | Status |
|---|---|
| Total/Chinese/Non-Chinese/Unknown counts | ✅ `GET /dashboard`, surfaced in the app's Overview tab |
| Recently scanned / recently imported | ✅ same endpoint |
| Pending verification | ✅ `pending_verification` count |
| Inspection statistics | 🟡 counted, but no dedicated inspection-stats view — folded into `/dashboard` |
| Recent alerts | ✅ Chinese+CRITICAL scans specifically surfaced |

---

## User roles, login, RBAC

| Requirement | Status | Evidence |
|---|---|---|
| Administrator / Inspector / Viewer / Database Manager | ✅ | `Role` enum, deny-by-default `PERMISSIONS` matrix in `security.py` — generated table in `ADMIN_MANUAL.md` |
| Username/password login | ✅ | tested, including uniform-failure-message behavior |
| Biometric login | 🟡 | Backend endpoint (`/auth/login/biometric`) verifies a real signature over a server nonce — **no Flutter client calls it** |
| PIN login | ✅ | Enrollment + quick-unlock in Settings/login screen, server-enforced device binding (`trusted_device_ids`) — this specific feature had a real vulnerability (no device binding at all) that was found and fixed mid-project, see `ADMIN_MANUAL.md` |
| Role-based access | ✅ | Enforced server-side on every mutating endpoint, not just hidden in the UI |

---

## Home screen / navigation

Spec called for: Scan Barcode, Scan QR, Scan Chip, Manual Search, Import
Database, Inspection History, Reports, Settings as home-screen actions.

| Action | Status |
|---|---|
| Scan barcode/QR | ✅ Verify tab |
| Scan chip (photo) | ✅ Verify tab, OCR online / manual entry offline |
| Manual search / manual entry | ✅ Verify tab's text field; Catalogue tab for browsing |
| Import database | ✅ | Now a real screen (`import_screen.dart`) — was the single largest surface-area gap between spec and app, closed this session |
| Inspection history | ✅ History tab (on-device log) + backend `/scan/history`/`/inspections` |
| Reports | ✅ **Reports screen added** — all 6 report types, format picker (PDF/XLSX/CSV), generates and hands off to the OS share sheet. Reachable from the Overview tab and the account sheet. Audit Trail report hidden from non-administrators client-side (backend still enforces it regardless) |
| Settings | ✅ Settings screen (added this session) |

---

## Scan workflow and result screens

| Requirement | Status | Evidence |
|---|---|---|
| Capture → improve image → OCR → normalize → search → return result | ✅ | Full pipeline server-side; `app/services/ocr.py`'s preprocessing (deskew, glare inpainting, CLAHE, multi-variant ensemble) is real, not a stub |
| RED banner (Chinese) with full detail set | ✅ | `verdict_widgets.dart`, matches spec's field list |
| GREEN banner (non-Chinese) | ✅ | |
| YELLOW banner (origin not found) | ✅ | |
| GREY banner (not found) + auto-queue for review | ✅ | `PendingComponent` queuing happens automatically server-side on every `not_found` scan, no explicit user action required |
| Play warning sound / vibrate on Chinese detection | ✅ | Server flags `alert`/`vibrate`/`sound`; Flutter calls `HapticFeedback`/`vibration` package (web demo has an audible two-tone beep) |
| "Add New Component" action from not-found screen | ❌ | No in-app create-component action (ties to the missing admin-screen gap above) |
| "Search Internet" (optional, per spec) | ❌ | Not implemented — spec marked this optional |

---

## OCR module

| Requirement | Status |
|---|---|
| Recognize SMD/IC/laser/processor/memory/FPGA/etc. markings | 🟡 Server pipeline classifies part-number vs. lot-code vs. date-code vs. vendor text generically (`classify_marking` in `ocr.py`) — not chip-family-specific, but the generic approach covers all of these by construction |
| Auto rotate/deglare/contrast/denoise/sharpen | ✅ | `_deskew`, `_suppress_glare` (inpainting), CLAHE, `fastNlMeansDenoising`, sharpening kernel — all real OpenCV calls, not placeholders |
| Detect multiple chips, read each separately | ✅ | `detect_chip_regions` segments a board photo before OCR |
| Merge OCR results across engines | ✅ | `merge_lines` — cross-engine, cross-preprocessing-variant voting |
| **On-device OCR (no network)** | ❌ | This is the real gap — everything above runs server-side only |

---

## Barcode scanner

| Requirement | Status |
|---|---|
| QR, Code128, Code39, EAN-13, UPC, DataMatrix, PDF417 | 🟡 supported by the underlying `mobile_scanner` plugin; not individually verified per symbology in this project |
| Continuous / single / batch scan modes | 🟡 Backend supports batch (`POST /scan/batch`); **the app's Verify screen has no explicit mode toggle** — it's continuously ready to scan one at a time, which covers "continuous" and "single" but not a distinct teardown/batch UI |
| Auto focus, flashlight, zoom | 🟡 Provided by the camera plugin's defaults; not explicitly surfaced as UI controls (e.g. no flashlight toggle button) |

---

## Search module

✅ All spec'd search dimensions (barcode, chip number, manufacturer,
country, drone subsystem, part number, category, keyword) are filterable —
`GET /components` query params, and the app's Catalogue tab filters.

---

## Inspection module

| Requirement | Status |
|---|---|
| Create inspection, assign inspector | ✅ `POST /inspections` |
| Inspection number | ✅ auto-generated (`INSP-YYYY-NNNNN`) |
| Location / GPS / timestamp | ✅ `latitude`/`longitude`/`started_at` fields |
| Final status, digital signature | ✅ `POST /inspections/{id}/sign` — HMAC signature over the frozen record, immutable once signed, tested |
| **In-app inspection creation/sign-off UI** | ✅ | `screens/inspections_screen.dart` — list (mine/all-open), create, per-inspection scan tally, sign-off with the same clear-with-Chinese-findings rejection surfaced client-side before the server 409s. An "active inspection" concept threads `inspection_id` through every scan (online and offline-queued) once set, added to `AppState` this session |

---

## Reports

✅ All 6 report types generate in all 3 formats (PDF/XLSX/CSV) —
`inspection`, `chinese_components`, `unknown_origin`, `statistics`,
`monthly`, `audit`. Verified by actually rendering a PDF and inspecting the
page image earlier in this project, and by `test_catalog_api.py`. **Now
downloadable from the app** — `screens/reports_screen.dart`, added this
session, is the first of the audit's "real backend, no Flutter screen"
findings actually closed. Uses `share_plus`'s current
`SharePlus.instance.share(ShareParams(...))` API — worth noting *why* that
detail matters here: I found while building this that the package's older
`Share.shareXFiles()` static method (what I'd have written from training
data alone) is now deprecated in favor of that instance API, caught by
checking pub.dev directly rather than assumed. A third-party package's API
surface is exactly the kind of thing that goes stale between a model's
training cutoff and whenever this code actually gets compiled.

---

## Database management

| Requirement | Status |
|---|---|
| Import/export/edit/delete/bulk update | ✅ | all via API, tested |
| Version history | ✅ | `ComponentRevision`, `GET /components/{id}/history` |
| Backup / restore | ✅ | `POST /database/backup`+`/restore`, SQLite online-backup API, pre-restore safety snapshot |
| Merge database | ✅ | import diff/merge logic |
| Validate entries | ✅ | `validate_row` |
| **Import from within the app** | ✅ | `screens/import_screen.dart` — file picker, stage/preview/commit, origin-verdict-flip warnings surfaced unmissably above everything else in the preview, an explicit "I have reviewed" checkbox gating the commit button. Deliberately built slowly, per `ROADMAP.md`'s note on why |
| **Export/edit/delete/bulk-update/backup/restore from within the app** | ❌ | Still API/curl/Swagger only. Import (including rollback) is now the exception, not export/backup/restore/bulk-update |

---

## History, analytics

| Requirement | Status |
|---|---|
| Who/when/where/result/device/images/barcode/OCR text | ✅ | all fields on `ScanRecord` |
| Most-detected Chinese components, top manufacturers | ✅ backend | `GET /analytics` |
| Trends, monthly analysis, charts | ✅ backend | same endpoint |
| Heat maps | ✅ backend | `heatmap` field in the same response |
| **Any of this surfaced in the app** | ✅ | `screens/analytics_screen.dart` — result mix, monthly trend, top manufacturers, most-detected Chinese components, the needs-verification queue, and heat-map data (as a sorted location×weekday list, not a chart grid — see the file's own comment on why no charting package was added just for this). Reachable from Overview and the account sheet, same as Reports/Inspections |

---

## Offline capability

✅ Genuinely offline-first, not offline-as-afterthought: bundled 203-record
catalogue, full matching engine on-device (Dart port, cross-verified
against Python/JS), scan queue that syncs on reconnect. This is one of the
most solid parts of the build.

---

## Notifications

🟡 The spec called for push-style notifications (database update available,
unknown component found, import failed, etc.). What exists now is an
**in-app notification center**, not push: `notifications_screen.dart`, a
bell icon with an unread badge in the app bar, populated at the points in
the app that actually generate these events — an unknown-component scan,
import commit/failure/rollback, and a detected catalogue-size change on
sync. Genuinely not push (no FCM/APNs) — deliberately, per `ROADMAP.md`'s
scoping note, since push needs platform-specific setup and a backend
trigger component that's a separate project from this one. "Database
update available" specifically is a coarse heuristic (row-count changed),
not a true revision comparison — noted honestly in the code rather than
presented as more precise than it is.

---

## Camera features

| Requirement | Status |
|---|---|
| Auto focus, flash, manual capture | ✅ | provided by the camera plugins in use |
| Macro mode, HDR, image stabilization, burst capture, auto-crop, perspective correction | ❌ | none of these are implemented; would require either a custom camera pipeline or a plugin beyond `mobile_scanner`/`image_picker` |

---

## AI / matching features

| Requirement | Status | Evidence |
|---|---|---|
| Fuzzy matching | ✅ | Damerau-Levenshtein + prefix-weighted similarity |
| Approximate part-number matching | ✅ | lot-code stripping, glyph-class folding |
| Manufacturer alias detection | ✅ | `DEFAULT_MANUFACTURER_ALIASES` — this was a real bug (aliases defined but never wired into any live code path) found and fixed mid-project |
| OCR error correction | ✅ | single-glyph confusion repair + glyph-class folding, two separate layers |
| Barcode validation | 🟡 | seed-data barcodes are checksum-valid EAN-13; **no checksum validation of a scanned barcode against its symbology** on the way in |
| Confidence score | ✅ | every match and every catalogue row carries one; low-confidence matches are explicitly downgraded (`verdict_for`'s floor) |
| Duplicate detection | ✅ | import-time (`stage_import`) |
| Suggestion engine | ✅ | every non-exact match returns ranked alternatives, never silently guesses on a genuine conflict |

---

## Security

| Requirement | Status | Evidence |
|---|---|---|
| AES-256 encrypted local database | 🟡 | Researched properly this session rather than left as a TODO: `aiosqlite` (used throughout this async backend) has no supported path to SQLCipher, which is a synchronous SQLAlchemy dialect — the `sqlcipher3-binary` line that implied otherwise has been removed from `requirements.txt` as actively misleading. Real mitigation documented in `ADMIN_MANUAL.md`'s new "Encryption at rest" section: OS/disk-level encryption (BitLocker/FileVault/LUKS/mobile device encryption), which needs no application changes and protects more than just this one file. True file-level SQLCipher support would require moving off the async engine — scoped as its own future project, not attempted half-verified |
| JWT authentication | ✅ | HS256, access+refresh, revocation on logout |
| Biometric authentication | 🟡 | backend only, see Login section |
| RBAC | ✅ | deny-by-default, tested |
| Audit logs | ✅ | hash-chained, tamper detection proven by a test that corrupts a row directly and confirms `/audit/verify` catches it |
| Tamper detection | ✅ | same as above |
| Secure backup/restore | ✅ | SQLite online-backup API, pre-restore safety copy |
| HTTPS | ✅ | Caddy reverse proxy added this session — automatic cert (public ACME or internal CA), backend has no other reachable path |
| SQL injection protection | ✅ | SQLAlchemy parameterized queries throughout; `.sql` import is regex-scraped `INSERT`-only, never executed as SQL |
| XSS protection | ✅ | Pydantic rejects control characters/angle brackets at the schema level; web demo escapes all rendered text (`esc()`) |
| CSRF protection | — | **N/A by design, not a gap**: this is a JWT-bearer-token API (`Authorization` header), not cookie-session-based — there's no ambient browser-sent credential for a forged cross-site request to exploit. CSRF tokens are a mitigation for a threat model this architecture doesn't have |
| Input validation | ✅ | Pydantic on every endpoint |
| Automatic logout after inactivity | 🟡 | Implemented as a client-side **screen lock**, not a server-forced logout: `AppState`'s inactivity timer + `main.dart`'s `_ActivityGate`/`_LockScreen`, unlocked with a locally-stored PIN (secure storage) that never needs network — deliberately, so an idle timeout doesn't strand a field user out of signal. `inactivity_logout_minutes` in `backend/app/core/config.py` is still unread by the server; this solves the same user-facing need from the client instead, which is a legitimate but different design than what that config value implies exists server-side. Off by default until a screen-lock PIN is configured in Settings — a lock with no way to unlock it is a worse failure than no lock at all |

---

## Performance requirements

| Requirement | Status |
|---|---|
| Scan result within 2 seconds | 🟡 the matching cascade is designed for this (exact/normalized layers are near-instant; fuzzy fallback is trigram-blocked, not a full scan) but **never measured against a clock** |
| OCR accuracy above 95% | ❌ **never measured** — no labeled test set of real chip photos exists to measure against. The classification/scoring logic is unit-tested; end-to-end OCR accuracy on real hardware is not |
| Support 1,000,000+ components | 🟡 the in-memory `ComponentIndex` (trigram blocking) is the right *shape* of design for this, but was only ever built and tested against 203 rows. **No load test at scale has been run** |
| Automatic crash recovery, comprehensive logging | 🟡 structured JSON logging exists (`main.py`'s `LOGGING` config); "crash recovery" beyond FastAPI/uvicorn's own process model isn't specifically engineered |

---

## UI/UX requirements

| Requirement | Status |
|---|---|
| Modern, responsive, dark/light | ✅ |
| Color-coded banners | ✅ exact palette from spec |
| Search filters | ✅ |
| Scan animation, loading indicators | 🟡 basic loading states exist; no dedicated scan animation |
| Accessibility support | ❌ **not verified** — no `Semantics` widgets, no screen-reader pass, no accessibility audit. Flutter's default Material widgets carry *some* baseline accessibility for free, but nothing here was deliberately built or tested for it |
| Multi-language support | ❌ English only. `intl` is a dependency (used for date/number formatting) but there is no localization framework wired up (no `flutter_localizations`, no `.arb` files, no translated strings) |

---

## Deliverables checklist

| Deliverable | Status |
|---|---|
| Full source code, modular structure | ✅ |
| Flutter frontend | ✅ (with the screen-coverage gaps noted above) |
| FastAPI backend | ✅ |
| SQLite + PostgreSQL/MySQL support | 🟡 SQLite+PostgreSQL proven; MySQL untested |
| OCR + barcode modules | 🟡 server OCR real; on-device OCR missing |
| Import/export utilities | ✅ |
| Auth + user management | ✅ |
| Complete REST API | ✅ documented live at `/api/docs` |
| Sample Excel database with test records | ✅ `data/DCOV_Sample_Database.xlsx`, 203 real records derived from the source workbook |
| Automated tests | ✅ ~40 pytest cases (backend), matching-engine test vectors (Dart) — **none executed in this environment**, see caveat at top |
| Installation/deployment guide | ✅ `DEPLOY.md` |
| User manual | ✅ `USER_MANUAL.md` |
| Administrator manual | ✅ `ADMIN_MANUAL.md` |
| API documentation | 🟡 live Swagger/OpenAPI at `/api/docs`; **no standalone written API reference document** exists separately from that |
| Docker support | ✅ `docker-compose.yml` + Caddy TLS |
| CI/CD configuration | ✅ `.github/workflows/ci.yml` — **never actually run** |
| Error handling and logging | ✅ structured exception handlers, JSON logging |

---

## The honest summary

**Solid and real:** the matching engine (the actual core intellectual
content of this app — verified three ways, in three languages), the import
wizard's safety properties (stage/commit/rollback, never silently flips an
origin verdict), RBAC and the audit chain, offline-first architecture, and
the two security bugs that were found and fixed mid-project rather than
shipped (PIN device binding, plaintext session tokens) — finding those
*is* the kind of thing this level of scrutiny is supposed to catch.

**The one pattern across most of the remaining real gaps:** with Reports,
Inspections, Analytics, Import, and User Management now built (all five
Phase 2 screens from `ROADMAP.md`), the "real backend capability with no
Flutter screen" pattern that dominated this audit's first pass is mostly
closed — what's left in that category is narrower (export, edit/delete,
bulk-update, backup/restore still API-only). The other pattern is
unchanged: **a feature that's declared but never wired up** — AES-256 local
encryption, inactivity auto-logout, notifications. That's still real
backend/config work sitting unexploited, just a smaller list than before.
The highest-leverage next work is
concentrated, not scattered.
