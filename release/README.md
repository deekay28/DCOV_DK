# release/

| File | State |
|---|---|
| `DCOV-Android-release.apk` | **Built** (CI run #11). Not stored in git (102 MB > GitHub's 100 MB file limit) — download from the pre-release: https://github.com/deekay28/DCOV_DK/releases/tag/android-v1.1.0-build2-run11 (also per-ABI APKs) |
| `DCOV-Android-release.sha256` | SHA-256 of that APK (`ffc63130…8200ebf`) |
| `SHA256SUMS.txt` | SHA-256 of all four APKs in the release |
| `APK_BUILD_INFO.txt` | CI `aapt2` facts + independent re-verification of the downloaded APK |
| `ANDROID_INSTALLATION_GUIDE.md` | how to download, check, install, connect to the server |
| `ANDROID_FIELD_TEST.md` | physical-device checklist — **not yet performed** |
| `FINAL_ANDROID_TEST_REPORT.md` | Phase 2 status report (build PASS; device tests NOT PERFORMED) |
| `ANDROID_RELEASE_TEST_REPORT.md` | superseded by `FINAL_ANDROID_TEST_REPORT.md` (pre-build state) |
| `WINDOWS_RELEASE_STATUS.md` | Windows zip: artifact *DCOV-Windows-release* (built in CI) |
| `IOS_RELEASE_STATUS.md` | no IPA (needs Mac + Apple signing); unsigned compile check passes in CI |
| `FINAL_SYSTEM_VERIFICATION.md` | Phase 1 whole-system verification |
