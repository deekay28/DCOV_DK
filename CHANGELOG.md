# Changelog

## 1.1.0 (build 2) — 2026-10-04 — first Android APK (CI)

- **Android release APK builds in CI** (run #11): `com.dcov.field` 1.1.0 (2),
  minSdk 24, targetSdk 36, not debuggable, debug-key signed. Published as
  GitHub pre-release `android-v1.1.0-build2-run11`.
- **Fixed:** Android build failure on Flutter 3.47 (AGP 9 built-in-Kotlin vs
  plugins still applying kotlin-android). Flutter pinned to 3.41.9;
  `google_mlkit_text_recognition` capped `<0.17`.
- **Fixed:** universal APK lost when the per-ABI build reused the output dir.
- **Fixed:** APK secret scan false positive on Apache Tika's MIME table (now
  requires a real PEM body) and scan step not failing the job on a hit.
- CI: public annotations for build errors and APK facts, build-log artifact,
  pre-release publishing, docs-only pushes skip the build.
- Physical-device testing: **not performed** — `release/ANDROID_FIELD_TEST.md`.

## 1.1.0 (build 2) — 2026-10-03 — field-readiness pass

Every item below was found by running the code (or, for the Flutter app, by
reading it against the backend contract), then fixed, then re-tested. Backend
suite: 69 → **119 tests, all passing**.

### Origin / verdict correctness
- **Fixed:** `derive_is_chinese` turned an explicit "Unknown" country into `NO`
  → 16 unknown-origin records showed **GREEN** on the server (YELLOW offline).
  Now UNKNOWN; repair existing DBs with `python -m app.cli reclassify_unknown`.
- **Fixed:** 104 manufacturer-level ("OEM landscape") records gave GREEN from
  the OEM's home country. Now YELLOW `OEM NON-CHINESE - COMPONENT ORIGIN NOT
  DOCUMENTED`; Chinese OEMs stay RED, labelled as manufacturer-level.
- **Fixed:** approximate identifications (multi-glyph OCR fold, partial prefix,
  fuzzy) could give GREEN. Now YELLOW `IDENTITY UNCERTAIN - REQUIRES MANUAL
  REVIEW`; to a Chinese record, RED `PROBABLE … CONFIRM MARKING`.
- Added to every scan result: `origin_evidence`, `evidence_detail`,
  `review_required`, `policy_decision` (Python, Dart, JS identical).
- Added reel/bag label barcode parsing (ECIA / ANSI MH10.8.2: 1P part number
  looked up; 4L label country shown as a claim only).
- Added JS↔Python parity test over all 203 records × 8 methods × 3 scores.

### OCR (server)
- **Fixed:** Tesseract whitelist lost its space when parsed → multi-word lines
  ("CHN 302", lot codes) came back with confidence 0 and were discarded, so the
  country-of-origin check never saw the COO code.
- **Fixed:** crash `cannot unpack non-iterable numpy.int32` on any rotated photo
  (OpenCV 5 HoughLinesP shape). Deskew replaced by projection-profile skew
  detection; 90/180/270° retries.
- **Fixed:** physical lines rebuilt with spaces for the marking check.
- **Fixed:** two packages in one photo — one chip's CHN line was applied to the
  other chip's verdict. Multi-chip mode now returns one scan per package;
  single mode flags "more than one part number" and does not auto-select.
- Photos are stored as evidence and linked to the confirmed scan (`image_ref`,
  path-traversal-safe). `auto_lookup=false` OCR-only mode.

### Backend / deployment
- **Fixed:** production TrustedHost list hard-coded to localhost → every phone
  on the LAN got `400 Invalid host header`. Now `DCOV_TRUSTED_HOSTS`.
- New `scripts/run_lan_server.sh` / `.ps1`: binds 0.0.0.0, persists
  `DCOV_SECRET_KEY` (restarts no longer sign every device out), prints the URL
  to type into the phone.
- `/auth/refresh` and `/auth/pin` accept JSON bodies (query forms kept; they
  leak credentials into access logs). Warning logged when no secret key is set.
- **Fixed:** `smoke_test.sh` never wrote report files (two `-o` flags) and
  hard-coded `/tmp`.

### Flutter app
- **Fixed:** sessions were treated as signed-out 30 min after sign-in (no
  refresh), after which offline scans were **silently not queued**. Tokens are
  now refreshed; scans queue whenever signed in and are attributed to the
  operator who made them.
- **Fixed:** OCR photo upload sent `application/octet-stream` → server
  rejected it (415). Now `image/jpeg`.
- **Fixed:** photo flow recorded two server scans per photo.
- **Fixed:** "online" meant "has Wi-Fi". Now a `/health` probe every 30 s.
- **Fixed:** offline restart fell back to the bundled seed catalogue; the last
  server catalogue is now cached on the device.
- **Fixed:** one corrupt queued scan made the whole queue unreadable.
- **Fixed:** default server `127.0.0.1` (the phone itself). Now unset, with
  validation and TEST CONNECTION in Settings; login asks for it first.
- Added: ONLINE VERIFIED / OFFLINE — PENDING SYNCHRONISATION / LOCAL ONLY on
  every result; scan ID, operator, timestamp; evidence card (component,
  marking, barcode, manufacturer, origin, evidence, method, confidence,
  policy); server verdict shown when online; repeat-scan notice.
- Added: on-device OCR (Google ML Kit, bundled model, Android/iOS) with
  candidate selection; server OCR as second opinion.
- Added: camera-permission-denied handling for scanner and photo; multiple
  barcodes → chooser; more symbologies; Windows falls back to USB scanner/typing.
- Added: offline queue upload via `/sync/push` (batched, idempotent), SYNC NOW.
- Added: forced password change on first sign-in.
- mobile_scanner 6 → 7 (Apple Vision on iOS, no ML Kit pod conflict).
- Compact app bar for phone widths.

### Build / release
- `.github/workflows/build-apps.yml`: Android release APK (universal +
  per-ABI, checksum, manifest dump, secret scan), Windows release zip, iOS
  no-codesign compile.
- `tool/configure_platforms.py`: permissions, app ID, minSdk 24, signing from
  `key.properties`, R8 rules for ML Kit, icons, iOS plist/15.5 — tested
  against the current Flutter templates.
- `tool/check_apk.py`: secret scan + bundled-data check.
