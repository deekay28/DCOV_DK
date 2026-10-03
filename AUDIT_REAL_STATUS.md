# DCOV — Real Status Audit

Audit date: 2026-10-03. Method: every claim below was checked against the
source and, where this environment allowed, by **running** it. "Works on real
device" is only ever YES when it was exercised on a physical phone — which
has **not** happened yet for any feature (no device and no Flutter toolchain
were reachable from the audit environment; see "Environment" below).

Status values: **VERIFIED** (ran and passed) · **PARTIALLY VERIFIED** (part of
the chain ran) · **NOT VERIFIED** (code exists, never executed) · **BROKEN**
(executed and failed — all such items found were fixed, see CHANGELOG.md) ·
**NOT IMPLEMENTED**.

## Environment the audit ran in

| Tool | State |
|---|---|
| Python 3.13, OpenCV 5, Tesseract 5.3.4, Node 22, JDK 21, Gradle 8.14 | available |
| FastAPI, SQLAlchemy, pytest, … | not installable from PyPI (egress blocked) — built from their GitHub sources |
| Flutter / Dart SDK | **not obtainable** (storage.googleapis.com blocked) |
| Android SDK / Maven / Gradle plugin repos | **not obtainable** (dl.google.com, maven.google.com, repo.maven.apache.org blocked) |
| Physical Android device / adb | none |
| macOS / Xcode | none |

Consequence: the backend was run and tested for real; the Flutter app could
not be compiled here. A GitHub Actions workflow (`.github/workflows/build-apps.yml`)
was added to compile, test and package it on GitHub's runners.

## Feature table

| Feature | Code exists | Integrated | Tested | Works on real device | Status | Evidence |
|---|---|---|---|---|---|---|
| Backend startup, DB init, seed load | Yes | Yes | Yes | n/a | VERIFIED | `scripts/run_lan_server.sh` run: schema created, 203 rows indexed, admin created; `/health`, `/ready` 200 |
| Alembic migration ↔ ORM | Yes | Yes | CI script only | n/a | NOT VERIFIED here | CI step in `ci.yml` (regex comparison) |
| Authentication (password, lockout, roles) | Yes | Yes | Yes | n/a | VERIFIED | `tests/test_auth_api.py` (10 tests) |
| Token refresh | Yes | **Was not used by app** | Yes | No | VERIFIED (backend), NOT VERIFIED (app) | `test_refresh_token_in_json_body`; app now refreshes (app_state.ensureFreshToken) |
| PIN login | Yes | Yes | Yes | No | VERIFIED (backend) | `test_auth_api.py`, `test_pin_enrolment_accepts_json_body` |
| Biometric login | Backend only | No | No | No | NOT IMPLEMENTED (app) | no Flutter caller |
| Component catalogue (CRUD, facets) | Yes | Yes | Yes | n/a | VERIFIED | `test_catalog_api.py` |
| Import wizard / rollback | Yes | Yes | Yes | n/a | VERIFIED | `test_importer.py`, `test_catalog_api.py` |
| Matching cascade (Python) | Yes | Yes | Yes | n/a | VERIFIED | `test_matching.py`, `test_origin_logic.py` |
| Matching cascade (JS web demo) | Yes | Yes | Yes | n/a | VERIFIED | `test_engine_parity.py`: 4 872 verdicts + 13 matches identical to Python |
| Matching cascade (Dart, offline in app) | Yes | Yes | Tests written | No | NOT VERIFIED | `test/matching_test.dart` — runs in CI only |
| Origin determination | Yes | Yes | Yes | n/a | VERIFIED (after fixes) | `test_origin_logic.py` (23 tests). **Was BROKEN**: 16 "Unknown" records became non-Chinese GREEN on the server; OEM-HQ country gave GREEN |
| Chinese-origin detection | Yes | Yes | Yes | n/a | VERIFIED | RED for catalogue YES, for CHN package marking, for China site codes |
| Policy (criticality) engine | Yes | Yes | Yes | n/a | VERIFIED | `policy_decision` on every scan result |
| Anti-remark marking analysis | Yes | Yes | Yes | n/a | VERIFIED | `test_marking.py`, OCR chain tests |
| Server OCR (Tesseract + OpenCV) | Yes | Yes | Yes, synthetic images | n/a | PARTIALLY VERIFIED | `test_ocr_pipeline.py` (16 tests on rendered markings). **Was BROKEN** 3 ways (COO/lot lines dropped, crash on rotated photos, cross-chip COO contamination). Not tested on real chip photos |
| EasyOCR engine | Yes | Optional | No | n/a | NOT VERIFIED | torch not installable here |
| On-device OCR (ML Kit) | **Added** | Yes | Ranking logic unit-tested (Dart, CI) | No | NOT VERIFIED | `lib/services/ocr_service.dart`; was NOT IMPLEMENTED |
| Barcode/QR scanning (camera) | Yes (mobile_scanner) | Yes | No | No | NOT VERIFIED | needs a phone |
| Reel-label barcodes (ECIA 1P/4L) | **Added** | Yes | Yes | No | VERIFIED (logic) | `test_origin_logic.py` label tests; Dart tests in CI |
| Barcode → database match | Yes | Yes | Yes | No | VERIFIED (logic) | exact_code / label_mpn paths tested |
| GS1 prefix used as origin | No (correct) | — | Yes | — | VERIFIED absent | `test_gs1_prefix_is_not_used_for_origin` |
| Photo capture + permissions | Yes | Yes (improved) | No | No | NOT VERIFIED | permission-denied dialogs added; needs phone |
| Photo → OCR → match → verdict | Yes | Yes | Server side yes | No | PARTIALLY VERIFIED | `test_photo_upload_ocr_only_then_confirmed_scan_links_image` |
| Multi-chip photos | Yes | Yes | Yes | No | VERIFIED (server, synthetic) | one scan per package; COO stays with its package |
| Scan images stored as evidence | **Added** | Yes | Yes | No | VERIFIED (server) | `image_path`/`image_ref`; path-traversal test |
| Duplicate scan handling | Yes | Yes | Yes | No | VERIFIED (server) | replay by client_uuid; sync duplicates reported |
| Offline sync APIs (/sync/push, /sync/pull) | Yes | **push now used by app** | Yes | No | VERIFIED (server) | `test_sync_push_reports_duplicates` |
| App offline queue | Yes | Rewritten | No | No | NOT VERIFIED | **Was BROKEN**: stopped queuing 30 min after sign-in |
| ONLINE VERIFIED vs OFFLINE/PENDING display | **Added** | Yes | No | No | NOT VERIFIED | `_StatusStrip` in verify_screen.dart |
| Catalogue cache for offline restarts | **Added** | Yes | No | No | NOT VERIFIED | **Was BROKEN**: restart offline reverted to bundled seed |
| Reports (PDF/XLSX/CSV) | Yes | Yes | Yes | No | VERIFIED (server) | smoke test: 18 KB PDF, 9.6 KB XLSX, 11 KB CSV |
| Audit hash chain | Yes | Yes | Yes | n/a | VERIFIED | `test_audit_chain.py`, smoke test "chain intact" |
| Inspections + signing | Yes | Yes | Yes | No | VERIFIED (server) | `test_scan_api.py` |
| LAN deployment (phone → PC server) | Yes | **Was BROKEN** | Yes | No | VERIFIED (server) | TrustedHost rejected LAN IP; quickstart bound 127.0.0.1. New `run_lan_server.sh/.ps1` tested via LAN IP |
| Docker / Caddy deployment | Yes | Yes | No | n/a | NOT VERIFIED | docker hub blocked here |
| Android platform config | Generated in CI | Yes | Patcher tested on real Flutter templates | No | PARTIALLY VERIFIED | `tool/configure_platforms.py` |
| Android APK | — | — | — | — | **NOT BUILT HERE** | blocked toolchain; CI workflow builds it |
| Windows build | — | — | — | — | NOT BUILT HERE | CI job `windows` |
| iOS build | — | — | — | — | NOT BUILT HERE | CI job `ios` (no-codesign compile) |
| Web demo | Yes | Yes | JS engine yes | n/a | PARTIALLY VERIFIED | parity test; Playwright check in CI |

## Exact blockers to a production-quality Android APK

1. **No Flutter/Android toolchain reachable from this environment** — resolved
   by running `.github/workflows/build-apps.yml` on GitHub (or any PC with
   Flutter). Until that runs, nothing in the Flutter app has been compiled
   since these changes; `flutter analyze` in CI is the first compile check.
2. **No physical-device test yet** — camera, barcode, ML Kit OCR, permissions,
   offline/online transitions must be run per `FIELD_ACCEPTANCE_TEST.md`.
3. **Release signing key** — without the four `ANDROID_*` repository secrets
   the APK is debug-key signed: installable and shareable for testing, not
   publishable, and a later differently-signed build cannot update it in place.
4. **Production transport** — the LAN setup is plain HTTP. Anything beyond an
   isolated field network needs HTTPS (deploy/Caddyfile).
5. **Catalogue content** — 203 seed records; 104 are manufacturer-level only
   (now YELLOW by design). Field usefulness depends on loading a real,
   component-level catalogue.
