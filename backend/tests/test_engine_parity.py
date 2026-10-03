"""The web demo's JS engine (web_demo/dcov-match.js) must give the same match
and verdict as the server for every catalogue row and match method. Runs the
JS with Node when it is installed; skipped otherwise. (The Dart port is held to
the same vectors by frontend_flutter/test/matching_test.dart.)"""
from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

import pytest

from app.services.matching import ComponentIndex, Matcher, verdict_for

ROOT = Path(__file__).resolve().parents[2]
NODE = shutil.which("node")


@pytest.mark.skipif(NODE is None, reason="node not installed")
def test_js_engine_matches_python_engine():
    seed = ROOT / "data" / "components_seed.json"
    out = subprocess.run([NODE, str(Path(__file__).parent / "js" / "parity_dump.js"),
                          str(ROOT / "web_demo" / "dcov-match.js"), str(seed)],
                         capture_output=True, text=True, check=True, timeout=120)
    js = json.loads(out.stdout)
    rows = {r["component_id"]: r for r in json.loads(seed.read_text())}
    for cid, m, sc, banner, head, ev, rev in js["verdicts"]:
        v = verdict_for(rows[cid], sc, m)
        assert (v["banner"], v["headline"], v["origin_evidence"], v["review_required"]) == \
            (banner, head, ev, rev), (cid, m, sc)
    idx = ComponentIndex(json.loads(seed.read_text()))
    for probe, meth, score, cid in js["matches"]:
        r = Matcher().match(probe, idx)
        assert (r.method, round(r.score, 2), (r.component or {}).get("component_id")) == \
            (meth, score, cid), probe
