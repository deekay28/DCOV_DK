// Regression for the first physical-device test (2026-10-04): typing only
// "TAIMAG" matched "TAIMAG HC-027 2340" (origin Taiwan, documented) by prefix
// at 88%. Verdict was correctly YELLOW "IDENTITY UNCERTAIN", but the line under
// it claimed "its origin was never established" - false for this record.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dcov_field/services/matching.dart';
import 'package:dcov_field/widgets/verdict_widgets.dart';

void main() {
  late ComponentIndex index;
  final matcher = ComponentMatcher();

  setUpAll(() {
    final raw = File('assets/data/components_seed.json').readAsStringSync();
    index = ComponentIndex((jsonDecode(raw) as List).cast<Map<String, dynamic>>());
  });

  test('approximate match to a documented-origin part does not say origin unknown', () {
    final r = matcher.match('TAIMAG', index);
    final v = verdictFor(r.component, r.score, r.method);
    expect(v.banner, 'YELLOW');
    expect(v.headline, startsWith('IDENTITY UNCERTAIN'));
    final sub = bannerSubFor(v);
    expect(sub, isNot(contains('never established')));
    expect(sub, contains('identity is not confirmed'));
  });

  test('exact match keeps the category sentence', () {
    final r = matcher.match('STM32F302C8T6', index);
    final v = verdictFor(r.component, r.score, r.method);
    expect(bannerSubFor(v), kBannerSub['chinese']);
  });
}
