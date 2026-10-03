# Running DCOV in VS Code

VS Code works well for this project because it's genuinely two codebases —
Python and Dart — and it handles both without needing two separate editors
open. This walks through both, plus the one thing VS Code can't do for you.

---

## 1. Extensions (once)

Open VS Code's Extensions panel (`Ctrl+Shift+X` / `Cmd+Shift+X`) and install:

- **Python** (Microsoft) — `ms-python.python`
- **Pylance** (Microsoft) — usually installs alongside Python, gives real
  type-checking against the codebase's type hints
- **Flutter** (Dart-Code) — `Dart-Code.flutter`. Installing this also pulls
  in the **Dart** extension automatically.
- **Docker** (Microsoft) — optional, but gives you a sidebar view of the
  `docker-compose.yml` stack once it's running, and lets you right-click
  `docker-compose.yml` → "Compose Up" instead of typing the command.

Restart VS Code after installing the Flutter extension — it needs to detect
your Flutter SDK install (Phase 0 in `ROADMAP.md`; VS Code doesn't install
Flutter for you, it just knows how to drive it once it's on your machine).

---

## 2. Open the project correctly

**Open the repo root as the workspace folder** (`File > Open Folder`), not
`backend/` or `frontend_flutter/` individually. The repo has a `.vscode/`
folder (below) that's written assuming the root is open, and this is what
lets you flip between the Python and Dart sides in one window instead of
juggling two.

**`.vscode/settings.json` and `.vscode/launch.json` already exist in the
repo** — nothing to create, they're checked in. Worth knowing what's in
them before you rely on them:

`.vscode/settings.json` points Pylance at `backend/.venv` (adjust if your
venv lives somewhere else) and tells the Python extension where
`backend/tests/` is for the Testing panel.

`.vscode/launch.json` has three ready-to-use configs, selectable from the
Run and Debug panel's dropdown:
- **DCOV backend (uvicorn)** — runs the API with `--reload`, debugger attached
- **DCOV backend: pytest (current file)** — runs whichever test file is
  open in the active editor tab, with breakpoints working inside it
- **DCOV Flutter app** — runs `frontend_flutter/lib/main.dart`

On Windows, the interpreter path is
`${workspaceFolder}/backend/.venv/Scripts/python.exe` instead — Windows
venvs put the executable in `Scripts/`, not `bin/`.

---

## 3. Backend (Python/FastAPI) side

**Create the venv from VS Code's integrated terminal** (`` Ctrl+` `` /
`` Cmd+` ``) rather than a separate terminal window — same shell, same
working directory, one less thing to keep track of:

```bash
cd backend
python -m venv .venv
source .venv/bin/activate        # Windows: .venv\Scripts\activate
pip install -r requirements.txt -r requirements-dev.txt
```

Once that finishes, **reload the window** (`Ctrl+Shift+P` → "Developer:
Reload Window") so Pylance picks up the new interpreter and stops
red-underlining every `from app.x import y` in the codebase — it doesn't
know packages exist until it's pointed at an environment that has them
installed.

**Run the backend** — either the integrated terminal:
```bash
cd backend && uvicorn app.main:app --reload --host 127.0.0.1 --port 8000
```
or use the **DCOV backend (uvicorn)** launch config already in
`.vscode/launch.json` (Run and Debug panel → pick it from the dropdown →
F5). That config means you can set actual breakpoints in `app/api/*.py`
and have them hit on a real request — worth doing once just to see the
request/response cycle for `/scan` step through the matching cascade live.

**Run the tests** — VS Code's Testing panel (flask icon in the sidebar)
should auto-discover `backend/tests/` once the interpreter is set
correctly above; click the play button, or from the terminal:
```bash
cd backend && pytest -v
```

---

## 4. Flutter side

**First**, if you haven't yet (see `FLUTTER_TESTING.md` and
`ROADMAP.md` Phase 1 — this is not optional, the platform folders don't
exist in the repo):
```bash
cd frontend_flutter
flutter create .
flutter pub get
```

**Then in VS Code**: open any file under `frontend_flutter/lib/` — the
status bar at the bottom-right should show a device picker (e.g. "Chrome"
or "Windows (desktop)" or a connected phone's name). Click it to choose a
target, then either:
- Press **F5** (or Run → Start Debugging) for a full debug session with
  breakpoints, hot reload on save, and the Debug Console
- Or **`Ctrl+F5`** to run without the debugger attached (slightly faster
  startup, no breakpoints)

If the device picker shows nothing, the Flutter extension hasn't found
your SDK yet — run `flutter doctor` in the integrated terminal and fix
whatever it flags before trying again.

**Hot reload**: save any file (`Ctrl+S`) while a debug session is running
and the app updates in place, state preserved, in under a second — this is
the actual productivity win of developing in VS Code over rebuilding from
scratch each time. Hot *restart* (`Ctrl+Shift+F5`) when you need a clean
state, e.g. after changing anything in `main.dart` or a `StatefulWidget`'s
`initState`.

**Run the Dart tests**: open `frontend_flutter/test/matching_test.dart` and
click the "Run" arrow that appears above `void main()`, or:
```bash
cd frontend_flutter && flutter test
```

**Analyzer**: the Flutter extension runs `flutter analyze` continuously in
the background — problems show up in the Problems panel (`Ctrl+Shift+M`)
as you type, not just when you explicitly run it.

---

## 5. Running both at once

Realistically you want the backend running in one integrated terminal tab
and the Flutter app debugging in the Run panel simultaneously — VS Code
supports multiple terminals (`` Ctrl+Shift+` `` for a new one) and a
concurrent debug session without conflict. Point the app at the backend:
Settings → Security → Connection → server address, or the "Change server
address" link on the login screen, set to `http://127.0.0.1:8000` if
they're on the same machine, or your machine's LAN IP if the app is
running on a physical phone instead of an emulator/Chrome (an Android
*emulator* specifically needs `10.0.2.2` instead of `127.0.0.1` to reach
the host machine — this is an Android emulator networking quirk, not a
DCOV-specific thing).

---

## What VS Code can't do here

Same caveat as everywhere else in this project's docs: VS Code is an
editor and task runner, not a substitute for having the actual Flutter SDK,
Android SDK, and (for iOS) Xcode installed and working via `flutter
doctor`. It makes Phase 1 in `ROADMAP.md` more pleasant to run — better
error highlighting, one-click test runs, real breakpoints — but it doesn't
remove any step from that phase. If `flutter doctor` isn't clean, no VS
Code extension fixes that; it just gives you a nicer place to read the
error.
