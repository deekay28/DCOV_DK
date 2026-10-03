# DCOV — Deploy and verify

Three layers exist right now, and they don't all talk to each other yet:

| Layer | Path | What it is | Talks to the backend? |
|---|---|---|---|
| Offline web demo | `web_demo/` | Standalone HTML/JS. The full matching engine ported to JavaScript, running entirely against an embedded copy of the catalogue. | No — self-contained by design |
| Backend API | `backend/` | The real FastAPI service: auth, database, import wizard, reports, audit. | — |
| Flutter app | *(not built yet)* | The real field client, online and offline | Would talk to the backend |

So there are two independent things to deploy and verify, not one. Do both.

---

## 1. Offline web demo — zero install, 30 seconds

This has no server-side component at all; it's a static folder.

```bash
cd web_demo
python3 -m http.server 8080
# open http://localhost:8080
```

Or just double-click `web_demo/index.html` — everything except the camera-based
scan buttons works straight from disk (`file://`).

**Verify it:**
- Tap any of the six sample chips on the Verify tab. You should see all four
  banner colors across them (red/green/yellow/grey) and, under each, the
  "Matching cascade" trace showing exactly which of the six matching layers
  fired.
- Switch to **Overview** — it should read **203 records, 45 Chinese, 142
  non-Chinese, 16 unknown, 29 Chinese+critical**. Those numbers come straight
  out of your workbook via `scripts/build_seed_database.py`; if you re-run
  that script after editing the source sheets, re-run
  `node -e "..."` isn't needed — just refresh the page, since `seed_data.js`
  is regenerated in place.
- Switch to **Catalogue**, filter Origin → Chinese, Criticality → Critical.
  Should show the same subsystems as the "Chinese-origin parts by subsystem"
  bar chart on Overview.
- Open DevTools console — there should be nothing in it. I ran this exact
  check with a headless browser before handing it to you: zero console errors
  across all four verdict states, the catalogue view, and the desktop layout.

This layer is genuinely done. What it can't do: it doesn't call OCR, doesn't
persist history past the browser tab, and doesn't share data between devices
— that's the backend's job.

---

## 2. Backend API

### Option A — no Docker (fastest first look)

```bash
./scripts/quickstart_local.sh
```

This creates a venv, installs `backend/requirements.txt`, starts the API on
SQLite at `127.0.0.1:8000`, creates an `admin` account with a generated
password (printed once — save it), loads all 203 seed components, and serves
the web demo on `127.0.0.1:8080`. Takes under a minute with a warm pip cache.

### Option B — Docker Compose (PostgreSQL + TLS, closer to production)

```bash
cp deploy/.env.example deploy/.env
# edit deploy/.env: set DCOV_SECRET_KEY and POSTGRES_PASSWORD to real values
python3 -c "import secrets; print(secrets.token_urlsafe(48))"   # generate a key

docker compose -f deploy/docker-compose.yml --env-file deploy/.env up -d --build
docker compose -f deploy/docker-compose.yml exec backend \
  python -m app.cli create_admin --username admin --password 'ChangeMe123!$'
docker compose -f deploy/docker-compose.yml exec backend \
  python -m app.cli load_seed data/components_seed.json
```

Caddy (`deploy/Caddyfile`) terminates TLS in front of everything and is the
*only* service that publishes a port to the host (80/443) — the backend and
web client are reachable only through it. It picks a certificate strategy
automatically based on `DCOV_DOMAIN` in `deploy/.env`:

- **Left at the default (`localhost`)**, for a LAN-only field deployment
  with no public DNS: Caddy issues a certificate from its own internal CA.
  Your browser will show a trust warning the first time — either click
  through it, or trust Caddy's root CA properly:
  ```bash
  docker compose -f deploy/docker-compose.yml exec proxy \
    cat /data/caddy/pki/authorities/local/root.crt > dcov-ca.crt
  # then import dcov-ca.crt into your OS/browser trust store
  ```
- **Set to a real DNS hostname you control** (`DCOV_DOMAIN=dcov.yourunit.example`
  in `.env`), with that record already pointing at this machine and ports
  80/443 reachable from the internet: Caddy requests and auto-renews a real
  publicly-trusted certificate. Nothing else to configure.

`INSTALL_VISION=true` in `.env` pulls EasyOCR/Torch (~2 GB, needs network at
build time) for server-side chip-photo OCR. Leave it `false` for a slim image
that still does barcode, QR, and manual entry — the full matching cascade
runs identically either way; only the "photograph a chip and let the server
read it" path needs the vision extras.

**Debugging without the proxy in the way:** to hit the backend directly on
plain HTTP (curl, a quick Swagger check) without dealing with TLS at all,
add the debug override, which republishes 8000/8080 straight to the host:
```bash
docker compose -f deploy/docker-compose.yml -f deploy/docker-compose.debug.yml \
  --env-file deploy/.env up -d --build
```
Never do this for anything reachable from outside your own machine — it
defeats the "only the proxy is exposed" guarantee the rest of this section
relies on.

### Verify the backend

```bash
DCOV_SMOKE_INSECURE=1 ./scripts/smoke_test.sh https://localhost admin 'the-password-from-above'
```
(`DCOV_SMOKE_INSECURE=1` tells curl to trust Caddy's internal CA without you
importing it first — fine for this quick check, and unset it if you ever
point the script at a real deployment with a proper certificate. Or skip
TLS during verification entirely with the debug override above and run
against `http://localhost:8000` with no flag.)

This is a real end-to-end check, not a ping — it logs in, submits a known
Chinese marking and confirms **RED**, submits an OCR-style misread of that
same marking and confirms it still resolves to RED through the correct
matching layer, submits a nonsense marking and confirms **GREY**, replays a
duplicate `client_uuid` and confirms no duplicate history row was created,
generates all three report formats and checks they're non-trivial in size,
and recomputes the audit hash chain end to end. Ten checks, plain
`OK`/`FAIL` output, non-zero exit on any failure.

You can also just open **`https://localhost/api/docs`** and drive it by
hand — every endpoint, schema, and validation rule is there via Swagger UI,
generated straight from the code, so it can't drift from what's actually
implemented.

### What "healthy" looks like

```bash
curl -sk https://localhost/health | python3 -m json.tool
```
```json
{
  "status": "ok",
  "version": "1.0.0",
  "index": {"rows": 203, "revision": 1, "built_at": "2026-08-04T..."}
}
```
`index.rows` should be 203 right after `load_seed`. If it's 0, the seed
load didn't run or pointed at the wrong file.

---

## Known gaps, stated plainly

- **The web demo talks to nothing.** It's a standalone proof that the
  matching logic is correct and portable, not a client of this API. The
  Flutter app (`frontend_flutter/`) *is* wired to the real backend via
  `lib/services/api_client.dart` — that's the actual online/offline client.
- **CI runs but has never executed.** `.github/workflows/ci.yml` runs pytest,
  ruff, mypy, bandit, an Alembic-vs-ORM drift check, a live smoke test, and
  the Flutter/web-demo checks — but I wrote and hand-verified all of it in an
  environment with no network access to actually install FastAPI, pytest, or
  the Flutter SDK. I checked what I could without them: every test's
  assertions against the real matching/importer code directly, the migration
  against the ORM models column-by-column via a diff script, and the CI
  YAML's parseability and step logic. The first real run on GitHub Actions
  (or `cd backend && pytest -v`) is still the actual first test — treat a red
  CI run on the first push as informative, not surprising.

## Fixed since the last pass

- **TLS.** `docker-compose.yml` now fronts everything with Caddy
  (`deploy/Caddyfile`), which is the only service exposed to the host and
  picks a certificate strategy automatically — a real Let's Encrypt
  certificate for a real domain, or its own internal CA for a LAN-only
  deployment with no public DNS. `DCOV_FORCE_HTTPS=true` is now the
  permanent setting rather than something to remember to flip later,
  because it's now actually true regardless of deployment target: the
  backend has no host-published port to reach any other way. A
  `docker-compose.debug.yml` override exists for local debugging that needs
  plain HTTP, clearly labeled as never for anything internet-reachable.
- **Alembic migration** — `backend/migrations/versions/0001_initial.py`,
  hand-transcribed from `app/models/entities.py` (no network to run
  `--autogenerate` here). Verified column-by-column against the ORM models
  with a diff script — see the CI job's "Alembic migration matches the ORM
  models" step, which runs that same check on every push.
- **pytest suite** — `backend/tests/`: matching-cascade unit tests, import
  wizard unit tests, and API tests for auth/RBAC/scanning/import
  stage-commit-rollback/audit-chain tamper detection. Every assertion in
  `test_matching.py` and `test_importer.py` was run against the real code in
  this sandbox and confirmed correct before being committed — one of them
  caught an actual bug (manufacturer alias resolution wasn't wired into the
  live API, only the offline ETL script; fixed in
  `app/services/matching.py`).

If you want, the standing offer moves to the next layer: `docs/USER_MANUAL.md`
/ `docs/ADMIN_MANUAL.md` (explicit deliverables from the original spec that
aren't written yet), or tightening `mypy`/CI once you've seen a real run.
