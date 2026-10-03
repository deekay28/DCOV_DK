/// Marking-consistency (anti-remark) analysis — Dart port of
/// backend/app/services/marking.py. Keep the two in lockstep: the offline
/// verdict on a phone with no signal must equal the server's verdict for the
/// same marking. test/marking_test.dart uses the same vectors as
/// backend/tests/test_marking.py.
///
/// The matching cascade trusts the printed part number - exactly the field a
/// remarked chip forges. This reads the *other* lines (country-of-origin code,
/// assembly-site code, wafer-fab code) and reports contradictions. It can only
/// ever make a verdict stricter.
library;

import 'matching.dart';

/// Country-of-origin codes printed on packages.
/// Source: "Chinese Components FINAL.xlsx", sheet COMMON CHINESE, COO table.
const Map<String, String> kCountryCodes = {
  'CHN': 'China', 'PHL': 'Philippines', 'SGP': 'Singapore', 'MYS': 'Malaysia',
  'TWN': 'Taiwan', 'KOR': 'Republic of Korea', 'FRA': 'France', 'ITA': 'Italy',
  'USA': 'USA', 'MLT': 'Malta',
};
const Set<String> kChinaCodes = {'CHN'};
const List<String> kChinaWords = ['MADE IN CHINA', 'PRC'];

class SiteCode {
  final String kind;      // assembly | diffusion
  final String country;
  final String site;
  final String source;
  const SiteCode(this.kind, this.country, this.site, this.source);
}

/// Manufacturer-scoped: a code only means something on that maker's chips.
const Map<String, Map<String, SiteCode>> kSiteCodes = {
  'STMICROELECTRONICS': {
    'GK': SiteCode('assembly', 'CHN', 'ST Shenzhen (China)',
        'ST PCN EMBEDDED PROCESSING/26/16389 and /16018'),
    'Y5': SiteCode('diffusion', 'CHN', 'HHGrace WuXi Fab 7 (China)',
        'ST PCN EMBEDDED PROCESSING/26/16388'),
    '2E': SiteCode('diffusion', 'CHN', 'HHGrace WuXi Fab 9 (China)',
        'ST PCN EMBEDDED PROCESSING/26/16388'),
  },
};

const Set<String> kPrintsCountryCode = {'STMICROELECTRONICS'};

const Map<String, String> kManufacturerAliases = {
  'STMICROELECTRONICS': 'STMICROELECTRONICS',
  'ST MICROELECTRONICS': 'STMICROELECTRONICS',
  'ST MICRO': 'STMICROELECTRONICS',
  'ST': 'STMICROELECTRONICS',
};

const Map<String, int> kSeverityRank = {'info': 0, 'yellow': 1, 'red': 2};

class MarkingFinding {
  final String code;
  final String severity;   // info | yellow | red
  final String message;
  const MarkingFinding(this.code, this.severity, this.message);
}

class MarkingAnalysis {
  String? countryCode;
  String? country;
  final List<String> siteCodes = [];
  final List<MarkingFinding> findings = [];

  String get worst {
    var w = 'info';
    for (final f in findings) {
      if (kSeverityRank[f.severity]! > kSeverityRank[w]!) w = f.severity;
    }
    return w;
  }
}

String canonicalManufacturer(String? name) {
  final n = (name ?? '').toUpperCase().replaceAll('.', '')
      .replaceAll(RegExp(r'\s+'), ' ').trim();
  if (kManufacturerAliases.containsKey(n)) return kManufacturerAliases[n]!;
  for (final e in kManufacturerAliases.entries) {
    if (e.key.length > 2 && n.contains(e.key)) return e.value;
  }
  return n;
}

List<String> _tokens(String line) =>
    line.toUpperCase().split(RegExp(r'[^A-Z0-9]+')).where((t) => t.isNotEmpty).toList();

String _norm(String s) => s.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

MarkingAnalysis analyseMarking(String markingText,
    {String? manufacturer, String? partKey, String? catalogueIsChinese}) {
  final out = MarkingAnalysis();
  final rawLines = markingText.split(RegExp(r'[\r\n|]+'))
      .where((l) => l.trim().isNotEmpty).toList();
  final pk = _norm(partKey ?? '');
  final probes = pk.length >= 6
      ? {pk.substring(0, 6), pk.substring(pk.length - 6)}
      : (pk.isNotEmpty ? {pk} : <String>{});
  // Drop part-number tokens, not whole lines - the full marking may be on one line.
  final lines = rawLines
      .map((r) => _tokens(r).where((t) => !probes.any((p) => p.isNotEmpty && t.contains(p))).join(' '))
      .where((l) => l.isNotEmpty)
      .toList();
  final manu = canonicalManufacturer(manufacturer);
  final siteTable = kSiteCodes[manu] ?? const <String, SiteCode>{};
  final upperText = rawLines.join(' ').toUpperCase();

  // Country of origin.
  for (final line in lines) {
    for (final tok in _tokens(line)) {
      if (kCountryCodes.containsKey(tok) && out.countryCode == null) {
        out.countryCode = tok;
        out.country = kCountryCodes[tok];
      }
    }
  }
  if (out.countryCode == null && kChinaWords.any((w) => upperText.contains(w))) {
    out.countryCode = 'CHN';
    out.country = 'China';
  }

  // Site codes - manufacturer-scoped, whole tokens only.
  for (final line in lines) {
    for (final tok in _tokens(line)) {
      if (siteTable.containsKey(tok) && !out.siteCodes.contains(tok)) out.siteCodes.add(tok);
    }
  }

  // Findings.
  final cat = (catalogueIsChinese ?? 'UNKNOWN').toUpperCase();
  if (out.countryCode != null && kChinaCodes.contains(out.countryCode)) {
    if (cat == 'NO') {
      out.findings.add(const MarkingFinding('unit_marked_china_catalogue_non_chinese', 'red',
          'This unit is marked CHN (China) although the catalogue lists this part as '
          'non-Chinese. The marking on the unit itself governs: treat as Chinese and '
          'update the catalogue if this source is supplied this way.'));
    } else {
      out.findings.add(const MarkingFinding('unit_marked_china', 'red',
          'Country-of-origin code on the package reads CHN (China).'));
    }
  } else if (out.countryCode != null && cat == 'YES') {
    out.findings.add(MarkingFinding('country_code_disagrees_with_catalogue', 'yellow',
        'Package is marked ${out.countryCode} (${out.country}) but this part has been '
        'recorded as Chinese-origin. Either a different assembly site or a remarked '
        'package - the catalogue verdict is kept; verify with the manufacturer.'));
  }

  for (final code in out.siteCodes) {
    final info = siteTable[code]!;
    if (info.kind == 'assembly') {
      if (out.countryCode != null && out.countryCode != info.country) {
        final chinaInvolved = out.countryCode == 'CHN' || info.country == 'CHN';
        out.findings.add(MarkingFinding('site_code_contradicts_country_code',
            chinaInvolved ? 'red' : 'yellow',
            'Assembly-site code $code = ${info.site}, but the package country code is '
            '${out.countryCode}. These cannot both be original - possible remarked '
            'package. (Code source: ${info.source})'));
      } else if (out.countryCode == null && kChinaCodes.contains(info.country)) {
        out.findings.add(MarkingFinding('china_assembly_site_code', 'red',
            'Assembly-site code $code = ${info.site}, but no country code was read. '
            '(Code source: ${info.source})'));
      }
    } else if (info.kind == 'diffusion' && kChinaCodes.contains(info.country)) {
      out.findings.add(MarkingFinding('china_wafer_fab_code', 'yellow',
          'Wafer-fab code $code = ${info.site}. The die was fabricated in China even if '
          'assembled elsewhere - origin policy decision required. '
          '(Code source: ${info.source})'));
    }
  }

  if (out.countryCode == null && kPrintsCountryCode.contains(manu) && rawLines.length >= 3) {
    out.findings.add(const MarkingFinding('country_code_missing', 'yellow',
        'This manufacturer normally prints a country-of-origin code, but none was read '
        'from an otherwise complete marking. Either the photo/OCR missed it or it has '
        'been removed - inspect the package surface.'));
  }
  return out;
}

/// Tighten (never relax) a catalogue verdict. Mirrors apply_to_verdict().
Verdict applyMarkingToVerdict(Verdict v, MarkingAnalysis a) {
  if (v.result == 'not_found') return v;
  final worst = a.worst;
  Verdict out = v;
  if (worst == 'red' && v.result != 'chinese') {
    final critical = v.criticality == 'CRITICAL';
    out = Verdict(
      result: 'chinese', banner: 'RED', headline: 'CHINESE ORIGIN MARKED ON PACKAGE',
      action: 'Marking evidence overrides the catalogue - quarantine the part',
      alert: true, vibrate: true, criticality: v.criticality,
      criticalityPolicy: v.criticalityPolicy, confidence: v.confidence,
      escalate: critical,
      escalationNote: critical ? 'Chinese-origin marking on a CRITICAL subsystem part' : '',
      originEvidence: v.originEvidence, evidenceDetail: v.evidenceDetail,
    );
  } else if (worst == 'yellow' && v.result == 'non_chinese') {
    out = v.copyWith(
      result: 'unknown_origin', banner: 'YELLOW', headline: 'MARKING INCONSISTENT',
      action: 'Package marking raises an origin question - verify before fitting',
      alert: false, vibrate: false,
    );
  }
  if (worst == 'red' || worst == 'yellow') {
    final msgs = a.findings.where((f) => f.severity == worst).map((f) => f.message).take(2);
    out = out.copyWith(
      originEvidence: worst == 'red' ? 'unit_marking' : out.originEvidence,
      evidenceDetail: msgs.isNotEmpty ? msgs.join(' ') : out.evidenceDetail,
      reviewRequired: true,
      policyDecision: policyDecision(out.result, out.criticality, out.criticalityPolicy),
    );
  }
  return out;
}
