# DCOV Android — physical-device field test

**Status: NOT YET PERFORMED.** No phone was reachable from the build
environment. Every row below is open until someone runs it on a real device
and fills in the *Result* column. Do not mark a row PASS from reading code.

APK under test: `DCOV-Android-release.apk`, release
`android-v1.1.0-build2-run11`, SHA-256
`ffc6313080a9ae71d730a7f8c026348c1e31b808035a0e651a22a67cb8200ebf`.

## 0. Record the setup

| Item | Value |
|---|---|
| Phone model / Android version | |
| APK file + SHA-256 checked? | |
| Server address used | `http://<PC-LAN-IP>:8000` |
| Tester / date | |

Optional, from a PC with USB debugging on (keep it running the whole test):

```
adb devices                                   # phone must show "device"
adb install -r DCOV-Android-release.apk
adb logcat -c
adb logcat -v time | findstr /i "dcov flutter AndroidRuntime mlkit camera FATAL"   # Windows
adb logcat -v time | grep -iE "dcov|flutter|AndroidRuntime|mlkit|camera|FATAL"      # Linux/macOS
```

Any `FATAL EXCEPTION` or `AndroidRuntime` crash = **FAIL** for the row being tested — save the log.

Result codes: **PASS** / **FAIL** (+ what happened) / **N/A** (+ why).

## 1. Launch, server, sign-in (Steps 6, 13.1–13.6)

Note: the app words the result as "OK - DCOV … answering" / "No answer from …", not the literal
labels CONNECTED / CONNECTION FAILED requested in the Phase 2 brief. Changing the wording
is queued with the first batch of field-test fixes.

| # | Do | Expect | Result |
|---|---|---|---|
| 1.1 | Fresh install, open DCOV | Opens to sign-in / dashboard, no crash | |
| 1.2 | Settings → Server address: `127.0.0.1:8000` → TEST CONNECTION | Failure message "No answer from http://127.0.0.1:8000 … (reason)" — the phone itself is not the server | |
| 1.3 | Server address: `http://<PC-LAN-IP>:8000` → TEST CONNECTION | Success message "OK - DCOV <version> answering, N components in its catalogue" (server running via `scripts/run_lan_server`) | |
| 1.4 | Stop the server → TEST CONNECTION | "No answer from …" with hints (same Wi-Fi? firewall?) and the error; no crash | |
| 1.5 | Wrong format, e.g. `abc` → SAVE | "not a valid address" message | |
| 1.6 | Restart server, SAVE, sign in as `admin` | Forced password change, then dashboard | |
| 1.7 | Dashboard → Settings → back | Screens open, back button works | |

## 2. Camera permission (Step 7)

Reset between rows: Settings → Apps → DCOV → Permissions → Camera.

| # | State | Do | Expect | Result |
|---|---|---|---|---|
| 2.1 | Never asked | Verify → SCAN CODE | System prompt appears; **Allow** → live preview | |
| 2.2 | Denied once | Verify → SCAN CODE → **Don't allow** | "Camera permission denied" screen with BACK; no crash, no black screen | |
| 2.3 | Denied permanently ("Don't ask again" / denied twice) | SCAN CODE | Same explanatory screen, mentions Settings; no crash | |
| 2.4 | Allowed after denying | Enable in Android Settings → return → SCAN CODE | Preview works | |
| 2.5 | Camera busy | Open another camera app first (or a phone with camera covered by a video call) → SCAN CODE | "Camera not available (…)" + RETRY; no crash | |
| 2.6 | Photo path, permission denied | Verify → PHOTO with camera denied | Falls back to gallery picker or explains; no crash | |

## 3. Barcode camera scanning (Step 8) — critical

Use real labels: an EAN-13 product barcode, a Code-128 reel/bag label, a QR code
containing a part number. Note which part numbers are in the catalogue.

| # | Do | Expect | Result |
|---|---|---|---|
| 3.1 | Verify → SCAN CODE → point at Code-128 with a catalogued part number | Scanner closes by itself, value shown, component identified | |
| 3.2 | Continue to result | Manufacturer, database origin, **origin evidence**, match method, confidence, **policy result** shown | |
| 3.3 | Check History | The scan is listed with time + status | |
| 3.4 | Signed in & online: check the server (Reports or web) | Same scan recorded (audit record) | |
| 3.5 | Reel label with several codes in view | "Several codes detected — choose" list; picking one verifies it | |
| 3.6 | EAN-13 retail barcode | GS1 prefix is **not** used as origin; unknown part → ORIGIN UNKNOWN / not found, not a country guess | |
| 3.7 | Torch button | Torch toggles | |
| 3.8 | Small / damaged barcode | Either decodes or keeps scanning; BACK works; no crash | |

## 4. Photo capture + OCR (Step 9)

| # | Condition | Do | Expect | Result |
|---|---|---|---|---|
| 4.1 | Normal light, clear marking | Verify → PHOTO → take photo → preview | OCR lines appear, best candidate pre-filled, inspector can correct | |
| 4.2 | → confirm marking | | Database match → origin → verdict screen | |
| 4.3 | Low light | same | Result or clear "could not read" + manual entry; no crash | |
| 4.4 | Rotated chip (90°/180°/~30°) | same | Reads or falls back to manual; no crash | |
| 4.5 | Small text (0402/SOT-23 parts) | same | as above | |
| 4.6 | Several chips in one photo | same | Several candidates; not auto-merged into one verdict | |
| 4.7 | Blurry | same | Low/no candidates → manual entry; no crash | |
| 4.8 | Glare | same | as above | |
| 4.9 | Pick from gallery instead | same | Works | |

## 5. On-device OCR without network (Step 10)

The APK **contains** the ML Kit Latin text-recognition models and native library
(verified by inspecting the APK — see `APK_BUILD_INFO.txt`), so OCR *should* run
locally. That is only a claim until 5.1–5.3 are done.

| # | Do | Expect | Result |
|---|---|---|---|
| 5.1 | **Airplane mode ON** (Wi-Fi off too) → Verify → PHOTO of a clear marking | Text appears; source shown as **on-device OCR** | |
| 5.2 | → confirm | Verdict from built-in catalogue, marked **LOCAL ONLY** or **OFFLINE — PENDING SYNC** | |
| 5.3 | Airplane mode, photo of a blank surface | "no text" style message → manual entry; no crash | |
| 5.4 | Online but server stopped → PHOTO | On-device OCR still works; "SECOND OPINION: SERVER OCR" explains it needs the server | |
| 5.5 | Online + signed in → SERVER OCR | Server result shown alongside | |

## 6. Origin verification (Step 11)

Pick catalogue entries of each kind (Catalogue screen shows them).

| # | Case | Expect | Result |
|---|---|---|---|
| 6.1 | Exact part, documented Chinese origin | RED per policy, evidence = database record, exact match | |
| 6.2 | Exact part, documented non-Chinese origin | GREEN, evidence shown | |
| 6.3 | Manufacturer-level record only | YELLOW "component origin not documented" — **not** GREEN from OEM home country | |
| 6.4 | Unknown origin in database | ORIGIN UNKNOWN / REQUIRES MANUAL REVIEW | |
| 6.5 | OCR-corrected / fuzzy match | YELLOW "identity uncertain — requires manual review" | |
| 6.6 | Part not in catalogue | Not found — no country inferred from barcode prefix, language or packaging | |

## 7. Offline mode + synchronisation (Steps 12, 13.14–13.15)

| # | Do | Expect | Result |
|---|---|---|---|
| 7.1 | Signed in, online: note History count | | |
| 7.2 | Airplane mode → kill app → relaunch | Opens; session/offline mode recovered; catalogue available | |
| 7.3 | Verify 3 parts (typed, barcode, photo) | Each marked **OFFLINE — PENDING SYNCHRONISATION** (or LOCAL ONLY if never signed in) | |
| 7.4 | Airplane mode OFF | "Offline scans synchronised: 3" notification; History rows become online-verified | |
| 7.5 | On the server: count those scans | Exactly 3 new — **no duplicates, none lost** | |
| 7.6 | Toggle network off/on twice more | Still exactly 3 (idempotent replay) | |
| 7.7 | Server audit log | Entries present; audit chain verifies | |

## 8. Lifecycle (Steps 13.16–13.17)

| # | Do | Expect | Result |
|---|---|---|---|
| 8.1 | Rotate the phone on Verify and on a result | No crash, state kept | |
| 8.2 | Home button → reopen after 1 min | Same screen | |
| 8.3 | Force-stop → reopen | Still signed in (or offline session), History intact | |
| 8.4 | Logout | Back to sign-in; queued scans of this user kept until they sign in again | |
| 8.5 | Look through the logcat capture | No FATAL / uncaught exceptions | |

## 9. Summary (fill in)

| Area | VERIFIED / NOT VERIFIED / FAIL |
|---|---|
| Camera + permissions (§2) | |
| Barcode camera (§3) | |
| Photo capture (§4) | |
| On-device OCR, airplane mode (§5) | |
| Origin verification on device (§6) | |
| Offline mode (§7.1–7.3) | |
| Synchronisation (§7.4–7.7) | |
| Lifecycle / crashes (§8) | |

Send back: this file filled in, the logcat capture, and photos of any failing
screen. Every FAIL becomes a fix and a new CI build.
