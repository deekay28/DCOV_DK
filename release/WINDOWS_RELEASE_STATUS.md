# Windows release status

**Not built or run in the audit environment** (Linux container, no Flutter,
no Windows). The `windows` job of `.github/workflows/build-apps.yml` builds
`flutter build windows --release` on a Windows runner and uploads
**DCOV-Windows-release.zip** (unzip, run `dcov_field.exe`; needs the Microsoft
Visual C++ runtime, present on most PCs).

Local build (Windows + Flutter + Visual Studio "Desktop development with C++"):
```powershell
cd frontend_flutter
flutter config --enable-windows-desktop
flutter create --org com.dcov --project-name dcov_field --platforms=windows .
python tool\configure_platforms.py
flutter build windows --release   # -> build\windows\x64\runner\Release\
```

| Capability on Windows | Expected | Tested |
|---|---|---|
| Sign-in, dashboard, catalogue, history, reports, inspections, import, users | same as Android | No |
| Typed verification, offline catalogue | yes | No |
| Barcode via camera | **no** — mobile_scanner has no Windows camera support; app explains and focuses the input field | No |
| Barcode via USB/Bluetooth scanner | yes — scanners type into the marking field | No |
| Chip photo | picks an image file; server OCR when online; **no on-device OCR** (ML Kit is Android/iOS only) | No |
| Secure token storage | Windows Credential Manager (flutter_secure_storage) | No |

No installer (MSIX) was produced; the zip is the deliverable.
