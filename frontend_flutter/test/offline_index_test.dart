// Offline catalogue must be fully searchable on the device. Regression for the
// `chip_number ?? part_number` bug: 116 of 203 bundled rows have chip_number ""
// and were indexed under an empty key, so typing their part number found
// nothing offline (the JS engine and the server were fine).
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dcov_field/services/matching.dart';

void main() {
  late List<Map<String, dynamic>> rows;
  late ComponentIndex index;
  final matcher = ComponentMatcher();

  setUpAll(() {
    final raw = File('assets/data/components_seed.json').readAsStringSync();
    rows = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    // separate decode: ComponentIndex writes search_key into its rows
    index = ComponentIndex((jsonDecode(raw) as List).cast<Map<String, dynamic>>());
  });

  test('part-number-only record is found by its part number', () {
    final r = matcher.match('ADT and GDT Radio Modem', index);
    expect(r.component?['component_id'], 'ASSY-452F0312');
    expect(r.score, 100);
  });

  test('every bundled record is found by its own marking', () {
    final misses = <String>[];
    for (final row in rows) {
      final chip = row['chip_number']?.toString() ?? '';
      final marking = chip.isNotEmpty ? chip : row['part_number']?.toString() ?? '';
      if (normalizeMarking(marking).isEmpty) continue;
      final r = matcher.match(marking, index);
      final hit = r.component;
      // Several records may legitimately share a marking (same part, different
      // assemblies); the match must land on a record with the same key.
      final hitKey = hit == null ? '' : normalizeMarking(
          (hit['chip_number']?.toString() ?? '').isNotEmpty
              ? hit['chip_number'].toString() : hit['part_number']?.toString());
      if (hitKey != normalizeMarking(marking)) misses.add('${row['component_id']}: "$marking"');
    }
    expect(misses, isEmpty, reason: 'not found by own marking:\n${misses.take(20).join('\n')}');
  });
}
