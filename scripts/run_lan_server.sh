#!/usr/bin/env bash
# Runs the DCOV backend so that phones on the same Wi-Fi/LAN can reach it.
#
#   ./scripts/run_lan_server.sh            # first run creates venv, admin, seed
#   ./scripts/run_lan_server.sh --port 8000
#
# Differences from quickstart_local.sh (which is localhost-only):
#   * binds 0.0.0.0, not 127.0.0.1 - otherwise no other device can connect
#   * persists DCOV_SECRET_KEY in backend/.env (git-ignored) so restarting the
#     server does not sign every phone out
#   * accepts the LAN IP as Host header (DCOV_TRUSTED_HOSTS)
#   * plain HTTP: acceptable on an isolated field LAN only. For anything
#     reachable from outside, put it behind TLS (deploy/Caddyfile, DEPLOY.md).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
PORT=8000
[[ "${1:-}" == "--port" ]] && PORT="$2"

PY=python3
if [[ ! -d .venv ]]; then
  echo "== creating virtual environment"
  $PY -m venv .venv
  .venv/bin/pip install -q --upgrade pip
  .venv/bin/pip install -q -r backend/requirements.txt
  echo "   (optional server OCR: .venv/bin/pip install -r backend/requirements-vision.txt"
  echo "    plus the tesseract-ocr package from your OS)"
fi
source .venv/bin/activate

ENV_FILE="backend/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  umask 077
  cat > "$ENV_FILE" <<EOF
DCOV_SECRET_KEY=$($PY -c 'import secrets;print(secrets.token_urlsafe(48))')
DCOV_DATABASE_URL=sqlite+aiosqlite:///$ROOT/data/dcov.sqlite
DCOV_ENVIRONMENT=production
DCOV_FORCE_HTTPS=false
DCOV_PASSWORD_SCHEME=pbkdf2_sha256
EOF
  echo "== wrote $ENV_FILE (keep it private; it holds the token signing key)"
fi
set -a; source "$ENV_FILE"; set +a

LAN_IP=$($PY - <<'EOF'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    s.connect(("10.255.255.255", 1)); print(s.getsockname()[0])
except OSError:
    print("127.0.0.1")
finally:
    s.close()
EOF
)
export DCOV_TRUSTED_HOSTS="[\"$LAN_IP\",\"localhost\",\"127.0.0.1\",\"*.local\"]"

cd backend
if ! $PY -c "import sqlite3,sys; c=sqlite3.connect('$ROOT/data/dcov.sqlite'); c.execute('select 1 from users limit 1')" 2>/dev/null; then
  FIRST_RUN=1
fi
if [[ "${FIRST_RUN:-0}" == "1" ]]; then
  echo "== first run: database, administrator, seed catalogue"
  $PY -c "import asyncio; from app.core.database import init_models; asyncio.run(init_models())"
  ADMIN_PASS="$($PY -c 'import secrets;print(secrets.token_urlsafe(12))')Aa1!"
  $PY -m app.cli create_admin --username admin --password "$ADMIN_PASS"
  $PY -m app.cli load_seed "$ROOT/data/components_seed.json"
  echo
  echo "   ADMIN LOGIN:  admin / $ADMIN_PASS     (shown once - write it down)"
fi

cat <<EOF

------------------------------------------------------------------
 DCOV backend for phones on this network

   In the app:  Settings > Server address  =  http://$LAN_IP:$PORT
   Check from the phone's browser:            http://$LAN_IP:$PORT/health

 If the phone cannot connect: same Wi-Fi network? firewall allowing
 TCP $PORT inbound? (Windows: allow Python through Defender Firewall)
------------------------------------------------------------------
EOF
exec $PY -m uvicorn app.main:app --host 0.0.0.0 --port "$PORT" --proxy-headers
