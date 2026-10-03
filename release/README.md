# release/

| File | State |
|---|---|
| `DCOV-Android-release.apk` | **Not present.** Produced by `.github/workflows/build-apps.yml` (artifact *DCOV-Android-APK*). Could not be built in the audit environment — see `FINAL_SYSTEM_VERIFICATION.md`. |
| `DCOV-Android-release.sha256` | Not present — generated next to the APK by the same workflow step. |
| `ANDROID_INSTALLATION_GUIDE.md` | ready |
| `ANDROID_RELEASE_TEST_REPORT.md` | ready |
| `WINDOWS_RELEASE_STATUS.md` | ready — Windows zip is artifact *DCOV-Windows-release* |
| `IOS_RELEASE_STATUS.md` | ready — no IPA (needs Mac + Apple signing) |
| `FINAL_SYSTEM_VERIFICATION.md` | ready |

When the workflow has run, download its artifacts into this folder to
complete the release set.
