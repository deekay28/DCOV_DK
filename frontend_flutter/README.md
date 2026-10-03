# DCOV field client (Flutter)

Cross-platform inspector app: Android, iOS, Windows, macOS, Linux, web.
Talks to the backend in `../backend`; works fully offline against the
bundled catalogue (`assets/data/components_seed.json`) when it can't.

```bash
flutter create .              # generates android/, ios/, etc. - NOT in this repo, see below
flutter pub get
flutter test                 # matching-engine unit tests, no device needed
flutter run -d chrome        # fastest UI loop
flutter run -d windows       # native desktop
flutter run -d <android-id>  # flutter devices, to list attached phones/emulators
```

**This repo ships `lib/`, `test/`, `assets/`, and `pubspec.yaml` only — no
`android/`/`ios/`/`windows/` platform folders.** Those come from `flutter
create .`, which needs the Flutter SDK itself and so can only be run on your
machine, not in the environment this code was written in. Run it before
anything else. Full detail, including the camera/vibration permissions
`flutter create` doesn't add for you, in
[`../docs/FLUTTER_TESTING.md`](../docs/FLUTTER_TESTING.md).

**Testing steps for Windows and Android (including where Termux does and
doesn't fit) are also in that document.**
Short version: Termux runs the backend on a phone; it cannot build or run
this app. Build from Windows/macOS/Linux; iOS specifically needs a Mac.

## Layout

```
lib/
  main.dart              entry point, theme wiring
  theme/                 design tokens ported from web_demo/index.html
  models/                Component, HistoryEntry, Session
  services/
    matching.dart        offline matching cascade - Dart port of
                          backend/app/services/matching.py and
                          web_demo/dcov-match.js. All three must agree.
    api_client.dart       REST client for the backend
    catalog_service.dart  bundled seed + live catalogue refresh
    local_store.dart      session/settings/history persistence
    app_state.dart        app-wide ChangeNotifier: session, connectivity,
                           the verify() pipeline
  screens/                one file per tab, plus login and the shell
  widgets/                verdict banner + cascade trace, shared
test/
  matching_test.dart      run with `flutter test`
```

## Known gaps

> v1.1.0: on-device OCR (ML Kit) **is now integrated** for Android/iOS, the
> offline queue uploads via `/sync/push`, tokens refresh, and every result
> shows ONLINE VERIFIED / PENDING SYNC / LOCAL ONLY - see ../CHANGELOG.md.
> Android/iOS/Windows folders: `flutter create ...` then
> `python tool/configure_platforms.py` (see ../ANDROID_RELEASE.md).
> The notes below predate that pass.


- Offline scan history is a JSON blob in `shared_preferences`, not a real
  local database. Fine at the volumes a single inspector generates in a
  session; a multi-week-offline deployment should move this to
  `sqflite`/`drift` and use the backend's `/sync/push` and `/sync/pull`
  properly instead of the current best-effort "retry on reconnect" queue in
  `AppState._flushPendingScans`. (Session tokens specifically are *not* in
  this blob - see "Fixed since the last pass" below.)
- No on-device OCR model is bundled (no ML Kit / Tesseract integration yet).
  The chip-photo flow uploads to the backend's OCR endpoint when online and
  otherwise routes straight to manual entry with the photo shown for
  reference. Wiring `google_mlkit_text_recognition` for a true offline OCR
  path is the natural next step for the "photograph chip" button.
- No biometric login yet (`local_auth` isn't wired up) — password and PIN
  login work end to end, including a working Settings screen for PIN
  enrollment; the backend already supports a biometric-assertion endpoint
  (`/auth/login/biometric`) for whenever this is added.
- Not yet checked against a real `flutter analyze`/`flutter build` — I don't
  have the Flutter SDK in the environment this was written in. I checked
  brace/paren/bracket balance and cross-referenced every new symbol against
  its definition by hand (grep, not a compiler) after every change,
  including this pass's, but run `flutter pub get && flutter analyze` as
  your first step and treat anything it flags as more reliable than this
  note.

## Fixed since the last pass

- **Session tokens were in `shared_preferences` in plaintext** (a 7-day
  refresh token, unencrypted, in the same JSON blob as the theme setting).
  Found while wiring up the PIN feature below, not part of any original
  plan - fixed by moving the session specifically to
  `flutter_secure_storage` (Keystore/Keychain/DPAPI depending on platform),
  everything else stays in `shared_preferences`. See the class comment in
  `lib/services/local_store.dart`.
- **PIN login is now real, not just a backend endpoint nobody calls.**
  `screens/settings_screen.dart` enrolls a PIN (requires an active password
  session, calls the backend's now-device-bound `/auth/pin`);
  `screens/login_screen.dart` offers PIN quick-unlock automatically on a
  device that has one enrolled, and falls back to the password form the
  moment the server rejects a PIN (e.g. an admin reset the account, or this
  genuinely isn't a trusted device). See `docs/ADMIN_MANUAL.md` for the
  server-side device-binding fix this depends on.
- Added a Settings screen (gear icon, top bar) — server address, PIN
  enrollment, theme, device ID, pending-sync count, sign-out. Previously
  these were scattered across the login screen and an account bottom sheet
  with no single place to find all of them.
