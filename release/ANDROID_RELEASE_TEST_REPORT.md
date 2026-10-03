# Android release test report

## Summary

| Area | Result |
|---|---|
| APK built | **NO — not in this environment.** Flutter SDK / Android SDK / Maven unreachable (egress policy). Build is defined in `.github/workflows/build-apps.yml` and has not run yet. |
| Physical-device tests | **None executed** (no device). Checklist: `FIELD_ACCEPTANCE_TEST.md`. |
| Backend the APK talks to | **119 / 119 automated tests pass**; live LAN smoke test 10/10 checks pass. |
| Offline engine parity | Python ↔ JS: 4 872 verdicts + 13 match probes identical. Dart: tests written, run in CI. |

## What the CI build checks automatically (once run)

1. `flutter analyze` — compile errors fail the build (first compile of the changed Dart code).
2. `flutter test` — matching/verdict/label/OCR-ranking/widget tests.
3. `flutter build apk --release` and `--split-per-abi`.
4. `aapt2 dump badging` — package `com.dcov.field`, version 1.1.0 (2), min/target SDK, permissions → `APK_BUILD_INFO.txt`.
5. `tool/check_apk.py` on every APK — fails on private keys, backend secret, DB URLs with passwords, keystore passwords, AWS keys, test passwords; requires the bundled catalogue + policy.
6. SHA-256 for every APK.

## Server-side tests executed here that correspond to device workflows

| Device workflow | Automated equivalent (ran, passed) |
|---|---|
| Barcode → database | `test_origin_logic.py::test_ecia_label_*`, `test_single_field_code128_label`, `test_gs1_prefix_is_not_used_for_origin`; exact_code via smoke test |
| Photo → OCR → match → verdict | `test_ocr_pipeline.py` (16 tests, real Tesseract on rendered markings: clean, rotated 8/25/-30/90/180/-90°, low light, noise, small glyphs, blur, glare, two chips, garbage input) |
| OCR upload → confirmed scan with image | `test_field_api.py::test_photo_upload_ocr_only_then_confirmed_scan_links_image` |
| Multi-chip photo | `test_multi_chip_photo_creates_one_scan_per_package` |
| Known Chinese / non-Chinese / unknown / not-found / wrong marking / multiple matches / unknown origin | `test_origin_logic.py` (23), `test_matching.py` (15), `test_scan_api.py` (10) |
| Duplicate scan / offline replay | `test_replayed_scan_is_not_duplicated`, `test_sync_push_reports_duplicates` |
| Token refresh (long field session) | `test_refresh_token_in_json_body` |
| LAN reachability | `run_lan_server.sh` started; `/health` via LAN IP 200; wrong Host header rejected |
| Reports, audit chain | `scripts/smoke_test.sh` against the LAN server: ALL CHECKS PASSED |

## Not tested (requires a phone)

Camera preview and permissions, barcode decoding from a camera, ML Kit OCR
quality on real chips, vibration, offline→online transition and queue upload
from the device, screen rotation, back-button behaviour, app restart, logcat
cleanliness. All are rows in `FIELD_ACCEPTANCE_TEST.md`.
