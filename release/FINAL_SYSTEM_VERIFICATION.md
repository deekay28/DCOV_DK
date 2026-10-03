# DCOV — Final System Verification

Date: 2026-10-03. Version 1.1.0 (build 2).

## 1. Overall status

| Component | Status |
|---|---|
| Backend | **VERIFIED** — 119/119 tests pass; live LAN smoke test passes |
| Flutter | **NOT VERIFIED** — code updated; never compiled here (no Flutter SDK reachable). CI compiles + tests it |
| Android | **NOT BUILT** — workflow ready; no APK yet |
| Windows | **NOT BUILT** — workflow ready |
| iOS | **NOT BUILT** — no-codesign compile in workflow; no IPA possible without Apple signing |
| OCR | Server: **PARTIALLY VERIFIED** (real Tesseract, synthetic chip images, 3 bugs fixed). On-device ML Kit: **NOT VERIFIED** (added) |
| Barcode | Matching logic **VERIFIED**; camera decoding **NOT VERIFIED** |
| Database | **VERIFIED** (seed load, import, rollback, catalogue API) — origin bug fixed |
| Origin verification | **VERIFIED** (server + JS parity); Dart port tested in CI only |
| Offline mode | Server sync APIs **VERIFIED**; app queue/status **NOT VERIFIED** on device |
| Reports | **VERIFIED** (server: PDF/XLSX/CSV generated) |
| Audit | **VERIFIED** (hash chain intact after real traffic) |
| Security | Reviewed; findings in §10 |

## 2. Tests executed

```
# environment
python3 --version; java -version; node --version; which flutter dart adb sdkmanager (none)
curl <storage.googleapis.com|dl.google.com|maven.google.com|pypi.org|…>   -> blocked (403 egress policy)
git clone <fastapi, starlette, sqlalchemy, aiosqlite, pydantic-settings, alembic, mako,
           python-jose, ecdsa, rsa, pyasn1, greenlet, pytest, pluggy, iniconfig,
           pytest-asyncio, passlib(libpass), httpx, httpcore>  -> venv /opt/dcovenv
python setup.py build_ext --inplace   (greenlet)

# backend
python -m pytest -q                       (baseline: 69 passed; final: 119 passed)
python -m compileall -q app
python tests-probe: OCR chain on 13 rendered chip images (before/after fixes)
node  tests/js/parity_dump.js  + Python comparison (4 872 verdicts, 13 matches)
scripts/run_lan_server.sh                 (fresh DB, admin, seed, 0.0.0.0:8000)
curl http://<LAN-IP>:8000/health          -> 200
curl -H "Host: evil.example" …/health     -> 400 Invalid host header
scripts/smoke_test.sh http://<LAN-IP>:8000 admin <pw>   -> ALL CHECKS PASSED
python -m app.cli reclassify_unknown      -> 16 records repaired on the pre-fix DB

# build tooling
tool/configure_platforms.py on the current Flutter templates (android-kotlin app/build.gradle.kts,
  AndroidManifest, iOS Info.plist/pbxproj, windows main.cpp) -> patched, idempotent, XML valid
tool/check_apk.py on a synthetic APK (clean -> pass; planted DCOV_SECRET_KEY -> fail)
```

## 3. Tests passed

All 119 backend tests: audit chain (1), auth API (10), catalogue API (10),
engine parity (1), field API (10), importer (12), marking (11), matching (15),
OCR pipeline (16), origin logic (23), scan API (10). Smoke test 10/10.

## 4. Tests failed

None outstanding in what could be run. Failures found and fixed during the
work are listed in `CHANGELOG.md` (each is now covered by a test).
Not run at all: `flutter analyze`, `flutter test`, every build, every device test.

## 5. Known limitations

- The Flutter changes (≈1 500 lines) have not been compiled. The first CI run
  is the first compile; Dart compile errors, if any, will appear there.
- No physical device test; OCR accuracy on real laser-etched chips is unknown.
  Synthetic images are cleaner than real packages.
- Severe glare that saturates glyphs cannot be read by any engine → GREY/manual.
- Catalogue: 203 seed rows, 104 manufacturer-level only (YELLOW by design).
- Barcode camera scanning: Android/iOS only, not Windows.
- On-device OCR: Android/iOS only.
- Debug-key signing unless release secrets are configured.
- Plain HTTP on LAN; HTTPS needed beyond an isolated network.
- Biometric sign-in not wired in the app. Web build not supported with ML Kit/dart:io.

## 6. Android APK

Expected location after the CI run: Actions → *Build apps* → artifact
**DCOV-Android-APK** → `DCOV-Android-release.apk` (+ `.sha256`,
`SHA256SUMS.txt`, `APK_BUILD_INFO.txt`, per-ABI APKs). **No APK exists yet.**

## 7. Installation

See `ANDROID_INSTALLATION_GUIDE.md`: copy APK → allow unknown apps → install
(or `adb install -r`). Android 7.0+.

## 8. Backend requirement

| Question | Answer |
|---|---|
| Works completely offline? | **Partly.** Typed, barcode and on-device-OCR verification against the on-phone catalogue work with no network (labelled LOCAL ONLY / PENDING SYNC). |
| Requires a local backend? | For sign-in, central audit trail, sync, reports, inspections, imports, server OCR. |
| Requires a LAN backend? | For a phone: the backend must be reachable — same Wi-Fi as a PC running `run_lan_server`, or a hosted HTTPS server. |
| Requires internet? | No. LAN only is fine. |
| Configurable server address? | Yes — Settings → Server address, with TEST CONNECTION. No address is built in. |

## 9. Origin verification methodology

See `ORIGIN_VERIFICATION_LOGIC.md`. In short: identity by a 7-step matching
cascade with explicit certain/uncertain methods; origin only from documented
evidence — package COO marking > component-level catalogue record >
manufacturer-only record > none; never from barcode prefixes, brand, language
or packaging. GREEN requires a certain identification **and** component-level
documented non-Chinese origin **and** no contrary marking. Anything weaker is
YELLOW (manual review) or GREY (not found). Policy acceptability comes from
the configured criticality matrix and is shown separately from the banner.

## 10. Security findings

| Finding | State |
|---|---|
| Secrets in APK | None by design (no server address, keys or passwords in the app); enforced by `check_apk.py` in CI |
| Tokens on device | flutter_secure_storage (Keystore/Keychain/Credential Manager) |
| Refresh token / PIN in query strings | Fixed: JSON body supported and used by the app; query form still accepted for old clients — remove after rollout |
| Random secret per restart | Mitigated: warning logged; LAN script persists `DCOV_SECRET_KEY` in git-ignored `backend/.env` (permissions 600) |
| TrustedHost | Now configurable; LAN script restricts to the LAN IP |
| Cleartext HTTP | Allowed in the app for LAN use — use HTTPS for anything internet-facing |
| Logout | Revokes the access token in memory only (lost on restart); refresh tokens are not revoked on logout — residual risk |
| Rate limiting | In-memory per process; resets on restart |
| Bootstrap admin | must_change_password now enforced in the app UI (server does not block API use before the change — residual) |
| Uploaded images | Stored under uploads/scans; `image_ref` accepted only for server-produced paths (traversal test) |
| Dependency audit | `pip-audit` not runnable here (PyPI blocked); CI runs it |
| Screen-lock PIN | stored in secure storage (by design, offline unlock) |
