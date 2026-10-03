# Running DCOV on Termux (Android)

Short answer: **the backend, yes — Docker Compose and server-side OCR, no.**

## What works

- The **offline web demo** (`web_demo/`) — trivially. It's static HTML/JS;
  serve it with `python -m http.server` inside Termux and open
  `http://127.0.0.1:8080` in Chrome/Firefox on the same phone. No caveats.
- The **backend API** on SQLite — yes, via `./scripts/quickstart_termux.sh`.
  FastAPI, SQLAlchemy, the matching engine, the import wizard, PDF/XLSX/CSV
  reports, the audit log — all pure Python or have Termux-buildable deps.
- Barcode/QR scanning and manual chip-number entry — yes, once a real client
  talks to it (today that's Swagger UI at `/api/docs`, or `curl`; the Flutter
  app isn't built yet).

## What doesn't

- **Docker.** Termux has no Docker daemon (no cgroups/namespaces support the
  way `docker-compose.yml` needs, even with root). Run the backend directly
  with the quickstart script instead of the compose stack.
- **PostgreSQL/MySQL as the backend's database.** `asyncpg`/`asyncmy` need
  server processes and client libraries this environment doesn't reasonably
  support. Termux mode is SQLite-only — fine for a single device or a small
  team pointed at one phone/tablet acting as a field server.
- **Server-side OCR** (`requirements-vision.txt`: EasyOCR/PyTorch,
  OpenCV). PyTorch has no Android/Termux wheel, and building it from source
  is a multi-hour, multi-gigabyte undertaking not worth attempting on a
  phone. This doesn't block chip-marking lookup — it blocks the specific
  "upload a photo and let the *server* read it" path. On an actual Android
  device the right answer is on-device ML Kit OCR in the Flutter client
  (already the intended design — see `SKILL`-adjacent notes in
  `backend/app/services/ocr.py`), not server-side OpenCV/EasyOCR.

## The two things that need extra care

**1. Native/Rust-heavy Python packages.** `pydantic-core` (Rust),
`cryptography` (Rust), and `bcrypt` (native) have no Android wheel, so pip
builds them from source. `pkg install rust binutils clang` makes this
*possible*, not fast — expect several minutes per package on a phone CPU, once.
`requirements-termux.txt` also drops `uvicorn[standard]`'s `uvloop`/`httptools`
extras (no Termux wheel, and you don't need them for a single-device server).

If bcrypt's build is too slow or fails on your device, you don't need it:

```bash
export DCOV_PASSWORD_SCHEME=pbkdf2_sha256
```

This switches password hashing to `pbkdf2_sha256`, which is pure Python and
needs no compiled extension at all. `backend/app/core/security.py` already
supports both schemes side by side — existing bcrypt hashes still verify, new
ones use whichever scheme is configured. JWTs default to HS256 (HMAC), so the
`cryptography` package is only exercised by the biometric-login signature
check, which you won't hit from `curl`/Swagger anyway.

**2. numpy/pandas.** Building numpy from source on a phone is slow and
occasionally flaky. `quickstart_termux.sh` installs Termux's own precompiled
`python-numpy`/`python-pandas` packages via `pkg` (built specifically for
Android's Bionic libc) and creates the venv with `--system-site-packages` so
it can see them, instead of letting pip try to compile numpy itself.

## Run it

```bash
pkg install git   # if you haven't already
# unzip or git clone the project, then:
cd dcov-drone-component-verify
./scripts/quickstart_termux.sh
./scripts/smoke_test.sh http://127.0.0.1:8000 admin '<password printed above>'
```

Termux suspends background processes when the session ends unless you keep
it alive — `pkg install tmux`, `tmux new -s dcov`, run the script inside that,
detach with `Ctrl+B D`. Also run `termux-wake-lock` if you want the API to
survive the screen locking.
