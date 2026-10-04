import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show compute;

/// Offline (device-only) user accounts - for running DCOV with no server.
///
/// Security model, stated plainly: these accounts protect against someone
/// picking up an unattended phone and attributing scans to the wrong person.
/// They are NOT a substitute for server accounts: an attacker with root on the
/// device can bypass any on-device check. Passwords are never stored - only a
/// PBKDF2-HMAC-SHA256 hash with a random 16-byte salt per account - and the
/// account list lives in the OS keystore-backed secure storage.
///
/// Roles mirror the server's (backend/app/models/schemas.py) so the same
/// permission names mean the same thing on and off the network.

class LocalAuthException implements Exception {
  final String message;
  LocalAuthException(this.message);
  @override
  String toString() => message;
}

class LocalUser {
  final String username;
  final String role;
  final bool mustChangePassword;
  const LocalUser(this.username, this.role, {this.mustChangePassword = false});

  bool get canImportCatalogue => role == 'administrator' || role == 'database_manager';
  bool get canManageUsers => role == 'administrator';

  Map<String, dynamic> toJson() =>
      {'username': username, 'role': role, 'must_change_password': mustChangePassword};
  static LocalUser? fromJson(Map<String, dynamic>? j) {
    if (j == null || j['username'] == null) return null;
    return LocalUser(j['username'].toString(), (j['role'] ?? 'viewer').toString(),
        mustChangePassword: j['must_change_password'] == true);
  }
}

class LocalAccountRecord {
  final String username; // stored lower-case
  final String role;
  final String salt; // base64
  final String hash; // base64
  final int iterations;
  final String createdAt;
  final bool disabled;
  final bool mustChangePassword;

  const LocalAccountRecord({
    required this.username, required this.role, required this.salt, required this.hash,
    required this.iterations, required this.createdAt, this.disabled = false,
    this.mustChangePassword = false,
  });

  LocalAccountRecord copyWith({String? role, String? salt, String? hash, int? iterations,
          bool? disabled, bool? mustChangePassword}) =>
      LocalAccountRecord(
        username: username, role: role ?? this.role, salt: salt ?? this.salt,
        hash: hash ?? this.hash, iterations: iterations ?? this.iterations,
        createdAt: createdAt, disabled: disabled ?? this.disabled,
        mustChangePassword: mustChangePassword ?? this.mustChangePassword,
      );

  Map<String, dynamic> toJson() => {
        'username': username, 'role': role, 'salt': salt, 'hash': hash,
        'iterations': iterations, 'created_at': createdAt, 'disabled': disabled,
        'must_change_password': mustChangePassword,
      };

  static LocalAccountRecord fromJson(Map<String, dynamic> j) => LocalAccountRecord(
        username: j['username'].toString(), role: (j['role'] ?? 'viewer').toString(),
        salt: j['salt'].toString(), hash: j['hash'].toString(),
        iterations: (j['iterations'] as num?)?.toInt() ?? LocalAccounts.defaultIterations,
        createdAt: (j['created_at'] ?? '').toString(), disabled: j['disabled'] == true,
        mustChangePassword: j['must_change_password'] == true,
      );
}

/// PBKDF2-HMAC-SHA256 (RFC 8018). Verified in test/local_accounts_test.dart
/// against the published RFC 7914 section 11 test vectors.
Uint8List pbkdf2Sha256(List<int> password, List<int> salt, int iterations, int dkLen) {
  final hmac = Hmac(sha256, password);
  final blocks = (dkLen + 31) ~/ 32;
  final out = <int>[];
  for (var i = 1; i <= blocks; i++) {
    final first = <int>[...salt, (i >> 24) & 0xff, (i >> 16) & 0xff, (i >> 8) & 0xff, i & 0xff];
    var u = hmac.convert(first).bytes;
    final t = Uint8List.fromList(u);
    for (var j = 1; j < iterations; j++) {
      u = hmac.convert(u).bytes;
      for (var k = 0; k < t.length; k++) {
        t[k] ^= u[k];
      }
    }
    out.addAll(t);
  }
  return Uint8List.fromList(out.sublist(0, dkLen));
}

class _HashArgs {
  final String password;
  final List<int> salt;
  final int iterations;
  const _HashArgs(this.password, this.salt, this.iterations);
}

List<int> _hashEntry(_HashArgs a) => pbkdf2Sha256(utf8.encode(a.password), a.salt, a.iterations, 32);

/// Runs the deliberately slow hash off the UI thread.
Future<List<int>> isolateHasher(String password, List<int> salt, int iterations) =>
    compute(_hashEntry, _HashArgs(password, salt, iterations));

typedef SecretReader = Future<String?> Function(String key);
typedef SecretWriter = Future<void> Function(String key, String? value);
typedef PasswordHasher = Future<List<int>> Function(String password, List<int> salt, int iterations);

class LocalAccounts {
  static const storageKey = 'dcov.local_accounts.v1';
  static const roles = ['administrator', 'database_manager', 'inspector', 'viewer'];
  static const defaultIterations = 60000;
  static const maxFailures = 5;
  static const lockout = Duration(seconds: 60);

  final SecretReader _read;
  final SecretWriter _write;
  final PasswordHasher _hasher;
  final int _iterations;
  final Random _rng;

  List<LocalAccountRecord> _accounts = [];
  bool _loaded = false;
  final Map<String, int> _failures = {};
  final Map<String, DateTime> _lockedUntil = {};

  LocalAccounts(this._read, this._write,
      {PasswordHasher? hasher, int iterations = defaultIterations, Random? random})
      : _hasher = hasher ?? isolateHasher,
        _iterations = iterations,
        _rng = random ?? Random.secure();

  bool get loaded => _loaded;
  bool get hasAccounts => _accounts.isNotEmpty;
  List<LocalAccountRecord> get accounts => List.unmodifiable(_accounts);

  Future<void> load() async {
    try {
      final raw = await _read(storageKey);
      if (raw != null && raw.isNotEmpty) {
        _accounts = (jsonDecode(raw) as List)
            .map((e) => LocalAccountRecord.fromJson((e as Map).cast<String, dynamic>()))
            .toList();
      }
    } catch (_) {
      // Unreadable (e.g. restored backup without its keystore key): start
      // empty rather than crash. The admin can recreate accounts.
      _accounts = [];
    }
    _loaded = true;
  }

  Future<void> _save() =>
      _write(storageKey, jsonEncode(_accounts.map((a) => a.toJson()).toList()));

  static String? validateUsername(String u) {
    final v = u.trim();
    if (v.length < 3 || v.length > 32) return 'Username must be 3-32 characters.';
    if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(v)) {
      return 'Username may contain letters, digits, dot, dash and underscore only.';
    }
    return null;
  }

  static String? validatePassword(String p, {String username = ''}) {
    if (p.length < 8) return 'Password must be at least 8 characters.';
    if (p.length > 128) return 'Password is too long.';
    if (RegExp(r'^(.)\1*$').hasMatch(p)) return 'Password cannot be one repeated character.';
    if (username.isNotEmpty && p.toLowerCase() == username.trim().toLowerCase()) {
      return 'Password cannot be the username.';
    }
    return null;
  }

  LocalAccountRecord? find(String username) {
    final u = username.trim().toLowerCase();
    for (final a in _accounts) {
      if (a.username == u) return a;
    }
    return null;
  }

  int get _enabledAdmins =>
      _accounts.where((a) => a.role == 'administrator' && !a.disabled).length;

  Future<(String, String)> _hashNew(String password) async {
    final salt = List<int>.generate(16, (_) => _rng.nextInt(256));
    final h = await _hasher(password, salt, _iterations);
    return (base64Encode(salt), base64Encode(h));
  }

  Future<void> create(String username, String password, String role,
      {bool mustChangePassword = false}) async {
    final uErr = validateUsername(username);
    if (uErr != null) throw LocalAuthException(uErr);
    final pErr = validatePassword(password, username: username);
    if (pErr != null) throw LocalAuthException(pErr);
    if (!roles.contains(role)) throw LocalAuthException('Unknown role "$role".');
    if (!hasAccounts && role != 'administrator') {
      throw LocalAuthException('The first offline account must be an administrator.');
    }
    if (find(username) != null) throw LocalAuthException('That username already exists on this device.');
    final (salt, hash) = await _hashNew(password);
    _accounts.add(LocalAccountRecord(
      username: username.trim().toLowerCase(), role: role, salt: salt, hash: hash,
      iterations: _iterations, createdAt: DateTime.now().toUtc().toIso8601String(),
      mustChangePassword: mustChangePassword,
    ));
    await _save();
  }

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  Future<LocalUser> authenticate(String username, String password, {DateTime? now}) async {
    final t = now ?? DateTime.now();
    final key = username.trim().toLowerCase();
    final until = _lockedUntil[key];
    if (until != null && t.isBefore(until)) {
      throw LocalAuthException('Too many wrong attempts. Try again in '
          '${until.difference(t).inSeconds + 1} s.');
    }
    final rec = find(key);
    // Hash even for unknown users so timing does not reveal which names exist.
    final salt = rec != null ? base64Decode(rec.salt) : List<int>.filled(16, 0);
    final got = await _hasher(password, salt, rec?.iterations ?? _iterations);
    if (rec == null || !_constantTimeEquals(got, base64Decode(rec.hash))) {
      final n = (_failures[key] ?? 0) + 1;
      _failures[key] = n;
      if (n >= maxFailures) {
        _lockedUntil[key] = t.add(lockout);
        _failures[key] = 0;
      }
      throw LocalAuthException('Wrong username or password.');
    }
    if (rec.disabled) throw LocalAuthException('This account is disabled on this device.');
    _failures.remove(key);
    _lockedUntil.remove(key);
    return LocalUser(rec.username, rec.role, mustChangePassword: rec.mustChangePassword);
  }

  Future<void> changePassword(String username, String current, String next) async {
    await authenticate(username, current);
    final pErr = validatePassword(next, username: username);
    if (pErr != null) throw LocalAuthException(pErr);
    if (next == current) throw LocalAuthException('Choose a password different from the current one.');
    await _setPassword(username, next, mustChange: false);
  }

  /// Administrator reset: the user must choose a new password at next sign-in.
  Future<void> resetPassword(String username, String temporary) async {
    final pErr = validatePassword(temporary, username: username);
    if (pErr != null) throw LocalAuthException(pErr);
    await _setPassword(username, temporary, mustChange: true);
    _lockedUntil.remove(username.trim().toLowerCase());
  }

  Future<void> _setPassword(String username, String password, {required bool mustChange}) async {
    final i = _accounts.indexWhere((a) => a.username == username.trim().toLowerCase());
    if (i < 0) throw LocalAuthException('No such account.');
    final (salt, hash) = await _hashNew(password);
    _accounts[i] = _accounts[i].copyWith(
        salt: salt, hash: hash, iterations: _iterations, mustChangePassword: mustChange);
    await _save();
  }

  Future<void> setRole(String username, String role) async {
    if (!roles.contains(role)) throw LocalAuthException('Unknown role "$role".');
    final i = _accounts.indexWhere((a) => a.username == username.trim().toLowerCase());
    if (i < 0) throw LocalAuthException('No such account.');
    final a = _accounts[i];
    if (a.role == 'administrator' && role != 'administrator' && !a.disabled && _enabledAdmins <= 1) {
      throw LocalAuthException('This is the last administrator on this device.');
    }
    _accounts[i] = a.copyWith(role: role);
    await _save();
  }

  Future<void> setDisabled(String username, bool disabled) async {
    final i = _accounts.indexWhere((a) => a.username == username.trim().toLowerCase());
    if (i < 0) throw LocalAuthException('No such account.');
    final a = _accounts[i];
    if (disabled && a.role == 'administrator' && !a.disabled && _enabledAdmins <= 1) {
      throw LocalAuthException('This is the last administrator on this device.');
    }
    _accounts[i] = a.copyWith(disabled: disabled);
    await _save();
  }

  Future<void> delete(String username) async {
    final a = find(username);
    if (a == null) throw LocalAuthException('No such account.');
    if (a.role == 'administrator' && !a.disabled && _enabledAdmins <= 1) {
      throw LocalAuthException('This is the last administrator on this device.');
    }
    _accounts.removeWhere((x) => x.username == a.username);
    await _save();
  }
}
