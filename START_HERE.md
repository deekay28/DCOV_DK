# DCOV — Start Here

> **Update 2026-10-03 (v1.1.0).** Read these first:
> `AUDIT_REAL_STATUS.md` (what is verified vs not), `CHANGELOG.md` (what was
> fixed), `ORIGIN_VERIFICATION_LOGIC.md` (how verdicts are decided),
> `ANDROID_RELEASE.md` + `release/` (building and installing the APK),
> `FIELD_ACCEPTANCE_TEST.md` (phone test checklist).
>
> Fastest path to a phone build: push this folder to a GitHub repo; the
> *Build apps* workflow produces the APK. Fastest path to a server phones can
> reach: `scripts/run_lan_server.ps1` (Windows) or `scripts/run_lan_server.sh`.
> `flutter create .` alone is no longer enough for Android — also run
> `python tool/configure_platforms.py` inside `frontend_flutter/` (camera
> permission, app ID, signing, ML Kit rules).

You have source code, not a running app. This is the one document that
takes you from "unzipped folder" to "actually running," in order, with
nothing skipped. Everything else in `docs/` is reference material for
after this works.

**The honest state of this project, in one paragraph:** every file has
been checked as thoroughly as possible without the tools to run it — every
Dart file's braces/parens/brackets balance, every cross-file class
reference has a matching import (verified programmatically, not by eye),
every backend `import` resolves to a real module and symbol, every Python
file compiles, every pytest fixture used is actually defined. What none of
it has ever done is run. That first run is step 2 below, and it is not
optional busywork — it's the actual test.

---

## Step 0: What you need before anything else

A real computer — Windows, Mac, or Linux. Not this environment, not
Termux. See `docs/FLUTTER_TESTING.md` for the full toolchain list; in
short: Python 3.12+, and Flutter + Android Studio (+ Xcode if you want
iOS). `docs/TERMUX.md` if you specifically want the *backend* running on
an Android phone (the app itself cannot build there).

## Step 1: Backend — the part most likely to just work

```bash
cd backend
python -m venv .venv
source .venv/bin/activate        # Windows: .venv\Scripts\activate
pip install -r requirements.txt -r requirements-dev.txt
pytest -v
```

**This is the real first test of ~3,500 lines of backend code that has
never executed.** Expect to fix something. If everything's green, then:

```bash
cd ..
./scripts/quickstart_local.sh
./scripts/smoke_test.sh http://127.0.0.1:8000 admin '<password it prints>'
```

Ten checks against a live server. `docs/DEPLOY.md` has the Docker path if
you want that instead.

## Step 2: Flutter app — the part that needs the most from you

```bash
cd frontend_flutter
flutter create .        # generates android/ios/windows/etc - not in this repo
flutter pub get
```

Add the camera permissions `flutter create` doesn't know about — exact XML
in `docs/FLUTTER_TESTING.md`, section 2. Then:

```bash
flutter test             # matching-engine unit tests
flutter analyze          # this is where any remaining issue will surface
flutter run -d chrome    # fastest first look
```

**`flutter analyze` is the single most informative command you can run
against this codebase.** Everything I could check without it, I checked;
what I couldn't check is exactly what this command checks. Read its output
literally — every file/line it names is real, actionable information, not
noise.

For Windows or Android specifically, and for `flutter build apk --release`,
see `docs/FLUTTER_TESTING.md` in full — it covers device setup, signing,
and the emulator-vs-real-device tradeoffs (camera scanning needs a real
device).

## Step 3: Point the app at the backend

Sign-in screen → "Change server address" → your backend's address
(`http://127.0.0.1:8000` if both are on the same machine, your machine's
LAN IP if the app is on a physical phone, `10.0.2.2` instead of `127.0.0.1`
specifically for the Android emulator).

## If something breaks

That's expected — see the honest-state paragraph above. Two things help a
lot:

1. **The exact error**, not a paraphrase. `flutter analyze` and `pytest`
   both give file/line/message; that's the useful unit.
2. **Which step** in this document you were on.

Bring both back and it can be fixed properly rather than guessed at.

---

## Everything else, for after this works

| Doc | What it's for |
|---|---|
| `docs/REQUIREMENTS_AUDIT.md` | What's actually built vs. the original spec, section by section, with evidence |
| `docs/ROADMAP.md` | What's left, in priority order |
| `docs/USER_MANUAL.md` | For an inspector using the app |
| `docs/ADMIN_MANUAL.md` | For whoever runs the server — users, imports, backups, security posture |
| `docs/DEPLOY.md` | Docker/production deployment, TLS |
| `docs/TERMUX.md` | Running the backend on an Android phone |
| `docs/VSCODE_SETUP.md` | VS Code-specific setup; `.vscode/` configs are already in the repo |
| `docs/FLUTTER_TESTING.md` | The full Flutter toolchain and testing story, Windows/Android in detail |
