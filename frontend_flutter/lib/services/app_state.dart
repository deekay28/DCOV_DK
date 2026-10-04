import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:uuid/uuid.dart';
import '../models/models.dart';
import 'api_client.dart';
import 'catalog_service.dart';
import 'local_store.dart';
import 'marking.dart';
import 'matching.dart';

/// Where a result came from - shown on every result so a field user never
/// mistakes a device-only check for a centrally recorded one.
class ScanStatus {
  /// The server ran the cascade on its live catalogue and stored the record.
  static const onlineVerified = 'online_verified';
  /// Verdict computed on this device; queued, will be recorded on the server
  /// at the next sync.
  static const pendingSync = 'pending_sync';
  /// Not signed in: device-only result, never recorded centrally.
  static const localOnly = 'local_only';
}

class VerifyOutcome {
  final MatchResult match;
  /// The verdict computed on this device from its catalogue copy.
  final Verdict localVerdict;
  /// The server's verdict, when the scan was recorded online.
  final Verdict? serverVerdict;
  final int elapsedMs;
  final HistoryEntry entry;
  /// Anti-remark findings from the package's other marking lines. Empty for
  /// typed/barcode entries that carry only the part number.
  final MarkingAnalysis marking;
  final String status;
  final String scanId;
  final String clientUuid;
  final String operator;
  final DateTime at;
  /// Server-side notes (replay notice etc.) and any disagreement note.
  final List<String> serverNotes;
  /// A previous scan of the same marking in the last 10 minutes, if any.
  final HistoryEntry? repeatOf;
  final String syncError;
  VerifyOutcome(this.match, this.localVerdict, this.elapsedMs, this.entry, {
    MarkingAnalysis? marking, this.serverVerdict, this.status = ScanStatus.localOnly,
    this.scanId = '', this.clientUuid = '', this.operator = '', DateTime? at,
    this.serverNotes = const [], this.repeatOf, this.syncError = '',
  })  : marking = marking ?? MarkingAnalysis(),
        at = at ?? DateTime.now();

  /// What the result screen shows: the server's verdict when there is one
  /// (authoritative - live catalogue), otherwise the device's.
  Verdict get verdict => serverVerdict ?? localVerdict;
}

/// Single source of truth for the running app. Deliberately a plain
/// ChangeNotifier consumed via ListenableBuilder rather than a state
/// management package - the app's state shape is small enough that a
/// dependency isn't buying anything.
class AppState extends ChangeNotifier {
  final LocalStore store;
  final CatalogService catalog = CatalogService();
  late DcovApiClient api;
  final ComponentMatcher _matcher = ComponentMatcher();
  final _uuid = const Uuid();

  Session? session;
  /// True only when the backend actually answered /health recently - not
  /// merely "the phone has Wi-Fi". Every screen that calls the API keys off
  /// this; a phone on Wi-Fi with the server down is OFFLINE for our purposes.
  bool online = false;
  /// The OS reports some network interface up.
  bool networkUp = false;
  DateTime? lastServerContact;
  String serverStatusDetail = '';
  bool booting = true;
  Timer? _healthTimer;
  bool _syncing = false;
  String themeMode = 'dark';
  final List<HistoryEntry> history = [];
  String? lastError;
  final List<AppNotification> notifications = [];
  final Set<String> _notifiedUnknownMarkings = {};

  // The inspection new scans are attributed to, if any. Verify still works
  // exactly the same with no active inspection - this is purely additive
  // metadata threaded onto api.scan()'s inspection_id, for whoever wants to
  // group a teardown's scans under one inspection record and sign off on
  // them together (see inspections_screen.dart).
  String? activeInspectionId;
  String? activeInspectionNumber;

  // --------------------------------------------------------- screen lock -- //
  // Deliberately a *local* lock, not a forced server re-authentication -
  // see the comment on LocalStore.appLockPin for why: this has to work with
  // zero network, or it strands a field user at the exact moment they're
  // most likely to be out of signal. The server session/token is untouched
  // by locking; this only blocks the UI until the local PIN is re-entered.
  bool locked = false;
  Timer? _lockTimer;

  bool get appLockEnabled => _appLockPinCache != null;
  String? _appLockPinCache;
  int get autoLockMinutes => store.autoLockMinutes;

  Future<void> _loadAppLockState() async {
    _appLockPinCache = await store.appLockPin();
  }

  Future<void> setAppLockPin(String pin) async {
    await store.setAppLockPin(pin);
    _appLockPinCache = pin;
    _armInactivityTimer();
    notifyListeners();
  }

  Future<void> disableAppLock() async {
    await store.setAppLockPin(null);
    _appLockPinCache = null;
    _lockTimer?.cancel();
    notifyListeners();
  }

  Future<void> setAutoLockMinutes(int minutes) async {
    await store.setAutoLockMinutes(minutes);
    _armInactivityTimer();
    notifyListeners();
  }

  /// Called from the root activity gate (see main.dart) on any pointer
  /// event, and from anywhere else that counts as "the user is still here"
  /// (e.g. a completed scan). A no-op while already locked or app-lock
  /// isn't configured, so this is safe to call unconditionally and often.
  void recordActivity() {
    if (locked || !appLockEnabled) return;
    _armInactivityTimer();
  }

  void _armInactivityTimer() {
    _lockTimer?.cancel();
    if (!appLockEnabled || autoLockMinutes <= 0) return;
    _lockTimer = Timer(Duration(minutes: autoLockMinutes), _lock);
  }

  void _lock() {
    if (!appLockEnabled) return; // never lock with no way to unlock again
    locked = true;
    notifyListeners();
  }

  /// True/false, not a throw - a wrong screen-lock PIN is an expected,
  /// frequent event (fat fingers), not an exceptional one.
  bool tryUnlock(String pin) {
    if (_appLockPinCache != null && pin == _appLockPinCache) {
      locked = false;
      _armInactivityTimer();
      notifyListeners();
      return true;
    }
    return false;
  }

  AppState(this.store) {
    api = DcovApiClient(baseUrl: store.baseUrl);
    themeMode = store.themeMode;
  }

  /// Signed in = holding a session that can still be renewed. An expired
  /// *access* token is not a sign-out: it is refreshed (ensureFreshToken).
  /// Treating it as one used to stop offline scans being queued at all once
  /// 30 minutes had passed since sign-in.
  bool get isLoggedIn => session != null;

  Future<void> boot() async {
    booting = true;
    notifyListeners();
    await catalog.loadBundled();
    await catalog.loadCached(); // last server catalogue, if this device has one
    history
      ..clear()
      ..addAll(store.loadHistory());
    notifications
      ..clear()
      ..addAll(store.loadNotifications());
    try {
      session = await store.loadSession();
    } catch (_) {
      session = null; // unreadable secure storage (e.g. restored backup): sign in again
    }
    if (session != null) api.accessToken = session!.accessToken;
    await _loadAppLockState();
    _armInactivityTimer();

    try {
      Connectivity().onConnectivityChanged.listen((results) {
        networkUp = !results.contains(ConnectivityResult.none);
        unawaited(checkServer());
      });
      final results = await Connectivity().checkConnectivity();
      networkUp = !results.contains(ConnectivityResult.none);
    } catch (_) {
      networkUp = true; // plugin unavailable on this platform: just probe
    }
    booting = false;
    notifyListeners();
    // Probe after first frame; never block start-up on the network.
    unawaited(checkServer());
    _healthTimer = Timer.periodic(const Duration(seconds: 30), (_) => checkServer());
  }

  /// Probes the backend. Transitions to reachable trigger a catalogue sync
  /// and a flush of the offline queue; the access token is renewed shortly
  /// before it expires so screens calling the API directly keep working.
  Future<void> checkServer() async {
    final was = online;
    if (!store.hasBaseUrl) {
      online = false;
      serverStatusDetail = 'No server address set (Settings).';
    } else if (!networkUp) {
      online = false;
      serverStatusDetail = 'No network connection.';
    } else {
      try {
        await api.health();
        online = true;
        lastServerContact = DateTime.now();
        serverStatusDetail = 'Server reachable.';
      } catch (e) {
        online = false;
        serverStatusDetail = 'Server not reachable at ${store.baseUrl}.';
      }
    }
    if (online != was) notifyListeners();
    if (online) {
      if (session != null &&
          session!.expiresAt.difference(DateTime.now()) < const Duration(minutes: 3)) {
        await ensureFreshToken();
      }
      if (!was && isLoggedIn) await _onCameOnline();
    }
  }

  /// Renews the access token with the refresh token when it is expired or
  /// about to be. Returns false if the session can no longer be renewed (the
  /// user must sign in again - queued scans are kept for them).
  Future<bool> ensureFreshToken() async {
    final s = session;
    if (s == null) return false;
    if (s.expiresAt.difference(DateTime.now()) > const Duration(minutes: 2)) return true;
    if (!online) return false;
    try {
      final next = await api.refresh(s);
      session = next;
      await store.saveSession(next);
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      if (e.statusCode == 401) {
        session = null;
        api.accessToken = null;
        await store.clearSession();
        final n = pendingSyncCount;
        pushNotification(level: 'warning', title: 'Signed out - session expired',
            body: n > 0 ? 'Sign in again to upload $n scan(s) waiting on this device.'
                        : 'Sign in again to record scans centrally.',
            route: 'settings');
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _onCameOnline() async {
    if (isLoggedIn) {
      await _trySyncCatalog();
      await flushPendingScans();
    }
  }

  Future<void> _trySyncCatalog() async {
    try {
      if (!await ensureFreshToken()) return;
      final before = catalog.counts['total'] ?? 0;
      final n = await catalog.refreshFromServer(api);
      lastError = null;
      if (n > 0) {
        // Row-count changed is a coarse proxy for "the catalogue changed" -
        // there's no client-side db_revision tracking to compare against
        // yet, so this can miss a same-count edit (e.g. one component's
        // origin flipped, nothing added or removed) and can't distinguish
        // growth from a wholesale reimport. Good enough to prompt "you may
        // want to know the catalogue moved"; not a precise diff.
        if (before != 0 && n != before) {
          pushNotification(level: 'info', title: 'Database updated',
              body: '$before \u2192 $n components synced from the server.',
              route: 'dashboard');
        }
        notifyListeners();
      }
    } catch (e) {
      // Non-fatal: keep serving the cached/bundled catalogue offline.
      lastError = 'Catalogue refresh failed: $e';
    }
  }

  /// "UPDATE CATALOGUE NOW" in Settings. The automatic sync on sign-in /
  /// reconnect is silent, so the first device test reported "no option of
  /// updating the catalogue" - this makes the update visible and explains
  /// why it cannot happen while signed out.
  Future<String> updateCatalogueNow() async {
    if (!isLoggedIn) {
      return 'NOT UPDATED - sign in to a DCOV server first. The catalogue is maintained '
          'on the server (admin: Import); the app downloads it from there.';
    }
    try {
      if (!await ensureFreshToken()) {
        return 'NOT UPDATED - session expired. Sign in again.';
      }
      final n = await catalog.refreshFromServer(api);
      lastError = null;
      notifyListeners();
      return n > 0
          ? 'CATALOGUE UPDATED - $n components downloaded from the server and saved for offline use.'
          : 'NOT UPDATED - the server returned an empty catalogue; keeping the current one.';
    } catch (e) {
      return 'UPDATE FAILED - $e. Keeping the current catalogue.';
    }
  }

  // -------------------------------------------------------- notifications -- //
  int get unreadNotificationCount => notifications.where((n) => !n.read).length;

  void pushNotification({
    required String level, required String title, String body = '', String route = '',
  }) {
    notifications.insert(0, AppNotification(
      id: _uuid.v4(), at: DateTime.now(), level: level, title: title, body: body, route: route,
    ));
    if (notifications.length > 100) notifications.removeRange(100, notifications.length);
    store.saveNotifications(notifications);
    notifyListeners();
  }

  void markNotificationRead(String id) {
    AppNotification? target;
    for (final n in notifications) {
      if (n.id == id) { target = n; break; }
    }
    if (target == null || target.read) return;
    target.read = true;
    store.saveNotifications(notifications);
    notifyListeners();
  }

  void markAllNotificationsRead() {
    if (notifications.every((n) => n.read)) return;
    for (final n in notifications) {
      n.read = true;
    }
    store.saveNotifications(notifications);
    notifyListeners();
  }

  void clearNotifications() {
    notifications.clear();
    store.saveNotifications(notifications);
    notifyListeners();
  }

  // ------------------------------------------------------------- auth -- //
  Future<void> login(String username, String password) async {
    final s = await api.login(username, password, store.deviceId);
    session = s;
    await store.saveSession(s);
    online = true;
    lastServerContact = DateTime.now();
    unawaited(_trySyncCatalog());
    unawaited(flushPendingScans());
    notifyListeners();
  }

  Future<void> logout() async {
    await api.logout();
    session = null;
    api.accessToken = null;
    await store.clearSession();
    // A PIN is meaningless without a session to unlock, and leaving it
    // enrolled would let the *next* person to open the app on this device
    // see "sign in with PIN for <departed user>" - clear it on sign-out.
    await store.setPinUsername(null);
    // Same reasoning: an active inspection is tied to whoever created it -
    // the next person to sign in on this device should not silently start
    // attributing scans to a departed inspector's open inspection.
    activeInspectionId = null;
    activeInspectionNumber = null;
    notifyListeners();
  }

  /// Whether this device can offer a PIN quick-login for the given username
  /// (i.e. a PIN was previously enrolled here and nobody has signed out
  /// since). Does not by itself prove the server will still accept it - the
  /// server is the source of truth for trusted_device_ids; this is purely a
  /// "should the login screen show the PIN field" hint.
  String? get pinEnrolledUsername => store.pinUsername;

  /// Enrolls a PIN for quick unlock on this device. Requires an active
  /// password-authenticated session - see api.setPin's doc comment.
  Future<void> setupPin(String pin) async {
    if (!isLoggedIn) {
      throw StateError('Sign in with your password before setting up a PIN.');
    }
    await api.setPin(pin);
    await store.setPinUsername(session!.username);
    notifyListeners();
  }

  Future<void> disablePin() async {
    await store.setPinUsername(null);
    notifyListeners();
  }

  Future<void> loginWithPin(String username, String pin) async {
    try {
      final s = await api.loginPin(username, pin, store.deviceId);
      session = s;
      await store.saveSession(s);
      unawaited(_trySyncCatalog());
      unawaited(flushPendingScans());
      notifyListeners();
    } on ApiException catch (e) {
      if (e.statusCode == 401) {
        // Either the PIN was wrong, or the server no longer trusts this
        // device for this user (e.g. an admin reset their account). Either
        // way, offering PIN login again would just repeat the same failure -
        // fall back to full password login on the next attempt.
        await store.setPinUsername(null);
      }
      rethrow;
    }
  }

  /// Normalises what a user typically types ("192.168.1.20:8000") into a
  /// usable URL. Returns null if it cannot be one.
  static String? normaliseServerUrl(String input) {
    var u = input.trim();
    if (u.isEmpty) return '';
    if (!u.startsWith('http://') && !u.startsWith('https://')) u = 'http://$u';
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    if (u.endsWith('/api/v1')) u = u.substring(0, u.length - 7);
    final parsed = Uri.tryParse(u);
    if (parsed == null || parsed.host.isEmpty) return null;
    return u;
  }

  Future<void> setBaseUrl(String url) async {
    final clean = normaliseServerUrl(url) ?? url.trim();
    await store.setBaseUrl(clean);
    api.baseUrl = clean;
    notifyListeners();
    unawaited(checkServer());
  }

  /// "Test connection" in Settings: probes [url] without saving it.
  Future<String> testServer(String url) async {
    final clean = normaliseServerUrl(url);
    if (clean == null || clean.isEmpty) return 'CONNECTION FAILED - not a valid address.';
    final probe = DcovApiClient(baseUrl: clean);
    try {
      final h = await probe.health(within: const Duration(seconds: 6));
      final rows = (h['index'] as Map?)?['rows'];
      return 'CONNECTED - DCOV ${h['version'] ?? ''} answering'
          '${rows != null ? ', $rows components in its catalogue' : ''}.';
    } catch (e) {
      return 'CONNECTION FAILED - no answer from $clean. Same Wi-Fi as the server? Server started with '
          'run_lan_server? Firewall allowing the port? ($e)';
    } finally {
      probe.close();
    }
  }

  Future<void> changePassword(String current, String next) async {
    await api.changePassword(current, next);
    final s = session;
    if (s != null) {
      session = Session(userId: s.userId, username: s.username, role: s.role,
          accessToken: s.accessToken, refreshToken: s.refreshToken,
          expiresAt: s.expiresAt, mustChangePassword: false);
      await store.saveSession(session!);
    }
    notifyListeners();
  }

  Future<void> setThemeMode(String mode) async {
    themeMode = mode;
    await store.setThemeMode(mode);
    notifyListeners();
  }

  // ------------------------------------------------------------ verify -- //
  /// Runs the identical offline cascade used by the backend, then - when
  /// signed in and the server is reachable - records the scan on the server
  /// and shows the server's verdict (live catalogue, authoritative). Offline,
  /// the device verdict is shown, clearly marked PENDING SYNC, and the scan is
  /// queued with its capture time and evidence for upload later.
  Future<VerifyOutcome> verify(String raw, {String mode = 'manual', String ocrText = '',
      String imageRef = '', String symbology = ''}) async {
    recordActivity();
    final sw = Stopwatch()..start();
    final at = DateTime.now();
    final match = _matcher.match(raw, catalog.index);
    final c = match.component;
    // Same check the server runs (backend/app/services/marking.py), so the
    // offline verdict matches the online one for the same marking.
    final marking = analyseMarking(ocrText.isNotEmpty ? ocrText : raw,
        manufacturer: c?['manufacturer']?.toString(),
        partKey: (c?['chip_number']?.toString().isNotEmpty ?? false)
            ? c!['chip_number'].toString() : c?['part_number']?.toString(),
        catalogueIsChinese: c?['is_chinese']?.toString());
    final local = applyMarkingToVerdict(verdictFor(c, match.score, match.method), marking);

    // Repeated scan of the same marking: flagged, never silently merged -
    // a second identical part on the same board is a legitimate new scan.
    HistoryEntry? repeatOf;
    for (final h in history) {
      if (at.difference(h.at) > const Duration(minutes: 10)) break;
      if (h.normalized.isNotEmpty && h.normalized == match.normalizedInput) {
        repeatOf = h;
        break;
      }
    }

    final clientUuid = _uuid.v4();
    final operator = session?.username ?? '';
    var status = ScanStatus.localOnly;
    Verdict? serverVerdict;
    var scanId = '';
    var syncError = '';
    final serverNotes = <String>[];
    final payload = <String, dynamic>{
      'client_uuid': clientUuid, 'input_mode': mode, 'raw_input': raw,
      'ocr_text': ocrText, 'device_id': store.deviceId,
      'scanned_at': at.toUtc().toIso8601String(),
      if (activeInspectionId != null) 'inspection_id': activeInspectionId,
      if (imageRef.isNotEmpty) 'image_ref': imageRef,
      if (symbology.isNotEmpty) 'barcode_symbology': symbology,
      'operator': operator,
    };

    if (session != null) {
      if (online && await ensureFreshToken()) {
        try {
          final res = await api.scan(
            clientUuid: clientUuid, inputMode: mode, rawInput: raw, ocrText: ocrText,
            deviceId: store.deviceId, inspectionId: activeInspectionId,
            imageRef: imageRef, barcodeSymbology: symbology,
            scannedAt: at.toUtc().toIso8601String());
          serverVerdict = Verdict.fromServer(res);
          scanId = res['scan_id']?.toString() ?? '';
          status = ScanStatus.onlineVerified;
          serverNotes.addAll(((res['notes'] as List?) ?? const []).map((e) => e.toString()));
          if (serverVerdict.banner != local.banner) {
            serverNotes.add('This device\'s catalogue copy gave ${local.banner}; the server\'s '
                'live catalogue gives ${serverVerdict.banner}. The server result is shown. '
                'Sync the catalogue (it refreshes automatically when online).');
            unawaited(_trySyncCatalog());
          }
        } on ApiException catch (e) {
          if (e.statusCode == 401 || e.statusCode >= 500 || e.statusCode == 429) {
            await _queuePendingScan(payload);
            status = ScanStatus.pendingSync;
            syncError = e.message;
          } else {
            // 4xx: the server refused this request as given - retrying the
            // same payload would fail forever, so it is not queued.
            syncError = 'Not recorded on the server: ${e.message}';
          }
        } catch (e) {
          await _queuePendingScan(payload);
          status = ScanStatus.pendingSync;
          syncError = 'Server unreachable - queued.';
        }
      } else {
        await _queuePendingScan(payload);
        status = ScanStatus.pendingSync;
      }
    }
    sw.stop();
    final shown = serverVerdict ?? local;

    final entry = HistoryEntry(
      at: at, raw: raw, normalized: match.normalizedInput,
      result: shown.result, method: match.method, score: match.score,
      componentId: match.component?['component_id']?.toString() ?? '',
      componentName: match.component?['component_name']?.toString() ?? '',
      mode: mode, synced: status == ScanStatus.onlineVerified,
      clientUuid: clientUuid, scanId: scanId, status: status,
      banner: shown.banner, operator: operator,
    );
    history.insert(0, entry);
    if (history.length > 2000) history.removeRange(2000, history.length);
    await store.saveHistory(history);

    if (shown.result == 'not_found' && match.normalizedInput.isNotEmpty
        && _notifiedUnknownMarkings.add(match.normalizedInput)) {
      // .add() returns false if already present - the dedupe and the
      // "should I notify" check are the same operation, on purpose, so a
      // repeatedly-rescanned unknown part doesn't spam the notification
      // center every time someone re-tries the same marking.
      pushNotification(level: 'warning', title: 'Unknown component',
          body: '"${entry.raw}" was not found in the catalogue.'
              '${status == ScanStatus.onlineVerified ? ' Queued for review.' : ''}',
          route: 'catalog');
    }
    notifyListeners();

    return VerifyOutcome(match, local, sw.elapsedMilliseconds, entry,
        marking: marking, serverVerdict: serverVerdict, status: status, scanId: scanId,
        clientUuid: clientUuid, operator: operator, at: at, serverNotes: serverNotes,
        repeatOf: repeatOf, syncError: syncError);
  }

  Future<void> _queuePendingScan(Map<String, dynamic> payload) async {
    final pending = store.loadPendingScans();
    if (pending.any((p) => p['client_uuid'] == payload['client_uuid'])) return;
    pending.add(payload);
    await store.savePendingScans(pending);
  }

  /// Uploads queued scans through /sync/push (batched, idempotent by
  /// client_uuid). Only scans captured by the signed-in user are sent, so a
  /// scan is never attributed to a different inspector than the one who made
  /// it; others stay queued until their own operator signs in.
  Future<int> flushPendingScans() async {
    if (_syncing || session == null || !online) return 0;
    _syncing = true;
    var uploaded = 0;
    try {
      if (!await ensureFreshToken()) return 0;
      final me = session!.username;
      var pending = store.loadPendingScans();
      final mine = pending.where((p) => (p['operator'] ?? me) == me).toList();
      for (var i = 0; i < mine.length; i += 100) {
        final batch = mine.sublist(i, i + 100 > mine.length ? mine.length : i + 100);
        final body = batch.map((p) => Map<String, dynamic>.from(p)..remove('operator')).toList();
        final res = await api.syncPush(store.deviceId, body);
        final details = (res['details'] as Map?) ?? const {};
        final done = <String, String>{}; // client_uuid -> scan_id ('' for duplicates)
        for (final a in (details['accepted'] as List? ?? const [])) {
          done[(a as Map)['client_uuid'].toString()] = a['scan_id']?.toString() ?? '';
        }
        for (final d in (details['duplicates'] as List? ?? const [])) {
          done[d.toString()] = '';
        }
        pending = pending.where((p) => !done.containsKey(p['client_uuid'])).toList();
        await store.savePendingScans(pending);
        for (var h = 0; h < history.length; h++) {
          final e = history[h];
          if (done.containsKey(e.clientUuid)) {
            history[h] = e.copyWith(synced: true, status: ScanStatus.onlineVerified,
                scanId: done[e.clientUuid]!.isNotEmpty ? done[e.clientUuid] : e.scanId);
          }
        }
        uploaded += done.length;
      }
      if (uploaded > 0) {
        await store.saveHistory(history);
        pushNotification(level: 'info', title: 'Offline scans synchronised',
            body: '$uploaded scan(s) recorded on the server.', route: 'history');
      }
    } catch (e) {
      lastError = 'Sync failed: $e'; // stays queued; retried on next contact
    } finally {
      _syncing = false;
      notifyListeners();
    }
    return uploaded;
  }

  // ------------------------------------------------------- inspections -- //
  /// Creates an inspection server-side and makes it the active one - every
  /// scan from here on (online or queued offline) carries its inspection_id
  /// until [clearActiveInspection] or [setActiveInspection] changes it.
  Future<Map<String, dynamic>> startInspection({
    String title = '', String platform = '', String serialNumber = '',
    String location = '', double? latitude, double? longitude, String remarks = '',
  }) async {
    final insp = await api.createInspection(
      title: title, platform: platform, serialNumber: serialNumber,
      location: location, latitude: latitude, longitude: longitude, remarks: remarks,
    );
    activeInspectionId = insp['id'] as String;
    activeInspectionNumber = insp['inspection_number'] as String;
    notifyListeners();
    return insp;
  }

  /// Points new scans at an inspection that already exists (e.g. resuming
  /// one picked from the list) without creating a new one.
  void setActiveInspection(String id, String number) {
    activeInspectionId = id;
    activeInspectionNumber = number;
    notifyListeners();
  }

  void clearActiveInspection() {
    activeInspectionId = null;
    activeInspectionNumber = null;
    notifyListeners();
  }

  Future<void> clearHistory() async {
    history.clear();
    await store.saveHistory(history);
    notifyListeners();
  }

  int get pendingSyncCount => store.loadPendingScans().length;

  @override
  void dispose() {
    _lockTimer?.cancel();
    _healthTimer?.cancel();
    super.dispose();
  }
}
