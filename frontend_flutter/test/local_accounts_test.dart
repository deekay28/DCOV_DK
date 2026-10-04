import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:dcov_field/services/local_accounts.dart';

String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('PBKDF2-HMAC-SHA256 (RFC 7914 section 11 vectors)', () {
    test('c=1', () {
      expect(hex(pbkdf2Sha256(utf8.encode('password'), utf8.encode('salt'), 1, 32)),
          '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b');
    });
    test('c=2', () {
      expect(hex(pbkdf2Sha256(utf8.encode('password'), utf8.encode('salt'), 2, 32)),
          'ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43');
    });
    test('c=4096', () {
      expect(hex(pbkdf2Sha256(utf8.encode('password'), utf8.encode('salt'), 4096, 32)),
          'c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a');
    });
    test('two output blocks', () {
      expect(hex(pbkdf2Sha256(utf8.encode('passwd'), utf8.encode('salt'), 1, 64)).substring(0, 32),
          '55ac046e56e3089fec1691c22544b605');
    });
  });

  group('LocalAccounts', () {
    late Map<String, String?> store;
    late LocalAccounts acc;

    Future<List<int>> fastHash(String p, List<int> s, int it) async =>
        pbkdf2Sha256(utf8.encode(p), s, it, 32);

    setUp(() async {
      store = {};
      acc = LocalAccounts((k) async => store[k], (k, v) async => store[k] = v,
          hasher: fastHash, iterations: 10);
      await acc.load();
    });

    test('first account must be administrator', () async {
      await expectLater(acc.create('alice', 'longpassword1', 'inspector'), throwsA(isA<LocalAuthException>()));
      await acc.create('Admin', 'longpassword1', 'administrator');
      expect(acc.hasAccounts, isTrue);
    });

    test('password is never stored in clear', () async {
      await acc.create('admin', 'S3cretPassw0rd', 'administrator');
      expect(store[LocalAccounts.storageKey], isNot(contains('S3cretPassw0rd')));
    });

    test('sign in: right, wrong, case-insensitive username', () async {
      await acc.create('admin', 'longpassword1', 'administrator');
      final u = await acc.authenticate('ADMIN', 'longpassword1');
      expect(u.username, 'admin');
      expect(u.role, 'administrator');
      await expectLater(acc.authenticate('admin', 'wrong-password'), throwsA(isA<LocalAuthException>()));
      await expectLater(acc.authenticate('nobody', 'longpassword1'), throwsA(isA<LocalAuthException>()));
    });

    test('accounts persist across reloads', () async {
      await acc.create('admin', 'longpassword1', 'administrator');
      final again = LocalAccounts((k) async => store[k], (k, v) async => store[k] = v,
          hasher: fastHash, iterations: 10);
      await again.load();
      expect((await again.authenticate('admin', 'longpassword1')).role, 'administrator');
    });

    test('lockout after repeated failures', () async {
      await acc.create('admin', 'longpassword1', 'administrator');
      final t0 = DateTime(2026, 10, 4, 12);
      for (var i = 0; i < LocalAccounts.maxFailures; i++) {
        await expectLater(acc.authenticate('admin', 'nope-nope', now: t0), throwsA(isA<LocalAuthException>()));
      }
      // even the right password is refused while locked
      await expectLater(acc.authenticate('admin', 'longpassword1', now: t0),
          throwsA(predicate((e) => e.toString().contains('Too many'))));
      final later = t0.add(LocalAccounts.lockout + const Duration(seconds: 1));
      expect((await acc.authenticate('admin', 'longpassword1', now: later)).username, 'admin');
    });

    test('last administrator cannot be removed, demoted or disabled', () async {
      await acc.create('admin', 'longpassword1', 'administrator');
      await acc.create('insp', 'longpassword2', 'inspector');
      await expectLater(acc.delete('admin'), throwsA(isA<LocalAuthException>()));
      await expectLater(acc.setRole('admin', 'inspector'), throwsA(isA<LocalAuthException>()));
      await expectLater(acc.setDisabled('admin', true), throwsA(isA<LocalAuthException>()));
      await acc.delete('insp');
      expect(acc.accounts.length, 1);
    });

    test('reset forces a password change; disabled account cannot sign in', () async {
      await acc.create('admin', 'longpassword1', 'administrator');
      await acc.create('insp', 'longpassword2', 'inspector');
      await acc.resetPassword('insp', 'temporary123');
      expect((await acc.authenticate('insp', 'temporary123')).mustChangePassword, isTrue);
      await acc.changePassword('insp', 'temporary123', 'brandnewpass');
      expect((await acc.authenticate('insp', 'brandnewpass')).mustChangePassword, isFalse);
      await acc.setDisabled('insp', true);
      await expectLater(acc.authenticate('insp', 'brandnewpass'), throwsA(isA<LocalAuthException>()));
    });

    test('password rules', () {
      expect(LocalAccounts.validatePassword('short'), isNotNull);
      expect(LocalAccounts.validatePassword('aaaaaaaaaa'), isNotNull);
      expect(LocalAccounts.validatePassword('inspector1', username: 'inspector1'), isNotNull);
      expect(LocalAccounts.validatePassword('a-good-pass'), isNull);
      expect(LocalAccounts.validateUsername('a b'), isNotNull);
      expect(LocalAccounts.validateUsername('field.op-1'), isNull);
    });
  });
}
