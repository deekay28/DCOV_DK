#!/usr/bin/env bash
# Exercises a running DCOV backend end to end: health, login, scan (red/green/
# grey), dashboard, report generation, and audit chain verification.
#
# Usage:
#   ./scripts/smoke_test.sh http://localhost:8000 admin 'YourPassword123!'
set -euo pipefail
BASE="${1:-http://localhost:8000}"
USER="${2:-admin}"
PASS="${3:?Usage: smoke_test.sh <base_url> <username> <password>}"
API="$BASE/api/v1"
FAIL=0

# Set DCOV_SMOKE_INSECURE=1 when testing an https:// target secured by
# Caddy's internal CA (the default for a LAN-only deploy/docker-compose.yml
# deployment - see docs/DEPLOY.md's TLS section) rather than a real
# certificate. Never set this against anything you don't control.
CURL_TLS_OPTS=()
[ "${DCOV_SMOKE_INSECURE:-0}" = "1" ] && CURL_TLS_OPTS+=(-k)

pass() { echo "  OK   $1"; }
fail() { echo "  FAIL $1"; FAIL=1; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/dcov_smoke.XXXXXX"); export WORK
trap 'rm -rf "$WORK"' EXIT
# OUT overrides where the response body goes (curl honours only one -o per URL -
# the report step used to pass a second -o, so reports were never written).
req()  { curl -sS "${CURL_TLS_OPTS[@]}" -o "${OUT:-$WORK/body}" -w '%{http_code}' "$@"; }

echo "== 1. Liveness =="
code=$(req "$BASE/health")
[ "$code" = "200" ] && pass "GET /health -> 200" || fail "GET /health -> $code"
grep -q '"status":"ok"' $WORK/body && pass "health payload reports ok" \
  || fail "unexpected health payload: $(cat $WORK/body)"

echo "== 2. Readiness (DB reachable) =="
code=$(req "$BASE/ready")
[ "$code" = "200" ] && pass "GET /ready -> 200 ($(cat $WORK/body))" \
  || fail "GET /ready -> $code"

echo "== 3. Auth =="
code=$(req -X POST "$API/auth/login" -H 'Content-Type: application/json' \
  -d "{\"username\":\"$USER\",\"password\":\"$PASS\",\"device_id\":\"smoke-test\"}")
if [ "$code" = "200" ]; then
  pass "POST /auth/login -> 200"
  TOKEN=$(python3 -c "import json,sys;print(json.load(open('$WORK/body'))['access_token'])")
else
  fail "POST /auth/login -> $code : $(cat $WORK/body)"
  echo "Cannot continue without a token."; exit 1
fi
AUTH=(-H "Authorization: Bearer $TOKEN")

echo "== 4. Dashboard reflects the seed data =="
code=$(req "${AUTH[@]}" "$API/dashboard")
if [ "$code" = "200" ]; then
  python3 - << 'PY'
import json
d = json.load(open(__import__('os').environ['WORK']+'/body'))
total, cn = d['total_components'], d['chinese_components']
print(f"  ->    total={total} chinese={cn} unknown={d['unknown_origin']} "
      f"critical_chinese={d['critical_chinese']} db_revision={d['db_revision']}")
assert total > 0, "expected a non-empty catalogue - did you load the seed data?"
PY
  pass "GET /dashboard -> 200 and non-empty"
else
  fail "GET /dashboard -> $code"
fi

echo "== 5. Scan cascade: known Chinese marking -> RED =="
code=$(req -X POST "$API/scan" "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d '{"client_uuid":"smoke-red-0001","input_mode":"manual","raw_input":"STM32F302C8T6"}')
if [ "$code" = "200" ]; then
  banner=$(python3 -c "import json;print(json.load(open('$WORK/body'))['banner'])")
  [ "$banner" = "RED" ] && pass "STM32F302C8T6 -> RED" || fail "expected RED, got $banner"
else
  fail "POST /scan -> $code : $(cat $WORK/body)"
fi

echo "== 6. Scan cascade: OCR-style misread still resolves =="
code=$(req -X POST "$API/scan" "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d '{"client_uuid":"smoke-ocr-0001","input_mode":"ocr","raw_input":"stm32 f3o2-c8t6"}')
if [ "$code" = "200" ]; then
  python3 -c "
import json
r = json.load(open('$WORK/body'))
assert r['banner'] == 'RED', f\"expected RED, got {r['banner']}\"
assert r['match_method'] in ('ocr_corrected','normalized'), r['match_method']
print(f\"  ->    method={r['match_method']} score={r['match_score']}\")"
  pass "misread marking still resolves to RED"
else
  fail "POST /scan (ocr) -> $code"
fi

echo "== 7. Scan cascade: unknown marking -> GREY, queued for review =="
code=$(req -X POST "$API/scan" "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d '{"client_uuid":"smoke-grey-0001","input_mode":"manual","raw_input":"NOT-A-REAL-PART-999"}')
if [ "$code" = "200" ]; then
  banner=$(python3 -c "import json;print(json.load(open('$WORK/body'))['banner'])")
  [ "$banner" = "GREY" ] && pass "unknown marking -> GREY" || fail "expected GREY, got $banner"
else
  fail "POST /scan (unknown) -> $code"
fi

echo "== 8. Replay idempotency (same client_uuid must not duplicate) =="
req -X POST "$API/scan" "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d '{"client_uuid":"smoke-red-0001","input_mode":"manual","raw_input":"STM32F302C8T6"}' >/dev/null
h1=$(req "${AUTH[@]}" "$API/scan/history?days=1&page_size=500")
count=$(python3 -c "
import json
d = json.load(open('$WORK/body'))
print(sum(1 for i in d['items'] if i['raw_input']=='STM32F302C8T6'))")
[ "$count" = "1" ] && pass "replay produced no duplicate history row" \
  || fail "expected exactly 1 history row for the replayed scan, found $count"

echo "== 9. Report generation (PDF, XLSX, CSV) =="
for fmt in pdf xlsx csv; do
  code=$(OUT="$WORK/report.$fmt" req "${AUTH[@]}" "$API/reports/chinese_components?fmt=$fmt")
  size=$(wc -c < "$WORK/report.$fmt" 2>/dev/null || echo 0)
  if [ "$code" = "200" ] && [ "$size" -gt 100 ]; then
    pass "chinese_components report ($fmt): $size bytes"
  else
    fail "chinese_components report ($fmt) -> HTTP $code, $size bytes"
  fi
done

echo "== 10. Audit chain integrity =="
code=$(req "${AUTH[@]}" "$API/audit/verify")
if [ "$code" = "200" ]; then
  intact=$(python3 -c "import json;print(json.load(open('$WORK/body'))['intact'])")
  [ "$intact" = "True" ] && pass "audit hash chain intact" || fail "AUDIT CHAIN BROKEN - investigate immediately"
else
  fail "GET /audit/verify -> $code"
fi

echo
if [ "$FAIL" = "0" ]; then
  echo "ALL CHECKS PASSED"
else
  echo "ONE OR MORE CHECKS FAILED - see FAIL lines above"
fi
exit "$FAIL"
