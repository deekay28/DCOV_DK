// Run with: flutter test
// These check the Dart engine against the same vectors used to validate the
// Python (backend/app/services/matching.py) and JS (web_demo/dcov-match.js)
// implementations, so a regression in any one of the three is caught here.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dcov_field/services/matching.dart';

void main() {
  late ComponentIndex index;

  setUpAll(() {
    final raw = File('assets/data/components_seed.json').readAsStringSync();
    final rows = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    index = ComponentIndex(rows);
  });

  final matcher = ComponentMatcher();

  test('exact normalized match on a known Chinese IC', () {
    final r = matcher.match('STM32F302C8T6', index);
    final v = verdictFor(r.component, r.score);
    expect(v.banner, 'RED');
    expect(r.method, 'normalized');
    expect(r.score, 100);
  });

  test('single-glyph OCR misread still resolves to the same verdict', () {
    final r = matcher.match('stm32 f3o2-c8t6', index);
    final v = verdictFor(r.component, r.score);
    expect(v.banner, 'RED');
    expect(r.method, 'ocr_corrected');
  });

  test('trailing lot/date code is discarded', () {
    final r = matcher.match('STM32G4A1KCU6 GQ23J 1B9U', index);
    final v = verdictFor(r.component, r.score);
    expect(v.banner, 'RED');
    expect(r.method, 'lot_code_stripped');
  });

  test('double-substitution resolves via glyph-class folding', () {
    final r = matcher.match('ADIN13OOBCPZ', index);
    final v = verdictFor(r.component, r.score);
    expect(v.banner, 'RED');
    expect(r.method, 'ocr_folded');
  });

  test('a known non-Chinese part returns GREEN', () {
    final r = matcher.match('ATMEGA16U2', index);
    final v = verdictFor(r.component, r.score);
    expect(v.banner, 'GREEN');
  });

  test('a marking absent from the catalogue returns GREY, not a guess', () {
    final r = matcher.match('TOTALLY-UNKNOWN-PART-999', index);
    final v = verdictFor(r.component, r.score);
    expect(v.banner, 'GREY');
    expect(r.component, isNull);
  });

  test('an empty input is handled without throwing', () {
    final r = matcher.match('', index);
    expect(r.matched, isFalse);
    expect(r.trace, isEmpty);
  });

  test('normalize() ignores case, spaces and dashes identically to the other two engines', () {
    expect(normalizeMarking(' stm32-f302 c8t6 '), 'STM32F302C8T6');
  });

  // --- origin-evidence rules (mirror backend tests/test_origin_logic.py) ---
  test('a multi-glyph OCR repair is never a clean GREEN', () {
    final r = matcher.match('MX2SLI2833F', index);
    expect(r.method, 'ocr_folded');
    final v = verdictFor(r.component, r.score, r.method);
    expect(v.banner, 'YELLOW');
    expect(v.reviewRequired, isTrue);
  });

  test('approximate match to a Chinese part stays RED but says PROBABLE', () {
    final row = index.byKey('STM32F302C8T6').first;
    final v = verdictFor(row, 88, 'prefix');
    expect(v.banner, 'RED');
    expect(v.headline, contains('PROBABLE'));
  });

  test('OEM home country alone never gives GREEN', () {
    final oem = index.rows.where((r) => r['category'] == 'OEM / LRU' && r['is_chinese'] == 'NO');
    expect(oem, isNotEmpty);
    for (final row in oem) {
      final v = verdictFor(row, 100, 'normalized');
      expect(v.banner, 'YELLOW', reason: row['component_name'].toString());
      expect(v.originEvidence, 'manufacturer');
    }
  });

  test('an explicit Unknown country is not an origin', () {
    final v = verdictFor({'component_id': 'X', 'is_chinese': 'NO', 'country_of_origin': 'Unknown',
        'confidence_score': '95'}, 100, 'normalized');
    expect(v.banner, 'YELLOW');
  });

  test('documented non-Chinese component is GREEN with component evidence', () {
    final r = matcher.match('ADF4350', index);
    final v = verdictFor(r.component, r.score, r.method);
    expect(v.banner, 'GREEN');
    expect(v.originEvidence, 'component');
    expect(v.policyDecision, startsWith('ACCEPTABLE'));
  });

  test('GS1 China-range EAN that is not catalogued is GREY, never RED', () {
    final r = matcher.match('6901234567892', index);
    expect(verdictFor(r.component, r.score, r.method).banner, 'GREY');
  });

  test('ECIA reel label: 1P part number is looked up, 4L only reported', () {
    const raw = '[)>\u001e06\u001d1PADF4350\u001d1TLOT9\u001d4LCN\u001e\u0004';
    final f = parseLabelBarcode(raw);
    expect(f['mpn'], 'ADF4350');
    expect(f['label_coo'], 'CN');
    final r = matcher.match(raw, index);
    expect(r.method, 'label_mpn');
    expect(verdictFor(r.component, r.score, r.method).banner, 'GREEN');
    expect(r.notes.any((n) => n.contains('4L')), isTrue);
  });

  test('single-field Code128 label', () {
    final r = matcher.match('1PMX25L12833F', index);
    expect(r.component?['chip_number'], 'MX25L12833F');
  });

  test('plain part numbers are not mistaken for labels', () {
    expect(parseLabelBarcode('STM32F302C8T6'), isEmpty);
  });
}
