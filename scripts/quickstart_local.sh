#!/usr/bin/env bash
# Stands up DCOV on a single machine with no Docker: a venv, SQLite, the seed
# catalogue, and a bootstrapped administrator. Good for a first look, a laptop
# demo, or a single field workstation. For multi-user / multi-device
# deployments use deploy/docker-compose.yml with PostgreSQL instead.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

echo "== 1. Virtual environment =="
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip -q
pip install -r backend/requirements.txt -q
echo "  (server-side OCR is optional: pip install -r backend/requirements-vision.txt)"

echo "== 2. Environment =="
export DCOV_DATABASE_URL="sqlite+aiosqlite:///$ROOT/data/dcov.sqlite"
export DCOV_SECRET_KEY="$(python3 -c 'import secrets;print(secrets.token_urlsafe(48))')"
export DCOV_ENVIRONMENT="development"
export DCOV_FORCE_HTTPS="false"
export DCOV_CORS_ORIGINS='["http://localhost:8080","http://127.0.0.1:8080"]'
echo "  DCOV_DATABASE_URL=$DCOV_DATABASE_URL"

echo "== 3. Start the API in the background =="
cd backend
python -m uvicorn app.main:app --host 127.0.0.1 --port 8000 > "$ROOT/var-dev.log" 2>&1 &
API_PID=$!
cd "$ROOT"
echo "  pid=$API_PID  log=$ROOT/var-dev.log"
for i in $(seq 1 20); do
  curl -sf http://127.0.0.1:8000/health >/dev/null 2>&1 && break
  sleep 0.5
done
curl -sf http://127.0.0.1:8000/health || { echo "API did not come up - check var-dev.log"; exit 1; }
echo "  API is up."

echo "== 4. Bootstrap the first administrator =="
ADMIN_PASS="$(python3 -c 'import secrets;print(secrets.token_urlsafe(12))')"
(cd backend && python -m app.cli create_admin --username admin --password "$ADMIN_PASS")
echo "  username: admin"
echo "  password: $ADMIN_PASS   (save this - it is shown once)"

echo "== 5. Load the seed catalogue (203 components from the source workbook) =="
(cd backend && python -m app.cli load_seed "$ROOT/data/components_seed.json")

echo "== 6. Serve the web client =="
cd web_demo
python3 -m http.server 8080 --bind 127.0.0.1 > "$ROOT/var-web.log" 2>&1 &
WEB_PID=$!
cd "$ROOT"
echo "  pid=$WEB_PID  log=$ROOT/var-web.log"

cat << EOF

--------------------------------------------------------------------
DCOV is running.

  API           http://127.0.0.1:8000/api/docs
  Web client    http://127.0.0.1:8080
  Admin login   admin / $ADMIN_PASS

Verify it end to end:
  ./scripts/smoke_test.sh http://127.0.0.1:8000 admin '$ADMIN_PASS'

Stop it:
  kill $API_PID $WEB_PID
--------------------------------------------------------------------
EOF
