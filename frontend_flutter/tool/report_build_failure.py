#!/usr/bin/env python3
"""Turn a failed `flutter build` log into readable GitHub annotations.

    python3 tool/report_build_failure.py <log> [<log> ...]

GitHub only shows full step logs to signed-in users, but run annotations and
the job summary are visible on the public run page. This script pulls the
lines that actually explain a Gradle/R8/Kotlin/Dart failure out of the log and
emits them as ::error:: annotations plus a job-summary section, so the root
cause can be read without downloading the log artifact.

Always exits 0 - the build step itself already failed the job.
"""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

KEEP = re.compile(
    r"(What went wrong|FAILURE:|BUILD FAILED|Execution failed|Could not |"
    r"Missing class|ERROR:|Error:|error:|^e: |Exception|Unresolved reference|"
    r"requires |incompatible|not compatible|Duplicate class|AAPT|"
    r"Lint found|minSdk|compileSdk|Namespace not specified|Dependency .* requires|"
    r"Gradle .* requires|Java .* requires|Unsupported class file|"
    r"Inconsistent JVM-target|Kotlin|R8)", re.I)


def blocks(text: str) -> list[str]:
    out: list[str] = []
    lines = text.splitlines()
    # 1. Gradle's "* What went wrong:" sections, verbatim, up to "* Try:".
    for i, line in enumerate(lines):
        if line.strip().startswith("* What went wrong"):
            chunk = []
            for nxt in lines[i + 1:i + 60]:
                if nxt.strip().startswith("* Try") or nxt.strip().startswith("* Get more help"):
                    break
                chunk.append(nxt.rstrip())
            out.append("What went wrong:\n" + "\n".join(chunk).strip())
    # 2. Other explanatory lines (de-duplicated, bounded).
    seen: set[str] = set()
    extra = []
    for line in lines:
        s = line.strip()
        if s and KEEP.search(s) and s not in seen and len(extra) < 80:
            seen.add(s)
            extra.append(s[:400])
    if extra:
        out.append("Relevant log lines:\n" + "\n".join(extra))
    return out


def esc(s: str) -> str:
    return s.replace("%", "%25").replace("\r", "").replace("\n", "%0A")


def main(paths: list[str]) -> int:
    summary = ["## Android build failure - extracted root cause\n"]
    n = 0
    for p in paths:
        f = Path(p)
        if not f.exists():
            continue
        text = f.read_text(encoding="utf-8", errors="replace")
        for b in blocks(text):
            n += 1
            if n <= 9:  # GitHub keeps 10 error annotations per step
                print(f"::error title={f.name} ({n})::{esc(b[:3800])}")
            summary.append(f"### {f.name} ({n})\n```\n{b[:12000]}\n```\n")
    # R8 writes the exact keep/dontwarn rules it wanted when classes are missing.
    for mr in Path(".").glob("frontend_flutter/build/app/outputs/mapping/*/missing_rules.txt"):
        rules = mr.read_text(errors="replace")
        print(f"::error title=R8 missing_rules.txt::{esc(rules[:3800])}")
        summary.append(f"### {mr}\n```\n{rules}\n```\n")
    if n == 0:
        print("::error title=build failed::no recognisable error lines; see the build-logs artifact")
    out = os.environ.get("GITHUB_STEP_SUMMARY")
    if out:
        with open(out, "a", encoding="utf-8") as fh:
            fh.write("\n".join(summary))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
