import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dcov_field/services/catalog_import.dart';
import 'package:dcov_field/services/matching.dart';

// Minimal real .xlsx (built with Python zipfile): title row above the header,
// shared strings incl. a rich-text run and an XML entity, an inline string,
// a numeric barcode, a gap cell, an unmapped column and an empty row.
const _fixtureXlsx = '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';

void main() {
  group('origin derivation (same rule as backend derive_is_chinese)', () {
    test('declared value wins', () {
      expect(deriveIsChinese('Taiwan', '', 'YES'), 'YES');
      expect(deriveIsChinese('China', '', 'no'), 'NO');
    });
    test('country and remarks', () {
      expect(deriveIsChinese('China'), 'YES');
      expect(deriveIsChinese('Hong Kong'), 'YES');
      expect(deriveIsChinese('USA', 'label says MADE IN CHINA'), 'YES');
      expect(deriveIsChinese('Taiwan'), 'NO');
    });
    test('unknown is never NO', () {
      for (final v in ['', 'Unknown', 'N/A', '-', 'TBD', 'not established']) {
        expect(deriveIsChinese(v), 'UNKNOWN', reason: v);
      }
    });
  });

  test('header mapping uses the worksheet synonyms', () {
    final m = autoMapColumns(['Name of Item', 'SUB COMPONENT / CHIP NO', 'Mfr', 'COO', 'Bar Code', 'Lot']);
    expect(m['Name of Item'], 'component_name');
    expect(m['SUB COMPONENT / CHIP NO'], 'chip_number');
    expect(m['Mfr'], 'manufacturer');
    expect(m['COO'], 'country_of_origin');
    expect(m['Bar Code'], 'barcode');
    expect(m.containsKey('Lot'), isFalse);
  });

  test('CSV: quotes, embedded comma/newline, semicolon delimiter, BOM', () {
    final rows = parseCsv('﻿a,b,c\r\n1,"x, y","line1\nline2"\r\n2,"say ""hi""",\r\n');
    expect(rows[0], ['a', 'b', 'c']);
    expect(rows[1], ['1', 'x, y', 'line1\nline2']);
    expect(rows[2], ['2', 'say "hi"', '']);
    expect(parseCsv('a;b\n1;2')[1], ['1', '2']);
  });

  test('XLSX reader', () {
    final rows = readXlsx(base64Decode(_fixtureXlsx));
    expect(rows[1], ['Name of Item', 'SUB COMPONENT / CHIP NO', 'Mfr', 'COO', 'Bar Code', 'Lot']);
    expect(rows[2], ['Flight Controller', 'STM32F405RGT6', 'STMicroelectronics', 'China', '8901234567890', 'LOT-7']);
    expect(rows[3], ['Radio & Link', 'RFD900X', '', 'Taiwan']);
    expect(detectHeaderRow(rows), 1);
  });

  test('XLSX preview: mapping, derivation, extras folded into remarks', () {
    final p = buildImportPreview('worksheet.xlsx', base64Decode(_fixtureXlsx), const []);
    expect(p.format, 'xlsx');
    expect(p.errors, isEmpty);
    expect(p.validRows.length, 2);
    final fc = p.validRows.first;
    expect(fc['component_name'], 'Flight Controller');
    expect(fc['chip_number'], 'STM32F405RGT6');
    expect(fc['is_chinese'], 'YES');
    expect(fc['barcode'], '8901234567890');
    expect(fc['remarks'], 'Lot: LOT-7');
    expect(fc['component_id'], startsWith('DEV-'));
    expect(p.validRows[1]['is_chinese'], 'NO');
    expect(p.newCount, 2);
    expect(p.unmapped, ['Lot']);
    expect(p.notes.join(), contains('Header found on row 2'));
  });

  test('imported rows are searchable and give the right verdict', () {
    final p = buildImportPreview('worksheet.xlsx', base64Decode(_fixtureXlsx), const []);
    final index = ComponentIndex(p.resultRows(const [], replace: true));
    final r = ComponentMatcher().match('STM32F405RGT6', index);
    expect(r.score, 100);
    expect(verdictFor(r.component, r.score, r.method).banner, 'RED');
    final g = ComponentMatcher().match('RFD900X', index);
    expect(verdictFor(g.component, g.score, g.method).banner, 'GREEN');
  });

  test('validation errors, duplicates and origin flips against the current catalogue', () {
    final current = [
      {'component_id': 'C-1', 'component_name': 'Old', 'part_number': 'P1', 'is_chinese': 'NO'},
      {'component_id': 'C-9', 'component_name': 'Kept', 'part_number': 'P9', 'is_chinese': 'NO'},
    ];
    const csv = 'Component ID,Component Name,Part Number,Country of Origin,Confidence\n'
        'C-1,Old,P1,China,90\n'        // flips NO -> YES
        'C-2,,P2,USA,\n'               // error: no name
        'C-3,No part,,USA,\n'          // error: no part/chip
        'C-4,Bad conf,P4,USA,150\n'    // error: confidence
        'C-5,New,P5,,\n'               // ok, UNKNOWN + warning
        'C-5,Dup,P5b,USA,\n';          // duplicate id
    final p = buildImportPreview('c.csv', utf8.encode(csv), current);
    expect(p.validRows.map((r) => r['component_id']), ['C-1', 'C-5']);
    expect(p.errors.length, 3);
    expect(p.duplicates.length, 1);
    expect(p.originFlips.single, contains('NO -> YES'));
    expect(p.validRows[1]['is_chinese'], 'UNKNOWN');
    expect(p.updatedCount, 1);
    expect(p.newCount, 1);
    expect(p.missingFromFile, 1);
    final merged = p.resultRows(current, replace: false);
    expect(merged.length, 3); // C-1 updated, C-9 kept, C-5 added
    expect(merged.firstWhere((r) => r['component_id'] == 'C-1')['is_chinese'], 'YES');
    expect(p.resultRows(current, replace: true).length, 2);
  });

  test('JSON: the bundled seed re-imports with no changes', () {
    final bytes = File('assets/data/components_seed.json').readAsBytesSync();
    final current = (jsonDecode(utf8.decode(bytes)) as List).cast<Map<String, dynamic>>();
    final p = buildImportPreview('components_seed.json', bytes, current);
    expect(p.errors, isEmpty);
    expect(p.validRows.length, current.length);
    expect(p.newCount, 0);
    expect(p.originFlips, isEmpty);
  });

  test('unsupported type is refused with a helpful message', () {
    expect(() => buildImportPreview('old.xls', [1, 2, 3], const []),
        throwsA(isA<FormatException>()));
  });
}
