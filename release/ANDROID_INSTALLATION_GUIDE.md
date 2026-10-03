# Installing DCOV on an Android phone

> The APK is produced by the GitHub Actions build (see `ANDROID_RELEASE_TEST_REPORT.md`).
> It was **not** present when this folder was assembled.

## 1. Get the APK

GitHub → your repo → **Actions** → *Build apps* → latest green run →
**Artifacts → DCOV-Android-APK** (zip). Inside: `DCOV-Android-release.apk`
and `DCOV-Android-release.sha256`. Optional check on a PC:
`certutil -hashfile DCOV-Android-release.apk SHA256` (Windows) or
`sha256sum DCOV-Android-release.apk` — must equal the `.sha256` file.

## 2. Install

**On the phone:** copy the APK (USB, Drive, WhatsApp-as-document, email) →
tap it → allow *Install unknown apps* for the app you opened it with → Install.
If Play Protect warns "unknown developer", choose *Install anyway* (the app is
not on Play). If an older DCOV with a different signature is installed,
uninstall it first.

**From a PC with adb:** enable Developer options → USB debugging, then
`adb install -r DCOV-Android-release.apk`.

Requires Android 7.0 or newer. ~90 % of phones use the arm64 build; the
universal APK works on all.

## 3. Start the server (for sign-in, sync, reports, server OCR)

On a Windows PC on the **same Wi-Fi**: install Python 3.12+, unzip the project,
then in PowerShell from the project folder:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\run_lan_server.ps1
```
First run prints the **admin password once** and the address to use, e.g.
`http://192.168.1.20:8000`. Allow Python through Windows Defender Firewall
(Private networks). Linux/macOS: `./scripts/run_lan_server.sh`.
Check from the phone's browser: `http://<that-address>/health` shows `"status":"ok"`.

## 4. Configure the app

DCOV → ⚙ Settings → Server address → `http://<PC-LAN-IP>:8000` → **TEST
CONNECTION** → SAVE → sign in (`admin` + printed password; you will be asked
to set a new one). Create inspector accounts under Users.

Without a server the app still verifies typed, scanned and photographed
markings against its built-in catalogue — results show **LOCAL ONLY**.

## 5. Share with another tester

Send them the same APK file. They need their own account on your server (or
use it offline). Remind them: results are screening evidence for a trained
inspector, not a clearance.

## Troubleshooting

| Symptom | Fix |
|---|---|
| "App not installed" | uninstall older DCOV (signature mismatch); free storage |
| TEST CONNECTION fails | same Wi-Fi? firewall? server window still open? guest Wi-Fi often blocks device-to-device traffic |
| "Invalid host header" | start the server with `run_lan_server` (sets trusted hosts) |
| Camera black / "permission denied" | Settings → Apps → DCOV → Permissions → Camera → Allow |
| Signed out unexpectedly | server restarted without `backend/.env` secret — use `run_lan_server`; queued scans are kept |
