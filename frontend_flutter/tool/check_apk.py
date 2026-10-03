#!/usr/bin/env python3
"""Post-build checks on a release APK - run by CI, also usable locally.

    python3 tool/check_apk.py build/app/outputs/flutter-apk/app-release.apk

1. Secret scan: the APK must not contain server secrets, private keys,
   keystore passwords or the backend's .env contents. Fails the build on a hit.
2. Content check: the bundled offline catalogue and policy are present.
3. Prints size and SHA-256.

Manifest/version facts (package, versionCode, min/target SDK, permissions)
are printed by `aapt2 dump badging` in the workflow, which needs the Android
SDK; this script deliberately needs only the Python standard library.
"""
from __future__ import annotations

import hashlib
import re
import sys
import zipfile
from pathlib import Path

PATTERNS = {
    "private key block": re.compile(rb"-----BEGIN (RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----"),
    "backend secret env": re.compile(rb"DCOV_SECRET_KEY\s*=\s*\S{8,}"),
    "database URL with password": re.compile(rb"(postgres(ql)?|mysql)(\+\w+)?://[^:\s/]+:[^@\s]{3,}@"),
    "keystore password property": re.compile(rb"storePassword\s*=\s*\S+"),
    "AWS access key": re.compile(rb"AKIA[0-9A-Z]{16}"),
    "test-suite admin password": re.compile(rb"TestAdminPass123!|CiSmokeTest123"),
    "generic password assignment": re.compile(rb"(?i)\b(admin_password|db_password|api_secret)\s*[:=]\s*['\"][^'\"]{6,}"),
}
REQUIRED = ["assets/flutter_assets/assets/data/components_seed.json",
            "assets/flutter_assets/assets/data/policy.json"]


def main(path: str) -> int:
    apk = Path(path)
    data = apk.read_bytes()
    print(f"APK      {apk.name}")
    print(f"size     {len(data):,} bytes ({len(data) / 1048576:.1f} MiB)")
    print(f"sha256   {hashlib.sha256(data).hexdigest()}")
    bad = []
    with zipfile.ZipFile(apk) as z:
        names = set(z.namelist())
        for req in REQUIRED:
            if req not in names:
                bad.append(f"missing bundled file {req}")
        for n in z.namelist():
            blob = z.read(n)
            for label, rx in PATTERNS.items():
                if rx.search(blob):
                    bad.append(f"{label} in {n}")
        abis = sorted({n.split('/')[1] for n in names if n.startswith('lib/') and n.count('/') >= 2})
        print(f"ABIs     {', '.join(abis) or 'none'}")
        print(f"entries  {len(names)}")
    if bad:
        print("\nFAILED:\n  " + "\n  ".join(bad))
        return 1
    print("secret scan: clean; offline catalogue + policy bundled")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
