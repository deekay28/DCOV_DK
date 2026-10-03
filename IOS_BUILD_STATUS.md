# DCOV — iOS Build Status

**No IPA exists and none has been tested.** No macOS/Xcode was available. The
`ios` job in `.github/workflows/build-apps.yml` compiles the app for device on
a GitHub macOS runner *without code signing*; that proves the iOS build
compiles but its output cannot be installed.

## Ready

| Item | State |
|---|---|
| Bundle identifier | `com.dcov.dcovField` (from `flutter create --org com.dcov`); change in Xcode if needed |
| Display name | DCOV (`configure_platforms.py`) |
| Camera permission text | `NSCameraUsageDescription` added |
| Photo library text | `NSPhotoLibraryUsageDescription` added |
| Network | `NSAllowsLocalNetworking` for LAN servers; use HTTPS in production |
| Deployment target | iOS 15.5 (required by google_mlkit_text_recognition) — Podfile and project |
| Plugins | mobile_scanner 7 (Apple Vision — avoids the ML Kit pod conflict mobile_scanner 6 had), google_mlkit_text_recognition, image_picker, flutter_secure_storage (Keychain), shared_preferences, connectivity_plus, vibration, share_plus, file_picker, path_provider — all list iOS support |
| Platform-specific code | none beyond plugins; platform checks use `defaultTargetPlatform` |

## Remaining requirements

1. A Mac with Xcode (current stable) and CocoaPods, or the CI macOS runner.
2. Apple Developer account, signing team and provisioning profile.
3. App icon set (currently Flutter default on iOS).
4. Physical-device run of `FIELD_ACCEPTANCE_TEST.md` sections B–F.

## Exact commands on a Mac

```bash
cd frontend_flutter
flutter create --org com.dcov --project-name dcov_field --platforms=ios .
python3 tool/configure_platforms.py
flutter pub get
flutter build ios --config-only --no-codesign
python3 tool/configure_platforms.py      # sets platform :ios, '15.5' in the generated Podfile
open ios/Runner.xcworkspace              # set Team under Signing & Capabilities
flutter build ipa --release              # -> build/ios/ipa/*.ipa
```

## Known limitations

- ML Kit on iOS does not run on the Simulator for arm64 Macs in some versions — test on a device.
- Untested: everything. Treat as "configured, compiles in CI (once run), not verified".
