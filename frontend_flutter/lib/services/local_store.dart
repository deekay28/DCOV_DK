import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/models.dart';

/// Wraps local persistence. Two backends, deliberately split by sensitivity:
///
///  - [FlutterSecureStorage] for the session (access + refresh tokens).
///    Backed by Keystore/Keychain/DPAPI depending on platform - encrypted at
///    rest, not just sandboxed. A refresh token is valid for 7 days; treat it
///    as the credential it is, not as app settings.
///  - [SharedPreferences] for everything else (server address, theme,
///    on-device history log, the offline scan queue, and the PIN-login
///    flags below). None of this is sensitive - the history log duplicates
///    what the server already records, and the PIN flags are just "does a
///    PIN exist for this device", never the PIN itself.
///
/// History/queue stay a JSON blob rather than a SQL table for now - see the
/// note in the class body. A heavier-volume deployment should move that
/// specific piece to sqflite/drift and the backend's /sync/push+pull; the
/// session's storage backend is already the encrypted one regardless.
class LocalStore {
  static const _kBaseUrl = 'dcov.base_url';
  static const _kThemeMode = 'dcov.theme_mode'; // 'dark' | 'light' | 'system'
  static const _kHistory = 'dcov.history';
  static const _kDeviceId = 'dcov.device_id';
  static const _kPendingScans = 'dcov.pending_scans';
  static const _kNotifications = 'dcov.notifications';
  static const _kPinUsername = 'dcov.pin_username'; // set once a PIN is enrolled on this device
  static const _kSecureSessionKey = 'dcov.session'; // key within secure storage
  static const _kAppLockPin = 'dcov.app_lock_pin';   // local screen-lock PIN, secure storage
  static const _kAutoLockMinutes = 'dcov.auto_lock_minutes'; // 0 = disabled

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secure;
  LocalStore._(this._prefs, this._secure);

  static Future<LocalStore> open() async => LocalStore._(
        await SharedPreferences.getInstance(),
        const FlutterSecureStorage(
          aOptions: AndroidOptions(encryptedSharedPreferences: true),
        ),
      );

  // ---- session (secure storage - tokens are real credentials) -------- //
  Future<Session?> loadSession() async {
    final raw = await _secure.read(key: _kSecureSessionKey);
    if (raw == null) return null;
    try {
      return Session.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveSession(Session s) =>
      _secure.write(key: _kSecureSessionKey, value: jsonEncode(s.toJson()));

  Future<void> clearSession() => _secure.delete(key: _kSecureSessionKey);

  // ---- PIN-login availability (not the PIN itself - just "is one set up
  //      on this device, for whom") - fine in plain prefs. The PIN's own
  //      hash lives server-side only; this device never stores it. -------- //
  String? get pinUsername => _prefs.getString(_kPinUsername);
  Future<void> setPinUsername(String? username) => username == null
      ? _prefs.remove(_kPinUsername)
      : _prefs.setString(_kPinUsername, username);

  // ---- screen-lock PIN (distinct from the server-trusted login PIN above).
  //      This one genuinely lives on-device, in secure storage - deliberate
  //      trade-off so the inactivity lock can be unlocked with no network
  //      at all. See AppState's lock/unlock methods for why: a field app
  //      that demands connectivity just to keep using itself, at the exact
  //      moment inactivity has already suggested the user stepped away
  //      from signal, is the wrong failure mode. The threat model this
  //      protects against is someone picking up an unattended unlocked
  //      device, not a network attacker - a locally-stored PIN, itself
  //      protected by the OS Keystore/Keychain, is an appropriate control
  //      for that threat model, same as a phone's own lock screen. ------- //
  Future<String?> appLockPin() => _secure.read(key: _kAppLockPin);
  Future<void> setAppLockPin(String? pin) => pin == null
      ? _secure.delete(key: _kAppLockPin)
      : _secure.write(key: _kAppLockPin, value: pin);

  int get autoLockMinutes => _prefs.getInt(_kAutoLockMinutes) ?? 15;
  Future<void> setAutoLockMinutes(int minutes) => _prefs.setInt(_kAutoLockMinutes, minutes);

  // ---- settings --------------------------------------------------------- //
  /// Empty until the user sets it. There is no sensible default for a phone:
  /// 127.0.0.1 is the phone itself, 10.0.2.2 only exists in the Android
  /// emulator, and the LAN IP of the PC running the backend is site-specific.
  String get baseUrl => _prefs.getString(_kBaseUrl) ?? '';
  bool get hasBaseUrl => baseUrl.trim().isNotEmpty;
  Future<void> setBaseUrl(String v) => _prefs.setString(_kBaseUrl, v);

  String get themeMode => _prefs.getString(_kThemeMode) ?? 'dark';
  Future<void> setThemeMode(String v) => _prefs.setString(_kThemeMode, v);

  String get deviceId {
    var id = _prefs.getString(_kDeviceId);
    if (id == null) {
      id = 'flutter-${DateTime.now().microsecondsSinceEpoch}';
      _prefs.setString(_kDeviceId, id);
    }
    return id;
  }

  // ---- history ------------------------------------------------------- //
  List<HistoryEntry> loadHistory() {
    final raw = _prefs.getStringList(_kHistory) ?? const [];
    return raw.map((s) {
      try {
        return HistoryEntry.fromJson(jsonDecode(s) as Map<String, dynamic>);
      } catch (_) {
        return null;
      }
    }).whereType<HistoryEntry>().toList();
  }

  Future<void> saveHistory(List<HistoryEntry> items) => _prefs.setStringList(
      _kHistory, items.map((e) => jsonEncode(e.toJson())).toList());

  // ---- notification center - capped at 100 on the write side (see
  //      AppState.pushNotification), so this list never needs its own
  //      separate trimming logic here. ------------------------------------ //
  List<AppNotification> loadNotifications() {
    final raw = _prefs.getStringList(_kNotifications) ?? const [];
    return raw.map((s) {
      try {
        return AppNotification.fromJson(jsonDecode(s) as Map<String, dynamic>);
      } catch (_) {
        return null;
      }
    }).whereType<AppNotification>().toList();
  }

  Future<void> saveNotifications(List<AppNotification> items) => _prefs.setStringList(
      _kNotifications, items.map((e) => jsonEncode(e.toJson())).toList());

  // ---- scans queued while offline, replayed once a session goes online -- //
  List<Map<String, dynamic>> loadPendingScans() {
    final raw = _prefs.getStringList(_kPendingScans) ?? const [];
    // One corrupt entry must not make the whole queue unreadable (that used
    // to throw out of boot() and leave every other queued scan stranded).
    return raw.map((s) {
      try {
        return jsonDecode(s) as Map<String, dynamic>;
      } catch (_) {
        return null;
      }
    }).whereType<Map<String, dynamic>>().toList();
  }

  Future<void> savePendingScans(List<Map<String, dynamic>> items) =>
      _prefs.setStringList(
          _kPendingScans, items.map((e) => jsonEncode(e)).toList());
}
