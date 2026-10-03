#!/data/data/com.termux/files/usr/bin/bash
# Stands up DCOV inside Termux on Android: SQLite only, no Docker, no vision
# extras. Uses Termux's own precompiled packages for the heavy scientific
# libraries (numpy/pandas/cryptography) instead of building them from source,
# which on a phone CPU can otherwise take 30-60+ minutes.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

echo "== 1. Termux system packages =="
pkg update -y
# python-numpy/python-pandas/python-cryptography are Termux's own precompiled
# builds for Android's Bionic libc - pulling these via pkg avoids pip trying
# (and often failing, or taking forever) to compile them from source.
pkg install -y python python-pip python-numpy python-pandas python-cryptography \
               openssl libffi rust binutils clang make pkg-config

echo "== 2. Virtual environment (with access to the pkg-installed packages) =="
python -m venv --system-site-packages .venv
source .venv/bin/activate
pip install --upgrade pip -q
pip install -r backend/requirements-termux.txt -q
echo "  If bcrypt/cryptography fail to build here despite the rust/clang packages,"
echo "  remove those two lines from backend/requirements-termux.txt, re-run, and"
echo "  set DCOV_PASSWORD_SCHEME=pbkdf2_sha256 below instead."

echo "== 3. Environment =="
export DCOV_DATABASE_URL="sqlite+aiosqlite:///$ROOT/data/dcov.sqlite"
export DCOV_SECRET_KEY="$(python -c 'import secrets;print(secrets.token_urlsafe(48))')"
export DCOV_ENVIRONMENT="development"
export DCOV_FORCE_HTTPS="false"
export DCOV_PASSWORD_SCHEME="${DCOV_PASSWORD_SCHEME:-bcrypt}"
export DCOV_CORS_ORIGINS='["http://127.0.0.1:8080"]'

echo "== 4. Start the API =="
cd backend
# Plain uvicorn, no --workers (Termux/Android does not give you real
# multi-process gains here) and no uvloop (not installed in this profile).
python -m uvicorn app.main:app --host 127.0.0.1 --port 8000 > "$ROOT/var-dev.log" 2>&1 &
API_PID=$!
cd "$ROOT"
for i in $(seq 1 30); do
  curl -sf http://127.0.0.1:8000/health >/dev/null 2>&1 && break
  sleep 1
done
curl -sf http://127.0.0.1:8000/health || { echo "API did not come up - check var-dev.log"; exit 1; }
echo "  API is up (pid=$API_PID)"

echo "== 5. Bootstrap admin + load seed catalogue =="
ADMIN_PASS="$(python -c 'import secrets;print(secrets.token_urlsafe(12))')"
(cd backend && python -m app.cli create_admin --username admin --password "$ADMIN_PASS")
(cd backend && python -m app.cli load_seed "$ROOT/data/components_seed.json")

echo "== 6. Serve the offline web demo =="
cd web_demo
python -m http.server 8080 --bind 127.0.0.1 > "$ROOT/var-web.log" 2>&1 &
WEB_PID=$!
cd "$ROOT"

cat << EOF

--------------------------------------------------------------------
DCOV is running under Termux.

  API           http://127.0.0.1:8000/api/docs
  Web client    http://127.0.0.1:8080   (open in Chrome/Firefox on the phone)
  Admin login   admin / $ADMIN_PASS

Verify:
  ./scripts/smoke_test.sh http://127.0.0.1:8000 admin '$ADMIN_PASS'

Keep it running in the background: Termux kills processes when the
session closes unless you run this under 'termux-wake-lock' or inside
'tmux'/'screen'. For anything beyond a quick test:
  pkg install tmux && tmux new -s dcov
  ./scripts/quickstart_termux.sh
  # Ctrl+B then D to detach; 'tmux attach -t dcov' to come back

Stop it:
  kill $API_PID $WEB_PID
--------------------------------------------------------------------
EOF
