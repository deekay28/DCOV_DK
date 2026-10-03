#!/usr/bin/env python3
"""Apply DCOV's platform configuration on top of `flutter create`.

The repo does not commit android/, ios/ or windows/ (they are regenerated per
Flutter version). Run, from frontend_flutter/:

    flutter create --org com.dcov --project-name dcov_field \
        --platforms=android,ios,windows .
    python3 tool/configure_platforms.py

Idempotent. Fails loudly (exit 1) if a file it must patch does not look the
way it expects, so a Flutter template change is caught in CI instead of
silently producing an APK without camera permission.

What it sets, and why:
  Android  applicationId com.dcov.field; label "DCOV"; minSdk >= 24
           (mobile_scanner 7 needs 23, ML Kit text 21); CAMERA / INTERNET /
           ACCESS_NETWORK_STATE / VIBRATE permissions; camera feature not
           required (tablets without camera can still install); IMAGE_CAPTURE
           <queries> entry (Android 11+ package visibility for image_picker);
           cleartext HTTP allowed (a field LAN server is usually http://<LAN-IP>
           - see docs/ANDROID_RELEASE.md, use https in production);
           R8 keep/dontwarn rules for ML Kit; release signing from
           android/key.properties when present, else the debug key (clearly
           reported by the build); DCOV launcher icon.
  iOS      camera + photo-library usage strings; display name "DCOV";
           NSAllowsLocalNetworking for LAN http; deployment target 15.5
           (google_mlkit_text_recognition requirement).
  Windows  window title "DCOV"; DCOV icon.
"""
from __future__ import annotations

import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BRAND = ROOT / "tool" / "branding"
APP_ID = "com.dcov.field"
MIN_SDK = 24
errors: list[str] = []


def need(cond: bool, msg: str) -> None:
    if not cond:
        errors.append(msg)


def patch(path: Path, fn) -> None:
    if not path.exists():
        errors.append(f"missing {path.relative_to(ROOT)} - run `flutter create` first")
        return
    old = path.read_text(encoding="utf-8")
    new = fn(old)
    if new != old:
        path.write_text(new, encoding="utf-8")
        print(f"  patched {path.relative_to(ROOT)}")


# --------------------------------------------------------------------------- #
# Android
# --------------------------------------------------------------------------- #
PERMS = ["android.permission.CAMERA", "android.permission.INTERNET",
         "android.permission.ACCESS_NETWORK_STATE", "android.permission.VIBRATE"]


def manifest(s: str) -> str:
    for p in PERMS:
        if p not in s:
            s = s.replace("<application", f'<uses-permission android:name="{p}"/>\n    <application', 1)
    if "android.hardware.camera" not in s:
        s = s.replace("<application", '<uses-feature android:name="android.hardware.camera" '
                                       'android:required="false"/>\n    <application', 1)
    s = re.sub(r'android:label="[^"]*"', 'android:label="DCOV"', s, count=1)
    if "networkSecurityConfig" not in s:
        s = s.replace("<application", '<application\n        android:networkSecurityConfig='
                                       '"@xml/network_security_config"\n        '
                                       'android:usesCleartextTraffic="true"', 1)
    if "android.media.action.IMAGE_CAPTURE" not in s:
        if "<queries>" in s:
            s = s.replace("<queries>", "<queries>\n        <intent>\n            <action android:name="
                                       '"android.media.action.IMAGE_CAPTURE"/>\n        </intent>', 1)
        else:
            s = s.replace("</manifest>", "    <queries>\n        <intent>\n            <action android:name="
                                         '"android.media.action.IMAGE_CAPTURE"/>\n        </intent>\n'
                                         "    </queries>\n</manifest>", 1)
    need('android.permission.CAMERA' in s and 'android:label="DCOV"' in s, "manifest patch failed")
    return s


KTS_HEADER = '''import java.io.FileInputStream
import java.util.Properties
'''
KTS_PROPS = '''
// DCOV: release signing from android/key.properties (never committed - see
// docs/ANDROID_RELEASE.md). Absent => the release build is signed with the
// debug key, which installs fine for testing but cannot be published.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {'''
KTS_SIGNING = '''
    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {'''


def gradle_kts(s: str) -> str:
    if "keystorePropertiesFile" in s:
        return s
    s = KTS_HEADER + s
    s = s.replace("\nandroid {", KTS_PROPS, 1)
    s = re.sub(r'applicationId\s*=\s*"[^"]*"', f'applicationId = "{APP_ID}"', s, count=1)
    s = re.sub(r"minSdk\s*=\s*flutter\.minSdkVersion",
               f"minSdk = maxOf({MIN_SDK}, flutter.minSdkVersion)", s, count=1)
    s = s.replace("\n    buildTypes {", KTS_SIGNING, 1)
    s = re.sub(r'signingConfig\s*=\s*signingConfigs\.getByName\("debug"\)',
               'signingConfig = if (keystorePropertiesFile.exists()) '
               'signingConfigs.getByName("release") else signingConfigs.getByName("debug")', s, count=1)
    need(APP_ID in s and "maxOf(" in s and 'getByName("release")' in s,
         "build.gradle.kts patch incomplete (template changed?)")
    return s


GROOVY_PROPS = '''
// DCOV: release signing from android/key.properties (see docs/ANDROID_RELEASE.md)
def keystoreProperties = new Properties()
def keystorePropertiesFile = rootProject.file('key.properties')
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(new FileInputStream(keystorePropertiesFile))
}

android {'''
GROOVY_SIGNING = '''
    signingConfigs {
        release {
            if (keystorePropertiesFile.exists()) {
                keyAlias keystoreProperties['keyAlias']
                keyPassword keystoreProperties['keyPassword']
                storeFile file(keystoreProperties['storeFile'])
                storePassword keystoreProperties['storePassword']
            }
        }
    }

    buildTypes {'''


def gradle_groovy(s: str) -> str:
    if "keystorePropertiesFile" in s:
        return s
    s = s.replace("\nandroid {", GROOVY_PROPS, 1)
    s = re.sub(r'applicationId\s*=?\s*"[^"]*"', f'applicationId = "{APP_ID}"', s, count=1)
    s = re.sub(r"minSdk(Version)?\s*=?\s*flutter\.minSdkVersion",
               f"minSdk = Math.max({MIN_SDK}, flutter.minSdkVersion)", s, count=1)
    s = s.replace("\n    buildTypes {", GROOVY_SIGNING, 1)
    s = re.sub(r"signingConfig\s*=?\s*signingConfigs\.debug",
               "signingConfig = keystorePropertiesFile.exists() ? signingConfigs.release "
               ": signingConfigs.debug", s, count=1)
    need(APP_ID in s and "Math.max(" in s and "signingConfigs.release" in s,
         "build.gradle patch incomplete (template changed?)")
    return s


NETSEC = '''<?xml version="1.0" encoding="utf-8"?>
<!-- DCOV: plain HTTP is permitted because a field server is normally reached
     as http://<LAN-IP>:8000 on an isolated network. For anything reachable
     beyond that network, serve HTTPS (deploy/Caddyfile) and use https:// in
     the app's server address. -->
<network-security-config>
    <base-config cleartextTrafficPermitted="true">
        <trust-anchors>
            <certificates src="system"/>
        </trust-anchors>
    </base-config>
</network-security-config>
'''
PROGUARD = '''# DCOV: ML Kit text recognition ships the Latin model only; the optional
# script recognisers are referenced but absent, which R8 reports as missing
# classes and fails the release build without these lines.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_text_common.** { *; }
'''


def android() -> None:
    app = ROOT / "android" / "app"
    if not app.exists():
        print("  (no android/ - skipped)")
        return
    patch(app / "src" / "main" / "AndroidManifest.xml", manifest)
    kts, groovy = app / "build.gradle.kts", app / "build.gradle"
    if kts.exists():
        patch(kts, gradle_kts)
    elif groovy.exists():
        patch(groovy, gradle_groovy)
    else:
        errors.append("android/app/build.gradle(.kts) not found")
    xml = app / "src" / "main" / "res" / "xml"
    xml.mkdir(parents=True, exist_ok=True)
    (xml / "network_security_config.xml").write_text(NETSEC)
    (app / "proguard-rules.pro").write_text(PROGUARD)
    for d in (BRAND / "android").glob("mipmap-*"):
        dst = app / "src" / "main" / "res" / d.name
        dst.mkdir(parents=True, exist_ok=True)
        shutil.copy(d / "ic_launcher.png", dst / "ic_launcher.png")
    # remove adaptive-icon XML that would override the PNGs on API 26+
    shutil.rmtree(app / "src" / "main" / "res" / "mipmap-anydpi-v26", ignore_errors=True)
    print("  android configured")


# --------------------------------------------------------------------------- #
# iOS
# --------------------------------------------------------------------------- #
PLIST_KEYS = {
    "NSCameraUsageDescription":
        "DCOV uses the camera to scan component barcodes and photograph chip markings "
        "for origin verification.",
    "NSPhotoLibraryUsageDescription":
        "DCOV can read a chip photo you already took, to verify its marking.",
}


def plist(s: str) -> str:
    add = ""
    for k, v in PLIST_KEYS.items():
        if k not in s:
            add += f"\t<key>{k}</key>\n\t<string>{v}</string>\n"
    if "NSAppTransportSecurity" not in s:
        add += ("\t<key>NSAppTransportSecurity</key>\n\t<dict>\n"
                "\t\t<key>NSAllowsLocalNetworking</key>\n\t\t<true/>\n\t</dict>\n")
    s = re.sub(r"(<key>CFBundleDisplayName</key>\s*<string>)[^<]*(</string>)", r"\1DCOV\2", s)
    if add:
        i = s.rindex("</dict>")
        s = s[:i] + add + s[i:]
    return s


def ios() -> None:
    ios_dir = ROOT / "ios"
    if not ios_dir.exists():
        print("  (no ios/ - skipped)")
        return
    patch(ios_dir / "Runner" / "Info.plist", plist)
    podfile = ios_dir / "Podfile"
    if podfile.exists():
        patch(podfile, lambda s: re.sub(r"#?\s*platform :ios, '[\d.]+'", "platform :ios, '15.5'", s))
    else:
        # Flutter writes the Podfile on the first iOS build/config step and
        # will NOT regenerate one that exists - so never create a stub here.
        # Run `flutter build ios --config-only --no-codesign` and then this
        # script again (the CI workflow does exactly that).
        print("  note: ios/Podfile not generated yet - rerun after "
              "`flutter build ios --config-only --no-codesign`")
    patch(ios_dir / "Runner.xcodeproj" / "project.pbxproj",
          lambda s: re.sub(r"IPHONEOS_DEPLOYMENT_TARGET = [\d.]+;",
                           "IPHONEOS_DEPLOYMENT_TARGET = 15.5;", s))
    print("  ios configured")


# --------------------------------------------------------------------------- #
def windows() -> None:
    w = ROOT / "windows"
    if not w.exists():
        print("  (no windows/ - skipped)")
        return
    patch(w / "runner" / "main.cpp", lambda s: re.sub(r'window\.Create\(L"[^"]*"',
                                                       'window.Create(L"DCOV"', s))
    ico = w / "runner" / "resources" / "app_icon.ico"
    if ico.parent.exists():
        shutil.copy(BRAND / "app_icon.ico", ico)
    print("  windows configured")


if __name__ == "__main__":
    android()
    ios()
    windows()
    if errors:
        print("\nCONFIGURATION FAILED:\n  " + "\n  ".join(errors), file=sys.stderr)
        sys.exit(1)
    print("platform configuration complete")
