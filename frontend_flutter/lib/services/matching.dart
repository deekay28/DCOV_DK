/// Offline matching engine — Dart port of backend/app/services/matching.py
/// and web_demo/dcov-match.js. All three must agree on every marking; that
/// invariant is what lets an inspector trust the same verdict whether the
/// phone has signal or not. See test/matching_test.dart for the shared
/// vector set checked against all three implementations.
library;

import 'dart:math' as math;

final RegExp _nonAlnum = RegExp(r'[^A-Z0-9]');
const _noisePrefixes = ['DCOV:', 'URN:DCOV:', 'HTTP://', 'HTTPS://'];

const Map<String, String> _confusions = {
  'O': '0', 'Q': '0', 'D': '0', 'I': '1', 'L': '1', '|': '1', 'T': '7',
  'Z': '2', 'S': '5', 'B': '8', 'G': '6', 'U': 'V', 'C': 'G', 'E': 'F',
};
final Map<String, String> _reverseConfusions = {
  for (final e in _confusions.entries) e.value: e.key,
};
const Map<String, String> _fold = {
  'O': '0', 'Q': '0', 'I': '1', 'L': '1', 'S': '5', 'B': '8', 'Z': '2',
  'G': '6', 'T': '7',
};

String normalizeMarking(String? value) {
  if (value == null || value.isEmpty) return '';
  var s = value.trim().toUpperCase();
  for (final p in _noisePrefixes) {
    if (s.startsWith(p)) s = s.substring(p.length);
  }
  return s.replaceAll(_nonAlnum, '');
}

String foldKey(String value) {
  final n = normalizeMarking(value);
  final buf = StringBuffer();
  for (final ch in n.split('')) {
    buf.write(_fold[ch] ?? ch);
  }
  return buf.toString();
}

// ---------------------------------------------------------------------------
// Reel / bag label barcodes (ANSI MH10.8.2 data identifiers, ECIA EIGP-114).
// Mirrors parse_label_barcode() in backend/app/services/matching.py.
// 1P = manufacturer part number (looked up); 4L = label-declared country of
// origin (shown, never decides the verdict - packaging is not proof).
// ---------------------------------------------------------------------------
const List<(String, String)> _diFields = [
  ('30P', 'alt_part'), ('1P', 'mpn'), ('4L', 'label_coo'), ('1T', 'lot'),
  ('10D', 'date_code'), ('9D', 'date_code'), ('1K', 'order'), ('Q', 'qty'),
  ('P', 'customer_part'), ('K', 'po'),
];
final RegExp _labelSep = RegExp('[\u001d\u001e\u0004]');
final RegExp _twoDigits = RegExp(r'^\d{2}$');

Map<String, String> parseLabelBarcode(String raw, {bool allowSingleField = false}) {
  var s = raw.trim();
  final structured = s.startsWith('[)>') || _labelSep.hasMatch(s);
  if (!structured && !allowSingleField) return const {};
  if (s.startsWith('[)>')) s = s.substring(3);
  var parts = s.split(_labelSep).map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
  if (!structured) parts = [s];
  final out = <String, String>{};
  for (final p in parts) {
    if (_twoDigits.hasMatch(p)) continue; // format header, e.g. "06"
    for (final (di, name) in _diFields) {
      if (p.toUpperCase().startsWith(di) && p.length > di.length) {
        out.putIfAbsent(name, () => p.substring(di.length).trim());
        break;
      }
    }
  }
  if (!out.containsKey('mpn')) return const {};
  return out;
}

List<String> ocrVariants(String text, {int max = 64}) {
  final base = normalizeMarking(text);
  final out = <String>[base];
  for (var i = 0; i < base.length; i++) {
    for (final table in [_confusions, _reverseConfusions]) {
      final rep = table[base[i]];
      if (rep == null) continue;
      final cand = base.substring(0, i) + rep + base.substring(i + 1);
      if (!out.contains(cand)) {
        out.add(cand);
        if (out.length >= max) return out;
      }
    }
  }
  return out;
}

List<String> truncations(String key, {int floor = 6}) {
  final out = <String>[];
  for (var i = key.length - 1; i >= floor; i--) {
    out.add(key.substring(0, i));
  }
  return out;
}

int damerauLevenshtein(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var prev2 = List<int>.filled(b.length + 1, 0);
  var prev = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final cur = List<int>.filled(b.length + 1, 0);
    cur[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      var val = [prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost].reduce(math.min);
      if (i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1]) {
        val = math.min(val, prev2[j - 2] + cost);
      }
      cur[j] = val;
    }
    prev2 = prev;
    prev = cur;
  }
  return prev[b.length];
}

double similarity(String a, String b) {
  if (a.isEmpty || b.isEmpty) return 0;
  if (a == b) return 100;
  final dist = damerauLevenshtein(a, b);
  final longest = math.max(a.length, b.length);
  final base = (1 - dist / longest) * 100;
  var prefix = 0;
  while (prefix < a.length && prefix < b.length && a[prefix] == b[prefix]) {
    prefix++;
  }
  final prefixRatio = prefix / longest;
  return ((base * 0.75 + prefixRatio * 100 * 0.25) * 100).round() / 100;
}

/// A component record as held in the offline cache. Deliberately a loose
/// map, not a rigid model: the offline cache mirrors whatever the server
/// last sent, field for field, without the client silently dropping a
/// column it doesn't yet know about.
typedef ComponentRow = Map<String, dynamic>;

class Candidate {
  final ComponentRow payload;
  final double score;
  Candidate(this.payload, this.score);
}

class TraceStep {
  final String layer;
  final bool hit;
  final String detail;
  TraceStep(this.layer, this.hit, this.detail);
}

class MatchResult {
  final bool matched;
  final String method;
  final double score;
  final ComponentRow? component;
  final List<Candidate> suggestions;
  final String normalizedInput;
  final List<String> notes;
  final List<TraceStep> trace;
  MatchResult({
    required this.matched,
    this.method = 'none',
    this.score = 0,
    this.component,
    this.suggestions = const [],
    this.normalizedInput = '',
    this.notes = const [],
    this.trace = const [],
  });
}

class ComponentIndex {
  final List<ComponentRow> rows;
  final Map<String, List<ComponentRow>> _byKey = {};
  final Map<String, List<ComponentRow>> _byFold = {};
  final Map<String, ComponentRow> _byBarcode = {};
  final Map<String, ComponentRow> _byQr = {};
  final Map<String, Set<int>> _blocks = {};

  ComponentIndex(this.rows) {
    for (var i = 0; i < rows.length; i++) {
      final c = rows[i];
      final key = (c['search_key'] as String?)?.isNotEmpty == true
          ? c['search_key'] as String
          : normalizeMarking((c['chip_number'] ?? c['part_number'])?.toString());
      c['search_key'] = key;
      if (key.isNotEmpty) {
        _byKey.putIfAbsent(key, () => []).add(c);
        _byFold.putIfAbsent(foldKey(key), () => []).add(c);
        for (final g in _grams(key)) {
          _blocks.putIfAbsent(g, () => {}).add(i);
        }
      }
      final barcode = c['barcode']?.toString();
      if (barcode != null && barcode.isNotEmpty) {
        _byBarcode[barcode.trim().toUpperCase()] = c;
      }
      final qr = c['qr_code']?.toString();
      if (qr != null && qr.isNotEmpty) {
        _byQr[qr.trim().toUpperCase()] = c;
      }
    }
  }

  static Set<String> _grams(String key, {int n = 3}) {
    final out = <String>{};
    for (var i = 0; i < math.max(1, key.length - n + 1); i++) {
      out.add(key.substring(i, math.min(i + n, key.length)));
    }
    return out;
  }

  List<ComponentRow> byKey(String key) => _byKey[key] ?? const [];
  List<ComponentRow> byFold(String key) => _byFold[key] ?? const [];
  ComponentRow? byBarcode(String raw) => _byBarcode[raw.trim().toUpperCase()];
  ComponentRow? byQr(String raw) => _byQr[raw.trim().toUpperCase()];

  List<ComponentRow> byPrefix(String key) {
    final out = <ComponentRow>[];
    _byKey.forEach((k, rows) {
      if (k.startsWith(key) || key.startsWith(k)) out.addAll(rows);
    });
    return out;
  }

  List<ComponentRow> candidates(String key, {int limit = 200}) {
    final counts = <int, int>{};
    for (final g in _grams(key)) {
      final bucket = _blocks[g];
      if (bucket == null) continue;
      for (final i in bucket) {
        counts[i] = (counts[i] ?? 0) + 1;
      }
    }
    final ranked = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return ranked.take(limit).map((e) => rows[e.key]).toList();
  }
}

const double kThreshold = 82;
const double kLowConfidenceFloor = 60;

class ComponentMatcher {
  // Named ComponentMatcher, not Matcher - a real `flutter analyze` run
  // caught that `Matcher` collides with package:matcher's own `Matcher`
  // class (re-exported by flutter_test, used throughout `expect(actual,
  // matcher)` assertions) - an ambiguous_import error the moment this
  // file and a test file were both in scope. Renamed rather than aliased.
  final double threshold;
  ComponentMatcher({this.threshold = kThreshold});

  MatchResult match(String raw, ComponentIndex index) {
    raw = raw.trim();
    final key = normalizeMarking(raw);
    final notes = <String>[];
    final trace = <TraceStep>[];

    if (key.isEmpty) {
      return MatchResult(matched: false, notes: const ['empty input']);
    }

    final coded = index.byBarcode(raw) ?? index.byQr(raw);
    trace.add(TraceStep('Coded payload', coded != null,
        coded != null ? 'barcode or QR matched verbatim' : 'not a stored barcode or QR payload'));
    if (coded != null) {
      return MatchResult(matched: true, method: 'exact_code', score: 100,
          component: coded, normalizedInput: key, notes: notes, trace: trace);
    }

    var label = parseLabelBarcode(raw);
    if (label.isNotEmpty) {
      trace.add(TraceStep('Label barcode', true, '1P = ${label['mpn']}'));
      return _fromLabel(label, index, notes, trace);
    }

    var hits = index.byKey(key);
    trace.add(TraceStep('Normalised key', hits.isNotEmpty, key));
    if (hits.isNotEmpty) {
      return _resolve(hits, key, 'normalized', 100, notes, trace);
    }

    label = parseLabelBarcode(raw, allowSingleField: true);
    if (label.isNotEmpty && index.byKey(normalizeMarking(label['mpn'])).isNotEmpty) {
      trace.add(TraceStep('Label barcode', true, '1P = ${label['mpn']}'));
      return _fromLabel(label, index, notes, trace);
    }

    for (final t in truncations(key)) {
      hits = index.byKey(t);
      if (hits.isNotEmpty) {
        notes.add('trailing lot/date code discarded: $key \u2192 $t');
        trace.add(TraceStep('Lot-code strip', true, '$key \u2192 $t'));
        return _resolve(hits, t, 'lot_code_stripped', 96, notes, trace);
      }
    }
    trace.add(TraceStep('Lot-code strip', false, 'no shorter leading substring is a known part number'));

    for (final v in ocrVariants(key).skip(1)) {
      hits = index.byKey(v);
      if (hits.isNotEmpty) {
        notes.add('OCR correction applied: $key \u2192 $v');
        trace.add(TraceStep('Single-glyph repair', true, '$key \u2192 $v'));
        return _resolve(hits, v, 'ocr_corrected', 94, notes, trace);
      }
    }
    trace.add(TraceStep('Single-glyph repair', false, 'no single character substitution reaches a known part'));

    final folded = foldKey(key);
    hits = index.byFold(folded);
    if (hits.isNotEmpty) {
      notes.add('resolved through glyph-class folding ($key ~ $folded) \u2014 verify the marking by eye before accepting');
      trace.add(TraceStep('Glyph-class fold', true, '$key ~ $folded'));
      return _resolve(hits, key, 'ocr_folded', 90, notes, trace);
    }
    for (final t in truncations(folded)) {
      hits = index.byFold(t);
      if (hits.isNotEmpty) {
        notes.add('glyph-class folding after discarding a trailing code ($key)');
        trace.add(TraceStep('Glyph-class fold', true, '$folded \u2192 $t'));
        return _resolve(hits, key, 'ocr_folded_stripped', 87, notes, trace);
      }
    }
    trace.add(TraceStep('Glyph-class fold', false, 'folded form $folded is unknown'));

    if (key.length >= 5) {
      final pref = index.byPrefix(key);
      if (pref.isNotEmpty) {
        final longest = pref.map((p) => (p['search_key'] as String).length).reduce(math.max);
        final best = pref.where((p) => (p['search_key'] as String).length == longest).toList();
        final distinct = best.map((p) => p['search_key']).toSet();
        trace.add(TraceStep('Partial marking', true, '${best.length} record(s) at the most specific prefix'));
        if (distinct.length == 1) {
          notes.add('matched on partial marking (prefix)');
          return _resolve(best, key, 'prefix', 88, notes, trace);
        }
        notes.add('${distinct.length} distinct part numbers share this prefix \u2014 confirm manually');
        return MatchResult(matched: false, method: 'ambiguous_prefix', score: 0,
            suggestions: best.take(10).map((c) => Candidate(c, 85)).toList(),
            normalizedInput: key, notes: notes, trace: trace);
      }
      trace.add(TraceStep('Partial marking', false, 'no stored part number shares this prefix'));
    }

    final cands = <Candidate>[];
    for (final comp in index.candidates(key, limit: 200)) {
      final ck = (comp['search_key'] as String?) ??
          normalizeMarking((comp['chip_number'] ?? comp['part_number'])?.toString());
      if (ck.isEmpty) continue;
      final s = similarity(key, ck);
      if (s >= 55) cands.add(Candidate(comp, s));
    }
    cands.sort((a, b) => b.score.compareTo(a.score));
    final top = cands.take(25).toList();

    if (top.isNotEmpty && top.first.score >= threshold) {
      if (top.length > 1 && top[1].score >= top.first.score - 2) {
        notes.add('two near-equal fuzzy candidates \u2014 inspector confirmation required');
        trace.add(TraceStep('Fuzzy', false,
            '${top[0].score}% vs ${top[1].score}% \u2014 too close to call'));
        return MatchResult(matched: false, method: 'ambiguous_fuzzy', score: top.first.score,
            suggestions: top.take(5).toList(), normalizedInput: key, notes: notes, trace: trace);
      }
      trace.add(TraceStep('Fuzzy', true, 'closest stored part number at ${top.first.score}%'));
      return MatchResult(matched: true, method: 'fuzzy', score: top.first.score,
          component: top.first.payload, suggestions: top.skip(1).take(4).toList(),
          normalizedInput: key, notes: notes, trace: trace);
    }
    trace.add(TraceStep('Fuzzy', false, top.isNotEmpty
        ? 'best candidate only ${top.first.score}%, below the ${threshold.toStringAsFixed(0)}% floor'
        : 'nothing in the catalogue is close'));
    return MatchResult(matched: false, method: 'none',
        score: top.isNotEmpty ? top.first.score : 0,
        suggestions: top.take(5).toList(), normalizedInput: key, notes: notes, trace: trace);
  }

  MatchResult _fromLabel(Map<String, String> label, ComponentIndex index,
      List<String> notes, List<TraceStep> trace) {
    final mpn = label['mpn']!;
    notes.add('reel/bag label barcode: manufacturer part number (1P) = $mpn');
    if ((label['label_coo'] ?? '').isNotEmpty) {
      notes.add('label declares country of origin (4L) = ${label['label_coo']} - '
          'packaging claim only, not used to decide the verdict');
    }
    final lotDate = [label['lot'], label['date_code']].whereType<String>()
        .where((v) => v.isNotEmpty).join(' / ');
    if (lotDate.isNotEmpty) notes.add('label lot/date: $lotDate');
    final inner = match(mpn, index);
    return MatchResult(
      matched: inner.matched,
      method: inner.method == 'normalized' ? 'label_mpn' : inner.method,
      score: inner.score, component: inner.component, suggestions: inner.suggestions,
      normalizedInput: inner.normalizedInput, notes: [...notes, ...inner.notes],
      trace: [...trace, ...inner.trace],
    );
  }

  MatchResult _resolve(List<ComponentRow> hits, String key, String method, double score,
      List<String> notes, List<TraceStep> trace) {
    final seen = <String, ComponentRow>{};
    for (final h in hits) {
      seen[h['component_id'].toString()] = h;
    }
    hits = seen.values.toList();
    if (hits.length == 1) {
      return MatchResult(matched: true, method: method, score: score,
          component: hits.first, normalizedInput: key, notes: notes, trace: trace);
    }

    final definite = hits.where((h) =>
        (h['is_chinese']?.toString() ?? 'UNKNOWN').toUpperCase() != 'UNKNOWN').toList();
    if (definite.isNotEmpty && definite.length < hits.length) {
      notes.add('${hits.length - definite.length} record(s) with unestablished origin '
          'superseded by verified record(s)');
      hits = definite;
    }

    final verdicts = hits.map((h) => (h['is_chinese']?.toString() ?? 'UNKNOWN').toUpperCase()).toSet();
    if (verdicts.length == 1) {
      final best = hits.reduce((a, b) {
        final ca = double.tryParse(a['confidence_score']?.toString() ?? '0') ?? 0;
        final cb = double.tryParse(b['confidence_score']?.toString() ?? '0') ?? 0;
        return cb > ca ? b : a;
      });
      notes.add('${hits.length} records share this marking; all agree on origin');
      return MatchResult(matched: true, method: method, score: score, component: best,
          suggestions: hits.where((h) => h != best).map((h) => Candidate(h, score)).toList(),
          normalizedInput: key, notes: notes, trace: trace);
    }
    final sortedVerdicts = verdicts.toList()..sort();
    notes.add('CONFLICT: ${hits.length} records share this marking with differing origin '
        'verdicts (${sortedVerdicts.join(', ')}). Manual adjudication required.');
    return MatchResult(matched: false, method: 'conflict', score: score,
        suggestions: hits.map((h) => Candidate(h, score)).toList(),
        normalizedInput: key, notes: notes, trace: trace);
  }
}

class Verdict {
  final String result;   // chinese | non_chinese | unknown_origin | not_found
  final String banner;   // RED | GREEN | YELLOW | GREY
  final String headline;
  final String action;
  final bool alert;
  final bool vibrate;
  final bool escalate;
  final String escalationNote;
  final String criticality;
  final String criticalityPolicy;
  final double confidence;
  /// What the origin claim rests on: component | manufacturer | unit_marking | none.
  final String originEvidence;
  final String evidenceDetail;
  final bool reviewRequired;
  /// The configured policy's decision for this result, in words.
  final String policyDecision;
  Verdict({
    required this.result, required this.banner, required this.headline,
    this.action = '', this.alert = false, this.vibrate = false,
    this.escalate = false, this.escalationNote = '', this.criticality = '',
    this.criticalityPolicy = '', this.confidence = 0,
    this.originEvidence = 'none', this.evidenceDetail = '',
    this.reviewRequired = true, this.policyDecision = '',
  });

  /// Built from the server's ScanResult JSON (backend/app/models/schemas.py).
  factory Verdict.fromServer(Map<String, dynamic> j) => Verdict(
        result: j['result']?.toString() ?? 'not_found',
        banner: j['banner']?.toString() ?? 'GREY',
        headline: j['headline']?.toString() ?? '',
        action: j['action']?.toString() ?? '',
        alert: j['alert'] == true, vibrate: j['vibrate'] == true,
        escalate: j['escalate'] == true,
        escalationNote: j['escalation_note']?.toString() ?? '',
        criticality: j['criticality']?.toString() ?? '',
        confidence: double.tryParse(j['confidence']?.toString() ?? '') ?? 0,
        originEvidence: j['origin_evidence']?.toString() ?? 'none',
        evidenceDetail: j['evidence_detail']?.toString() ?? '',
        reviewRequired: j['review_required'] != false,
        policyDecision: j['policy_decision']?.toString() ?? '',
      );

  Verdict copyWith({String? result, String? banner, String? headline, String? action,
      bool? alert, bool? vibrate, bool? escalate, String? escalationNote,
      String? originEvidence, String? evidenceDetail, bool? reviewRequired,
      String? policyDecision}) => Verdict(
        result: result ?? this.result, banner: banner ?? this.banner,
        headline: headline ?? this.headline, action: action ?? this.action,
        alert: alert ?? this.alert, vibrate: vibrate ?? this.vibrate,
        escalate: escalate ?? this.escalate,
        escalationNote: escalationNote ?? this.escalationNote,
        criticality: criticality, criticalityPolicy: criticalityPolicy,
        confidence: confidence,
        originEvidence: originEvidence ?? this.originEvidence,
        evidenceDetail: evidenceDetail ?? this.evidenceDetail,
        reviewRequired: reviewRequired ?? this.reviewRequired,
        policyDecision: policyDecision ?? this.policyDecision,
      );
}

/// Match methods that identify a component only approximately - never a
/// clean pass. Mirrors UNCERTAIN_METHODS in backend/app/services/matching.py.
const Set<String> kUncertainMethods = {'fuzzy', 'prefix', 'ocr_folded', 'ocr_folded_stripped'};
const Set<String> _unknownCountry = {'UNKNOWN', 'UNK', 'N/A', 'NA', '-', '?', 'TBD', 'NONE'};

/// What a catalogue record's origin claim rests on. Mirrors origin_evidence()
/// in backend/app/services/matching.py - see ORIGIN_VERIFICATION_LOGIC.md.
(String, String) originEvidence(ComponentRow? c) {
  if (c == null) return ('none', '');
  final src = (c['verification_source']?.toString() ?? '').trim();
  final country = (c['country_of_origin']?.toString() ?? '').trim();
  final isCn = (c['is_chinese']?.toString() ?? 'UNKNOWN').toUpperCase();
  final by = (c['verified_by']?.toString() ?? '').trim();
  if ((isCn != 'YES' && isCn != 'NO') || country.isEmpty || country.toUpperCase() == 'UNKNOWN') {
    return ('none', 'The catalogue record has no documented country of origin.');
  }
  final cat = (c['category']?.toString() ?? '').trim().toUpperCase();
  if (cat == 'OEM / LRU' || src.toUpperCase().contains('OEM LANDSCAPE')) {
    return ('manufacturer',
        'Manufacturer/OEM home country only ($country); source: '
        '${src.isEmpty ? 'not recorded' : src}. This is not the component\'s '
        'documented place of manufacture.');
  }
  return ('component',
      'Catalogue record: $country; source: ${src.isEmpty ? 'not recorded' : src}'
      '${by.isNotEmpty ? '; verified by $by' : ''}.');
}

String policyDecision(String result, String criticality, [String criticalityPolicy = '']) {
  final crit = criticality.toUpperCase();
  final pol = criticalityPolicy.trim();
  if (result == 'chinese') {
    if (crit == 'CRITICAL') {
      return 'NOT ACCEPTABLE${pol.isNotEmpty ? ' - $pol' : ' in a CRITICAL subsystem'}';
    }
    if (crit == 'NON-CRITICAL') {
      return 'PERMITTED BY POLICY${pol.isNotEmpty ? ' - $pol' : ''}'
          ' (Chinese origin recorded; non-critical subsystem)';
    }
    return 'REFER TO INSPECTING AUTHORITY - subsystem not classified in the policy matrix';
  }
  if (result == 'non_chinese') return 'ACCEPTABLE - no Chinese-origin evidence for this marking';
  if (result == 'unknown_origin') {
    return 'REQUIRES MANUAL REVIEW - origin or identity not established';
  }
  return 'NOT IN CATALOGUE - REQUIRES MANUAL REVIEW';
}

/// Mirrors verdict_for() in backend/app/services/matching.py exactly.
Verdict verdictFor(ComponentRow? component, [double score = 100, String? method]) {
  if (component == null) {
    return Verdict(result: 'not_found', banner: 'GREY', headline: 'COMPONENT NOT FOUND',
        action: 'Capture images and save for review',
        policyDecision: policyDecision('not_found', ''));
  }
  final isChinese = (component['is_chinese']?.toString() ?? 'UNKNOWN').toUpperCase();
  var origin = (component['country_of_origin']?.toString() ?? '').trim();
  if (_unknownCountry.contains(origin.toUpperCase())) origin = '';
  final crit = (component['criticality']?.toString() ?? 'REVIEW').toUpperCase();
  final critPolicy = component['criticality_policy']?.toString() ?? '';
  final conf = double.tryParse(component['confidence_score']?.toString() ?? '0') ?? 0;
  final effective = math.min(conf, score);
  final (tier, detail) = originEvidence(component);
  final uncertain = kUncertainMethods.contains(method ?? '');

  String result, banner, headline, action = '';
  var alert = false;
  if (isChinese == 'YES') {
    result = 'chinese'; banner = 'RED'; headline = 'CHINESE COMPONENT DETECTED'; alert = true;
  } else if (isChinese == 'NO' && origin.isNotEmpty) {
    result = 'non_chinese'; banner = 'GREEN'; headline = 'NON-CHINESE COMPONENT';
  } else {
    result = 'unknown_origin'; banner = 'YELLOW'; headline = 'ORIGIN NOT FOUND';
    action = 'Needs verification — refer to database manager';
  }

  if (effective < kLowConfidenceFloor && result == 'non_chinese') {
    result = 'unknown_origin'; banner = 'YELLOW'; headline = 'ORIGIN NOT CONFIRMED';
    action = 'Match confidence ${effective.toStringAsFixed(0)}% is below the '
        '${kLowConfidenceFloor.toStringAsFixed(0)}% floor — verify manually';
  }
  if (result == 'non_chinese' && tier == 'manufacturer') {
    result = 'unknown_origin'; banner = 'YELLOW';
    headline = 'OEM NON-CHINESE - COMPONENT ORIGIN NOT DOCUMENTED';
    action = 'Only the manufacturer\'s home country is on record. Confirm the component\'s '
        'country of manufacture (package COO marking, datasheet or supplier certificate '
        'of conformance).';
  }
  if (result == 'chinese' && tier == 'manufacturer') {
    headline = 'CHINESE MANUFACTURER - COMPONENT ORIGIN PRESUMED CHINESE';
    action = 'The catalogue records a Chinese manufacturer/OEM, not this unit\'s place of '
        'manufacture. Treat as Chinese-origin unless documented otherwise.';
  }
  if (uncertain && result == 'non_chinese') {
    result = 'unknown_origin'; banner = 'YELLOW';
    headline = 'IDENTITY UNCERTAIN - REQUIRES MANUAL REVIEW';
    action = 'Matched by \'$method\' at ${score.toStringAsFixed(0)}%. Compare the marking on '
        'the part with the catalogue record before accepting.';
  }
  if (uncertain && result == 'chinese') {
    headline = 'PROBABLE CHINESE COMPONENT - CONFIRM MARKING';
    action = 'Matched by \'$method\' at ${score.toStringAsFixed(0)}%. Treat as Chinese-origin '
        'until the marking is confirmed by eye.';
  }

  final escalate = result == 'chinese' && crit == 'CRITICAL';
  return Verdict(
    result: result, banner: banner, headline: headline, action: action,
    alert: alert, vibrate: alert, criticality: crit, criticalityPolicy: critPolicy,
    confidence: (effective * 10).round() / 10,
    escalate: escalate,
    escalationNote: escalate
        ? (critPolicy.isNotEmpty ? critPolicy : 'Chinese origin not acceptable in this subsystem')
        : '',
    originEvidence: tier, evidenceDetail: detail,
    reviewRequired: uncertain || result != 'non_chinese',
    policyDecision: policyDecision(result, crit, critPolicy),
  );
}
