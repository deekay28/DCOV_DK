import 'package:flutter_test/flutter_test.dart';
import 'package:dcov_field/services/ocr_ranking.dart';

void main() {
  test('part number outranks vendor, lot and COO lines', () {
    final r = rankOcrLines(['ST', 'STM32F302C8T6', 'GQ23J 1B9U', 'CHN 302']);
    expect(r.best, 'STM32F302C8T6');
    expect(r.fullText, contains('CHN 302'));
    expect(r.multipleParts, isFalse);
  });

  test('classification matches the server pipeline', () {
    expect(classifyMarking('STM32F302C8T6'), 'part_number');
    expect(classifyMarking('2219'), 'date_code');
    expect(classifyMarking('CHN'), 'country_of_origin');
    expect(classifyMarking('ST'), 'vendor');
  });

  test('two different part numbers in one photo are flagged', () {
    final r = rankOcrLines(['STM32F302C8T6', 'CHN', 'MX25L12833F', 'TWN']);
    expect(r.multipleParts, isTrue);
    expect(r.warnings.join(), contains('different part numbers'));
  });

  test('empty input yields no candidates and a warning', () {
    final r = rankOcrLines([]);
    expect(r.best, isEmpty);
    expect(r.warnings, isNotEmpty);
  });
}
