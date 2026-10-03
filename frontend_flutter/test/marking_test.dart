// Same vectors as backend/tests/test_marking.py - if one side changes, both
// must, or the offline verdict will disagree with the server's.
import 'package:flutter_test/flutter_test.dart';
import 'package:dcov_field/services/marking.dart';
import 'package:dcov_field/services/matching.dart';

const st = 'STMICROELECTRONICS';
Verdict green() => Verdict(result: 'non_chinese', banner: 'GREEN',
    headline: 'NON-CHINESE COMPONENT', criticality: 'CRITICAL', confidence: 100);
Verdict red() => Verdict(result: 'chinese', banner: 'RED',
    headline: 'CHINESE COMPONENT DETECTED', criticality: 'CRITICAL', confidence: 100);
List<String> codes(MarkingAnalysis a) => a.findings.map((f) => f.code).toList();

void main() {
  test('real PDF marking reads the China country code', () {
    final a = analyseMarking('32G491KCU6\nGQ 21U 9R\nCHN 30 2B1',
        manufacturer: st, partKey: 'STM32G491KCU6', catalogueIsChinese: 'YES');
    expect(a.countryCode, 'CHN');
    expect(codes(a), ['unit_marked_china']);
  });

  test('unit marked CHN overrides a non-Chinese catalogue entry', () {
    final a = analyseMarking('32G484CEU6\nGQ 22X 7A\nCHN 31 4C2',
        manufacturer: st, partKey: 'STM32G484', catalogueIsChinese: 'NO');
    expect(codes(a).first, 'unit_marked_china_catalogue_non_chinese');
    final v = applyMarkingToVerdict(green(), a);
    expect(v.banner, 'RED');
    expect(v.result, 'chinese');
    expect(v.escalate, isTrue);
  });

  test('China assembly-site code with a foreign country code is a remark signature', () {
    final a = analyseMarking('32G484CEU6\nGK 22X 7A\nPHL 31 4C2',
        manufacturer: st, partKey: 'STM32G484', catalogueIsChinese: 'NO');
    expect(a.countryCode, 'PHL');
    expect(a.findings.any((f) =>
        f.code == 'site_code_contradicts_country_code' && f.severity == 'red'), isTrue);
    expect(applyMarkingToVerdict(green(), a).banner, 'RED');
  });

  test('consistent non-China marking leaves GREEN alone', () {
    final a = analyseMarking('32G484CEU6\nGQ 22X 7A\nPHL 31 4C2',
        manufacturer: st, partKey: 'STM32G484', catalogueIsChinese: 'NO');
    expect(a.findings, isEmpty);
    expect(applyMarkingToVerdict(green(), a).banner, 'GREEN');
  });

  test('China wafer-fab code downgrades GREEN to YELLOW, not RED', () {
    final a = analyseMarking('32G484CEU6\nY5 22X 7A\nPHL 31 4C2',
        manufacturer: st, partKey: 'STM32G484', catalogueIsChinese: 'NO');
    expect(a.findings.map((f) => f.severity).toList(), ['yellow']);
    expect(applyMarkingToVerdict(green(), a).banner, 'YELLOW');
  });

  test('foreign code on a part recorded as Chinese never relaxes RED', () {
    final a = analyseMarking('32G491KCU6\nGQ 21U 9R\nMYS 30 2B1',
        manufacturer: st, partKey: 'STM32G491KCU6', catalogueIsChinese: 'YES');
    expect(codes(a).first, 'country_code_disagrees_with_catalogue');
    expect(applyMarkingToVerdict(red(), a).banner, 'RED');
  });

  test('missing country code on a complete ST marking is flagged', () {
    final a = analyseMarking('32G484CEU6\nGQ 22X 7A\n31 4C2',
        manufacturer: st, partKey: 'STM32G484', catalogueIsChinese: 'NO');
    expect(codes(a), ['country_code_missing']);
    expect(applyMarkingToVerdict(green(), a).banner, 'YELLOW');
  });

  test('site codes are scoped to the manufacturer', () {
    final a = analyseMarking('TPS62130\nGK 4A\nPHL',
        manufacturer: 'Texas Instruments', partKey: 'TPS62130', catalogueIsChinese: 'NO');
    expect(a.siteCodes, isEmpty);
    expect(a.findings, isEmpty);
  });

  test('single-line typed input produces no false alarms', () {
    final a = analyseMarking('STM32G484',
        manufacturer: st, partKey: 'STM32G484', catalogueIsChinese: 'NO');
    expect(a.findings, isEmpty);
  });

  test('not-found verdict is never rewritten', () {
    final a = analyseMarking('XYZ123\nCHN');
    final nf = Verdict(result: 'not_found', banner: 'GREY', headline: 'COMPONENT NOT FOUND');
    expect(identical(applyMarkingToVerdict(nf, a), nf), isTrue);
  });

  test('whole marking on one line still finds the country code', () {
    final a = analyseMarking('32G484CEU6 GQ 22X 7A CHN 31 4C2',
        manufacturer: st, partKey: 'STM32G484', catalogueIsChinese: 'NO');
    expect(a.countryCode, 'CHN');
    expect(applyMarkingToVerdict(green(), a).banner, 'RED');
  });
}
