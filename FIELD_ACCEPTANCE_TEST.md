# DCOV — Field Acceptance Test (physical Android phone)

Fill in **PASS / FAIL** and evidence (screenshot name, scan ID, note) for every
row. A row without evidence counts as FAIL. Rows marked *(server)* need the
backend running on a PC on the same Wi-Fi (`scripts/run_lan_server.ps1` on
Windows, `scripts/run_lan_server.sh` on Linux/macOS).

Tester: ____________  Phone model / Android version: ____________  Date: ________
APK file + SHA-256 (first 12 chars): ____________  Server address: ____________

Status as delivered: **no row has been executed yet** — no phone was
available to the build environment. Automated server-side equivalents that
did run are listed in `release/ANDROID_RELEASE_TEST_REPORT.md`.

## A. Install and first run

| # | Step | Expected | PASS/FAIL | Evidence |
|---|---|---|---|---|
| A1 | Install `DCOV-Android-release.apk` (allow "install unknown apps") | installs, icon "DCOV" | | |
| A2 | Launch | dashboard/verify screen, no crash | | |
| A3 | Settings → Server address `http://<PC-LAN-IP>:8000` → TEST CONNECTION *(server)* | "OK - DCOV … components" | | |
| A4 | Sign in with admin + one-time password *(server)* | asked to set new password; then signed in | | |
| A5 | App bar | shows ONLINE | | |

## B. Barcode / QR

| # | Step | Expected | PASS/FAIL | Evidence |
|---|---|---|---|---|
| B1 | SCAN CODE → first time | camera permission prompt | | |
| B2 | Deny permission | explanation screen, no crash, BACK works | | |
| B3 | Re-allow in Settings → SCAN CODE | camera preview | | |
| B4 | Scan a DCOV label QR (print one from the catalogue, `DCOV:<id>:<part>`) | match `exact_code`, correct verdict | | |
| B5 | Scan an EAN-13 DCOV label | match `exact_code` | | |
| B6 | Scan a real reel label DataMatrix (Digi-Key/Mouser/LCSC) | method `label_mpn`; 4L shown as label claim | | |
| B7 | Scan an unknown retail barcode | GREY NOT FOUND, no crash | | |
| B8 | Two codes in view | chooser list appears | | |
| B9 | Same code twice within 10 min | second result says "Repeat scan" | | |
| B10 | Low light → torch button | torch toggles | | |
| B11 | Angled / small / damaged code | reads or user can type; no crash | | |

## C. Photo + OCR

| # | Step | Expected | PASS/FAIL | Evidence |
|---|---|---|---|---|
| C1 | PHOTOGRAPH CHIP → permission prompt (first time) | prompt; deny → dialog with "PICK A PHOTO" | | |
| C2 | Photo of a known Chinese-origin IC (e.g. STM32F302C8T6 marked CHN) **airplane mode** | on-device OCR candidates appear; verdict RED; status OFFLINE — PENDING | | |
| C3 | Photo of a known non-Chinese IC with COO line (e.g. MX25L12833F / TWN) | GREEN, evidence "Documented for this component" | | |
| C4 | Rotated 90° photo | still read | | |
| C5 | Blurry photo | candidates wrong/empty → user corrects; never auto-GREEN | | |
| C6 | Glare across marking | warning or no candidates; manual entry works | | |
| C7 | Two chips in one photo | "different part numbers" warning; no pre-fill | | |
| C8 | Online: SECOND OPINION: SERVER OCR *(server)* | server candidates appear | | |
| C9 | Verify after server OCR *(server)* | one scan in server history, with image (Reports/History) | | |

## D. Results and evidence

| # | Step | Expected | PASS/FAIL | Evidence |
|---|---|---|---|---|
| D1 | Type `STM32F302C8T6` | RED, policy NOT ACCEPTABLE…, escalate | | |
| D2 | Type `ADF4350` | GREEN, review "Not required" | | |
| D3 | Type `MX2SLI2833F` (OCR-style misread) | YELLOW IDENTITY UNCERTAIN | | |
| D4 | Type `Doodle Labs` | YELLOW OEM NON-CHINESE – ORIGIN NOT DOCUMENTED | | |
| D5 | Type `SN74LVC1G08` | GREY NOT FOUND | | |
| D6 | Type `ADF4350` + other line `CHN 2219` | RED CHINESE ORIGIN MARKED ON PACKAGE | | |
| D7 | Every result shows component, marking, barcode, manufacturer, origin, confidence, evidence, method, policy, time, operator, scan ID | all present | | |

## E. Offline and sync

| # | Step | Expected | PASS/FAIL | Evidence |
|---|---|---|---|---|
| E1 | Signed in, airplane mode, verify 3 parts | OFFLINE — PENDING; app bar "3 PENDING" | | |
| E2 | Stop the server, Wi-Fi on, verify 1 part | PENDING (server unreachable), no crash | | |
| E3 | Restart server, wait ≤ 30 s | pending → 0; notification "synchronised"; history shows SERVER | | |
| E4 | Server History *(server)* | the 4 scans appear once each, with original capture times | | |
| E5 | Settings → SYNC NOW twice | no duplicates on server | | |
| E6 | Force-close app offline, reopen | catalogue still the last synced one (Settings: "Last server sync (cached)") | | |
| E7 | Leave signed in > 30 min, verify online | still ONLINE VERIFIED (token refreshed) | | |

## F. Robustness

| # | Step | Expected | PASS/FAIL | Evidence |
|---|---|---|---|---|
| F1 | Back button from scanner / sheet / settings | returns, no crash | | |
| F2 | Rotate screen on Verify and result | layout OK | | |
| F3 | Invalid server address `abc` | "not a valid address" | | |
| F4 | Reports → PDF *(server)* | file opens/share sheet | | |
| F5 | Sign out → sign in | works; pending scans of other users not uploaded under you | | |
| F6 | `adb logcat -s flutter` during the run | no uncaught exceptions | | |

Result: ____ / ____ rows PASS. Signed: ______________________
