# DCOV — Final Android test report (Phase 2)

Date: 2026-10-04 · Version 1.1.0 (build 2) · Commit `deeaff2` · CI run #11

## 1. Android build

| | |
|---|---|
| BUILD | **PASS** (CI run #11, all three jobs green) |
| APK | `DCOV-Android-release.apk` — https://github.com/deekay28/DCOV_DK/releases/tag/android-v1.1.0-build2-run11 |
| APK SIZE | 101,873,461 bytes (97.2 MiB); per-ABI: arm64-v8a 39,039,519 · armeabi-v7a 30,633,107 · x86_64 42,021,399 |
| SHA256 | `ffc6313080a9ae71d730a7f8c026348c1e31b808035a0e651a22a67cb8200ebf` (re-computed after download — matches) |
| VERSION / BUILD NUMBER | 1.1.0 / 2 |
| Package | `com.dcov.field` |
| min / target / compile SDK | 24 / 36 / 36 |
| Release / debug | Release build, **not debuggable**; signed with the CI **debug key** (no release keystore secrets configured) |
| Toolchain | Flutter 3.41.9 (pinned), AGP 8.11.1, Kotlin 2.2.20, JDK 17 |

Not committed to `release/`: the APK files themselves. The universal APK
(102 MB) exceeds GitHub's 100 MB per-file limit and the 25 MB web-upload
limit, so the APKs are published as GitHub pre-release assets instead;
`release/` holds their checksums and build info.

## 2. How the build was made to work (Steps 2–4)

| Run | Result | Root cause → fix |
|---|---|---|
| #1 | fail | workflow added before `frontend_flutter/pubspec.yaml` was uploaded |
| #2 | Android fail (analyze, tests, Windows, iOS pass) | Flutter 3.47 template = AGP 9 with `builtInKotlin=false`; `google_mlkit_text_recognition` 0.17+ requires built-in Kotlin while `file_picker` 10 / `share_plus` 12 still apply `kotlin-android` — no setting satisfies both. **Fix:** pin Flutter 3.41.9 (AGP 8.11.1 + KGP 2.2.20), cap ML Kit `<0.17`. Root cause inferred from plugin/template sources (logs need sign-in); confirmed by the next run building. |
| #5 | invalid workflow | my YAML error (`${{ }}` inside a flow mapping) — fixed, now linted with actionlint |
| #6 | APK built, "Inspect APKs" failed | universal APK copied after the per-ABI build reused the output folder → now stashed immediately |
| #8 | pass, but scan flagged 4 APKs | false positive: Apache Tika's `tika-mimetypes.xml` (via `file_picker`) contains the *text* `-----BEGIN PRIVATE KEY-----` as a file-type rule. Scanner now requires a real PEM body; still catches real plain/encrypted/PKCS#8 keys (tested). Also fixed: scan step did not fail the job on a hit (missing `pipefail`). |
| #10, #11 | **pass** | #11 also publishes the pre-release and reports min SDK / debuggable |

The workflow now also: posts Gradle/R8 root causes and APK facts as public
run annotations, uploads build logs, skips CI for docs-only pushes.

## 3. APK verification (Step 5)

Independently re-checked outside CI from the downloaded release (custom
binary-manifest and signing-block decoder; see `APK_BUILD_INFO.txt`):
file exists, size, SHA-256, package, version, version code, min/target SDK,
permissions (CAMERA, INTERNET, ACCESS_NETWORK_STATE, VIBRATE), camera feature
not required, no `debuggable`, v2 signature with `CN=Android Debug`.

Secrets: CI scanner clean on all 4 APKs; manual search of compiled Dart
(`libapp.so`), dex and bundled assets for private keys, JWTs, API keys,
tokens, password assignments and DB URLs — **none found**.

## 4. Server configuration (Step 6)

The saved server address defaults to **empty**; nothing points at
`127.0.0.1`/`localhost`. The only addresses in the binary are hint text
(`http://192.168.1.20:8000`, `http://10.0.2.2:8000` for the emulator). Settings
has SERVER ADDRESS + **TEST CONNECTION** (probes `/health` without saving)
and warns that 127.0.0.1 is the phone itself. The result reads "OK - DCOV …
answering, N components" or "No answer from <url> … (error)" — equivalent in
meaning but **not** the literal words CONNECTED / CONNECTION FAILED from the
brief; that wording change is queued with the first field-test fixes.
On-device check: field test §1.

## 5. What the code does vs. what is proven

| Step | In the APK (verified by build/inspection) | Proven on a phone? |
|---|---|---|
| 7 Camera permission | CAMERA declared, camera not required; scanner shows "permission denied" / "camera not available" + RETRY instead of crashing | **No** — field test §2 |
| 8 Barcode camera | mobile_scanner 7 + bundled ML Kit barcode (`libbarhopper_v3.so`, models) compiled in; 12 symbologies; multi-code chooser | **No** — §3 |
| 9 Photo → OCR | image_picker (camera/gallery, 2400 px) → on-device OCR → inspector confirms → match → verdict | **No** — §4 |
| 10 On-device OCR | ML Kit Latin recogniser **bundled** (native lib + 24 model files) → designed to run with no network; server OCR is an optional second opinion | **No** — airplane-mode test §5 not done; "offline OCR" is **not** claimed as demonstrated |
| 11 Origin | evidence hierarchy in matching engine; no origin from barcode prefix / OEM home country / appearance; RED/YELLOW/GREEN/UNKNOWN with evidence shown | Logic: **yes** (automated tests). On device: §6 |
| 12 Offline + sync | verdict on device, queued with `client_uuid`, labelled OFFLINE — PENDING SYNCHRONISATION / LOCAL ONLY; `/sync/push` idempotent | Server side: **yes** (tests). Device: §7 |
| 13 Device run + logcat | — | **Not performed** — no device |

## 6. Final status (Step 16)

```
ANDROID BUILD
BUILD:                PASS
APK:                  DCOV-Android-release.apk  (GitHub pre-release android-v1.1.0-build2-run11)
APK SIZE:             101,873,461 bytes (97.2 MiB)
SHA256:               ffc6313080a9ae71d730a7f8c026348c1e31b808035a0e651a22a67cb8200ebf
VERSION:              1.1.0
BUILD NUMBER:         2

AUTOMATED TESTS
Flutter analyze:      PASS   (CI run #11; errors fatal, warnings reported)
Flutter tests:        PASS   (CI run #11)
Backend:              PASS   (119/119 — previous session; not re-run in this one)
Android compilation:  PASS

FUNCTIONAL TESTING
Camera:               NOT VERIFIED
Barcode camera:       NOT VERIFIED
Photo capture:        NOT VERIFIED
OCR:                  NOT VERIFIED   (server OCR tested on synthetic images only, previous session)
On-device OCR:        NOT VERIFIED   (ML Kit confirmed bundled in the APK; not run on a device)
Database matching:    VERIFIED       (automated: backend + Flutter tests)
Origin verification:  VERIFIED       (automated logic tests; not on device)
Offline mode:         NOT VERIFIED
Synchronisation:      NOT VERIFIED   (server sync API tested; device queue not)

PHYSICAL DEVICE
Physical Android:     NOT AVAILABLE — PHYSICAL DEVICE TEST: NOT PERFORMED
```

## 7. Next

1. Install the APK and run `ANDROID_FIELD_TEST.md`; send back results + logcat.
   First fix batch already queued: TEST CONNECTION wording → CONNECTED / CONNECTION FAILED.
2. Add the `ANDROID_KEYSTORE_*` secrets so builds share one signing key
   (installs can then update in place).
3. Move off Flutter 3.41.9 once `file_picker` and `share_plus` support AGP 9.
4. Update `actions/checkout`, `setup-java`, `upload-artifact` to Node-24
   versions before GitHub removes Node 20 (warnings only today).
