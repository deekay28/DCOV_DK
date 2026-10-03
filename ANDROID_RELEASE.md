# DCOV — Android Release

| Item | Value |
|---|---|
| APK filename | `DCOV-Android-release.apk` (universal) + `app-arm64-v8a-release.apk`, `app-armeabi-v7a-release.apk`, `app-x86_64-release.apk` |
| Application ID | `com.dcov.field` |
| Version / build number | 1.1.0 / 2 (from `frontend_flutter/pubspec.yaml`) |
| Minimum Android | 7.0 (API 24) — `max(24, flutter.minSdkVersion)` |
| Target Android | Flutter stable default (API 35/36 at time of writing); exact value printed in `APK_BUILD_INFO.txt` |
| SHA-256 | in `DCOV-Android-release.sha256` produced by the build — **not available yet: the APK has not been built** (see below) |
| Built by | `.github/workflows/build-apps.yml`, job `android` |

## Status

**Not built in the audit environment** — the Flutter SDK, Android SDK and
Maven repositories were unreachable there. The workflow builds it on GitHub:
push the project to a GitHub repo → Actions → *Build apps* → artifact
**DCOV-Android-APK** containing the APKs, `SHA256SUMS.txt`,
`DCOV-Android-release.sha256` and `APK_BUILD_INFO.txt` (package, SDK levels,
permissions, ABIs, secret-scan result).

Or locally (Windows/macOS/Linux with Flutter + Android Studio):

```bash
cd frontend_flutter
flutter create --org com.dcov --project-name dcov_field --platforms=android .
python tool/configure_platforms.py
flutter pub get && flutter analyze && flutter test
flutter build apk --release                 # universal: build/app/outputs/flutter-apk/app-release.apk
flutter build apk --release --split-per-abi # smaller per-CPU APKs
python tool/check_apk.py build/app/outputs/flutter-apk/app-release.apk
```

Universal vs split: the universal APK contains native code for all CPU types
(larger, installs on any phone — use this to share). Split APKs are ~⅓ the
size each; nearly every current phone needs `arm64-v8a`.

## Signing

Without secrets the release APK is signed with the **debug key**: it installs
and runs normally — fine for field testing and sharing — but cannot go on Play,
and a later build signed with a different key cannot update it (uninstall
first). For a real release key:

```bash
keytool -genkeypair -v -keystore dcov-release.jks -alias dcov -keyalg RSA -keysize 4096 -validity 9125
base64 -w0 dcov-release.jks   # -> ANDROID_KEYSTORE_BASE64 repository secret
```
Add repository secrets `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`,
`ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`. Locally: create
`frontend_flutter/android/key.properties` (storeFile/storePassword/keyAlias/keyPassword).
`key.properties` and `*.jks` are git-ignored. Keep the keystore and its
passwords outside the repository and backed up — losing it means users must
uninstall to upgrade.

## Backend configuration requirement

The APK contains **no server address and no secrets**. On first use:
Settings → Server address →

| Where the app runs | Address |
|---|---|
| Physical phone, server on a PC on the same Wi-Fi | `http://<PC-LAN-IP>:8000` (printed by `scripts/run_lan_server.ps1` / `.sh`) |
| Android emulator, server on the same PC | `http://10.0.2.2:8000` |
| Production | `https://<your-domain>` (deploy/Caddyfile) |

Never `127.0.0.1`/`localhost` on a phone — that is the phone itself.
Use TEST CONNECTION before signing in.

## What works without the server

Typed markings, barcode/QR scanning and on-device OCR (ML Kit, bundled Latin
model) are verified against the catalogue on the phone — the bundled 203-row
seed, or the last catalogue synced from the server. Results are labelled
OFFLINE — PENDING SYNCHRONISATION (signed in) or LOCAL ONLY (not signed in).
Server OCR, reports, inspections, user admin, imports and the central audit
trail need the server.

## Permissions

CAMERA (scan/photograph), INTERNET + ACCESS_NETWORK_STATE (server), VIBRATE
(RED alert). Camera hardware is declared optional. No storage permission is
requested (photos come from the camera intent / system picker).
Cleartext HTTP is enabled for LAN servers; use HTTPS in production.

## Known limitations

- Not yet run on a physical phone — complete `FIELD_ACCEPTANCE_TEST.md`.
- Debug-key signing unless release secrets are configured.
- iOS icon is the Flutter default; Android/Windows use the DCOV icon.
- Biometric sign-in not implemented in the app (server supports it).
