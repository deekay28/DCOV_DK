#!/usr/bin/env python3
"""Publish `flutter analyze` errors and `flutter test` failures as GitHub
annotations (visible on the public run page without signing in).

    python3 tool/report_dart_issues.py <analyze.log> <test.log>

Always exits 0 - the analyze/test step has already failed the job.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ANALYZE = re.compile(r"^\s*(error|warning)\s+•\s+(.+?)\s+•\s+(\S+?):(\d+):(\d+)\s+•\s+(\S+)")
COMPILE = re.compile(r"^(\S+\.dart):(\d+):(\d+): Error: (.*)")


def esc(s: str) -> str:
    return s.replace("%", "%25").replace("\r", "").replace("\n", "%0A")


def main(analyze_log: str, test_log: str) -> int:
    n = 0
    a = Path(analyze_log)
    if a.exists():
        for line in a.read_text(errors="replace").splitlines():
            m = ANALYZE.match(line)
            if m and n < 40:
                sev, msg, f, ln, col, code = m.groups()
                kind = "error" if sev == "error" else "warning"
                print(f"::{kind} file=frontend_flutter/{f},line={ln},col={col},title=analyze {code}::{esc(msg)}")
                n += 1
    t = Path(test_log)
    if t.exists():
        lines = t.read_text(errors="replace").splitlines()
        for i, line in enumerate(lines):
            m = COMPILE.match(line.strip())
            if m and n < 40:
                f, ln, col, msg = m.groups()
                print(f"::error file=frontend_flutter/{f},line={ln},col={col},title=test compile::{esc(msg)}")
                n += 1
            elif "[E]" in line and n < 40:
                block = "\n".join(lines[i:i + 30])
                print(f"::error title=test failed::{esc(block[:3800])}")
                n += 1
    if n == 0:
        print("::error title=analyze/test failed::no recognisable lines - see the logs")
    return 0


if __name__ == "__main__":
    sys.exit(main(*(sys.argv[1:3] + ["", ""])[:2]))
