# DCOV — Roadmap to a Finished App

Ordered phases, each with what to run and what "done" looks like. Read
`REQUIREMENTS_AUDIT.md` first if you haven't — this roadmap is built
directly off its gap list, in priority order, not the original spec's
order.

---

## Phase 0 — Toolchain (once, on your machine)

You need a real Windows/Mac/Linux machine for this — not Termux, not this
sandbox. See `docs/FLUTTER_TESTING.md` for full detail (and
`docs/VSCODE_SETUP.md` if VS Code is your editor — a `.vscode/` folder with
working launch configs for both the backend and the Flutter app is already
checked into this repo):

1. Install Flutter SDK, Android Studio (Android SDK + an emulator or a
   physical device with USB debugging on), and — only if you need iOS —
   a Mac with Xcode. Windows desktop builds need Visual Studio 2022 with
   the "Desktop development with C++" workload.
2. `flutter doctor -v` — resolve everything it flags before moving on.
3. Install Docker Desktop (for the backend) or follow `DEPLOY.md`'s
   no-Docker path if you'd rather run the backend directly with Python.

**Done when:** `flutter doctor` is clean and `docker --version` (or
`python3 --version` if going Docker-free) works.

---

## Phase 1 — Verify what's actually here (the first real test)

Everything in this project has been checked by hand-tracing code and
running isolated logic in a sandbox with no Flutter SDK, no Docker, and no
network. Nothing has been compiled or run as a whole system yet. This phase
is that first real run.

```bash
# Backend
cd backend
python -m venv .venv && source .venv/bin/activate   # or Scripts\activate on Windows
pip install -r requirements.txt -r requirements-dev.txt
pytest -v --cov=app --cov-report=term-missing
cd ..
./scripts/quickstart_local.sh
./scripts/smoke_test.sh http://127.0.0.1:8000 admin '<password it prints>'

# Flutter
cd frontend_flutter
flutter create .          # generates android/ios/windows/etc - see docs/FLUTTER_TESTING.md
                           # for the camera permissions you need to add right after this
flutter pub get
flutter test
flutter analyze
flutter run -d chrome     # or windows, or a connected Android device
```

**Expect some red.** Nothing here has been compiler-checked. Fix what
breaks before adding anything new — a foundation you haven't actually run
is not a foundation to build the next phase on. If you hit something you
can't figure out, bring the exact error back and it can be fixed properly
instead of guessed at.

**Done when:** pytest is green, `flutter analyze` is clean, the app runs on
at least Chrome + one real target (Windows or Android), and
`smoke_test.sh` passes all 10 checks against a locally running backend.

---

## Phase 2 — Close the biggest gap: admin/report/inspection screens in the app

This is the single highest-leverage phase. The audit found the same shape
of gap repeated five times: real, tested backend capability with no
Flutter screen calling it. Closing this is mostly plumbing — the hard part
(the API, the business logic, the safety properties) is already done and
tested.

Suggested order, each shippable independently:

1. ~~**Reports screen.**~~ **Done** — `frontend_flutter/lib/screens/reports_screen.dart`.
   All 6 report types, format picker (PDF/XLSX/CSV), generates via `GET
   /reports/{key}` and hands off to the OS share sheet. Reachable from the
   Overview tab and the account sheet. Not yet compiler-verified (see
   Phase 1) — this is source code checked by hand-tracing and cross-checking
   package APIs against current pub.dev docs, not by `flutter run`.
2. ~~**Inspection creation and sign-off.**~~ **Done** — `frontend_flutter/lib/screens/inspections_screen.dart`.
   List, create, an "active inspection" that scans get tagged to
   automatically (online and offline-queued alike), scan tally, sign-off
   with the clear-with-findings rejection caught client-side before the
   server has to 409 it. Same compiler caveat as the reports screen.
3. ~~**Analytics screen.**~~ **Done** — `frontend_flutter/lib/screens/analytics_screen.dart`.
   Result mix, monthly trend bars, top-manufacturers and most-detected-Chinese
   leaderboards, the needs-verification queue, and heat-map data as a sorted
   list rather than a chart grid. No charting package added — hand-rolled
   bars in the same style `dashboard_screen.dart` already used, deliberately
   avoiding another third-party API surface to guess at after the
   `share_plus` lesson on the reports screen. Same compiler caveat as the
   other two screens above.
4. ~~**Import wizard UI**~~ **Done, including rollback** — `frontend_flutter/lib/screens/import_screen.dart`.
   File picker → stage → preview, with origin-verdict-flip warnings pulled
   out of the general warnings list and shown first, in red, above
   everything else — and a mandatory "I have reviewed" checkbox that gates
   the commit button, so committing without scrolling past the diffs isn't
   possible. `ImportHistoryScreen` (same file) lists past batches with a
   rollback action, gated with a mandatory typed reason.
5. ~~**Basic user management**~~ **Done** — `frontend_flutter/lib/screens/user_management_screen.dart`.
   List, create, role change, activate/deactivate. Administrator-only, the
   strictest single-role gate in the app. Deactivate is the only removal
   path offered - no delete - matching `ADMIN_MANUAL.md`'s reasoning
   (a hard delete would orphan that user's attribution on every historical
   scan and audit entry).

**Phase 2 is now fully first-pass complete** - all five items have working
screens. None of it has been compiled yet (see Phase 1); that is still the
actual next step, not more screens.

**Done when:** an Administrator can do everything in `ADMIN_MANUAL.md`
from inside the app, not just via `curl`.

---

## Phase 3 — Wire up what's declared but not enforced

Three specific things found during the audit:

1. ~~**`inactivity_logout_minutes` does nothing today.**~~ **Done, as a
   client-side screen lock, not a server logout.** `frontend_flutter/lib/main.dart`'s
   `_ActivityGate`/`_LockScreen` + `AppState`'s inactivity timer, unlocked
   with a PIN stored locally in secure storage rather than re-authenticated
   against the server - deliberately, so an idle timeout doesn't strand a
   field user out of signal at the exact moment they're most likely to be
   without one. This is a different, narrower thing than
   `inactivity_logout_minutes` implied: it locks the screen, it does not
   revoke the server session/token. If a true forced server-side logout is
   a hard requirement (compliance-driven, say), that's still open - see
   `REQUIREMENTS_AUDIT.md`'s entry on this for the exact distinction.
   Configured in Settings → Screen Lock; off by default until a PIN is set,
   on purpose - locking someone out with no way back in is worse than the
   feature not existing.
2. ~~**AES-256 local database encryption.**~~ **Resolved as a documented
   decision, not implemented as SQLCipher.** Researched properly rather
   than attempted blind: `aiosqlite` (used throughout this async backend)
   has no supported path to SQLCipher, which is a synchronous SQLAlchemy
   dialect. The misleading `sqlcipher3-binary` line has been removed from
   `requirements.txt`. Real guidance is now in `ADMIN_MANUAL.md`'s
   "Encryption at rest" section: OS/disk-level encryption
   (BitLocker/FileVault/LUKS/mobile device encryption) needs no application
   changes and protects more than just this one file. True SQLCipher
   support would mean moving off the async engine entirely - scope that as
   its own project if a hard compliance requirement ever demands it
   specifically, don't bolt it on.
3. ~~**Notifications.**~~ **Done, in-app only, not push** — `frontend_flutter/lib/screens/notifications_screen.dart`,
   bell icon with an unread badge in `home_shell.dart`. Populated from the
   points in the app that generate a real event: an unknown-component scan,
   import commit/failure/rollback (`import_screen.dart`), and a detected
   catalogue-size change on sync (`AppState._trySyncCatalog`, a row-count
   heuristic, not a true revision diff - said so in the code). Push
   notifications (FCM/APNs, a backend trigger component) remain out of
   scope, as flagged when this item was first written up - a separate
   project, not a natural extension of this one.

**Phase 3 is now fully complete: all three items resolved** - two
implemented (screen lock, notifications), one resolved by researching it
properly and documenting the real answer instead of building something
broken (AES-256 → OS-level disk encryption guidance).**Done when:** each of these is either implemented, or explicitly
descoped with a written reason — "not needed for this deployment" is a
legitimate answer, silently doing nothing is not.

---

## Phase 4 — Measure what's only been assumed

The performance section of the audit has three unmeasured claims. This
phase is about getting real numbers, not necessarily hitting the original
spec's exact targets (2 seconds, 95%, 1,000,000 rows) — but you should
*know* the real numbers before calling this done.

1. **Scan latency.** Time `POST /scan` end to end against a realistic
   catalogue size, from a real device on real (not localhost) network
   conditions. The matching cascade's cheap layers should already be fast;
   confirm it.
2. **OCR accuracy.** This needs a labeled test set that doesn't exist yet —
   a folder of real chip photos with known-correct markings. Without that,
   "95% accuracy" is unmeasurable, not just unmeasured. Building that test
   set (even 50-100 photos across a range of lighting/angle/glare
   conditions) is the actual prerequisite, not a nice-to-have.
3. **Catalogue scale.** Generate or source a synthetic dataset in the tens
   or hundreds of thousands of rows (not 1,000,000 unless you actually have
   that much real data), load it, and confirm `ComponentIndex`'s trigram
   blocking holds up — watch memory (it's all in-process) as much as
   latency.

**Done when:** you have real numbers for all three, written down, not
assumed from the design being "the right shape."

---

## Phase 5 — Release

1. **Sign the release build properly** — not Flutter's debug keystore. See
   `FLUTTER_TESTING.md`'s signing section for the five-minute `keytool`
   setup.
2. **Deploy the backend for real** — `docker-compose.yml` with Caddy
   already handles TLS; follow `DEPLOY.md` end to end on the actual server
   this will run on, not just locally. Take a backup immediately after the
   first successful `load_seed`/import, before anyone starts scanning
   against it.
3. **Roll out with the manuals.** `USER_MANUAL.md` for inspectors,
   `ADMIN_MANUAL.md` for whoever administers it — both are written against
   the app as it actually behaves, not the original spec, so they should
   hold up as real training material once Phase 2's screens exist to match
   what the manuals already describe conceptually.
4. **If distributing outside your own team:** app store submission
   (Google Play / Apple App Store) has its own review process and
   requirements (privacy policy, data-safety declarations, icons in every
   required size) not covered anywhere in this project — budget real time
   for it if that's the plan, separate from the engineering work above.

---

## What I'd actually do first, if it were me

Phase 1, in full, today — you cannot safely plan Phase 4 on a codebase that
has never been compiled. Phases 2 and 3 are now both fully first-pass
complete (all five screens, plus screen lock, encryption-at-rest guidance,
and notifications); none of it has been through a compiler yet. That gap
is the single biggest risk in this project right now, bigger than any
remaining feature or measurement work - see the caveat at the top of
`REQUIREMENTS_AUDIT.md`. Once Phase 1 is clean, Phase 4's OCR-accuracy test
set is the next thing that has no shortcut - it needs real photos of real
chips, which nothing in this sandbox could ever produce.
