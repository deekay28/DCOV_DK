/// Ranking of OCR'd text lines into candidate part-number markings.
///
/// Dart port of classify_marking() / score_candidate() in
/// backend/app/services/ocr.py, so on-device OCR (ML Kit) and server OCR
/// (Tesseract/EasyOCR) rank the same text the same way. Pure Dart - no
/// plugin imports - so it is unit-testable with `flutter test`.
library;

final RegExp _rePart = RegExp(r'^[A-Z]{1,5}[A-Z0-9\-/]{3,22}$');
final RegExp _reDate = RegExp(r'^(19|20)?\d{2}(0[1-9]|[1-4]\d|5[0-3])$');
final RegExp _reLot = RegExp(r'^[A-Z0-9]{2,6}$');
final RegExp _reCoo = RegExp(
    r'\b(CHN|CHINA|TWN|TAIWAN|PHL|PHILIPPINES|MYS|MALAYSIA|KOR|KOREA|SGP|SINGAPORE|'
    r'USA|JPN|JAPAN|FRA|ITA|MLT|MADE IN [A-Z]+)\b');
const Set<String> _vendorWords = {
  'STMICROELECTRONICS', 'ST', 'TI', 'TEXAS', 'NXP', 'MICROCHIP', 'ATMEL', 'REALTEK',
  'BROADCOM', 'ANALOG', 'DEVICES', 'MEDIATEK', 'SANDISK', 'MACRONIX', 'WINBOND', 'CIRRUS',
  'SILICON', 'LABS', 'NVIDIA', 'XILINX', 'MICRON', 'ONSEMI', 'DIODES', 'ALLWINNER',
  'FORESEE', 'MONOLITHIC',
};
const Set<String> _noise = {'E4', 'CE', 'FC', 'ROHS', 'PB', 'LF', 'GREEN', 'ESD'};

String classifyMarking(String text) {
  final t = text.toUpperCase().replaceAll(RegExp(r'\s+'), '');
  if (t.isEmpty) return 'noise';
  if (_reCoo.hasMatch(text.toUpperCase())) return 'country_of_origin';
  if (_vendorWords.contains(t) ||
      _vendorWords.any((v) => t.startsWith(v) && t.length <= v.length + 2)) {
    return 'vendor';
  }
  if (_noise.contains(t)) return 'noise';
  if (t.length == 4 && _reDate.hasMatch(t)) return 'date_code';
  if (_rePart.hasMatch(t) && t.contains(RegExp(r'\d')) && t.length >= 5) return 'part_number';
  if (_reLot.hasMatch(t)) return 'lot_code';
  return 'other';
}

double scoreCandidate(String text) {
  final t = text.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  final kind = classifyMarking(text);
  var base = const {
    'part_number': 100.0, 'other': 55.0, 'lot_code': 25.0, 'date_code': 5.0,
    'vendor': 10.0, 'country_of_origin': 15.0, 'noise': 0.0,
  }[kind]!;
  if (t.length >= 8 && t.length <= 16) {
    base += 12;
  } else if (t.length < 6) {
    base -= 20;
  }
  final letters = t.split('').where((c) => RegExp(r'[A-Z]').hasMatch(c)).length;
  final digits = t.split('').where((c) => RegExp(r'\d').hasMatch(c)).length;
  if (letters > 0 && digits > 0) base += 8;
  if (digits > 0 && letters == 0) base -= 15;
  return base;
}

class RankedOcr {
  /// Physical lines as read, spaces kept (for the marking-consistency check).
  final List<String> lines;
  /// Candidate markings, best first.
  final List<String> candidates;
  final List<String> warnings;
  /// More than one distinct full-length part number in one frame.
  final bool multipleParts;
  RankedOcr(this.lines, this.candidates, this.warnings, this.multipleParts);
  String get best => candidates.isEmpty ? '' : candidates.first;
  String get fullText => lines.join('\n');
}

/// Turns raw recognised lines into ranked word-level candidates.
RankedOcr rankOcrLines(List<String> rawLines) {
  final lines = rawLines
      .map((l) => l.toUpperCase().replaceAll(RegExp(r'\s+'), ' ').trim())
      .where((l) => l.isNotEmpty)
      .toList();
  final seen = <String>{};
  final cands = <String>[];
  // Word level, as the server does (Tesseract words): joining a whole line
  // would turn a lot-code line such as "GQ23J 1B9U" into a part-number-shaped
  // "GQ23J1B9U" that competes with the real part number.
  for (final l in lines) {
    for (final piece in l.split(' ')) {
      final k = piece.replaceAll(RegExp(r'[^A-Z0-9]'), '');
      if (k.length >= 2 && seen.add(k)) cands.add(k);
    }
  }
  // Stable ranking: score, then reading order (List.sort is not stable).
  final order = {for (var i = 0; i < cands.length; i++) cands[i]: i};
  cands.sort((a, b) {
    final c = scoreCandidate(b).compareTo(scoreCandidate(a));
    return c != 0 ? c : order[a]!.compareTo(order[b]!);
  });
  final warnings = <String>[];
  final parts = cands.where((c) => classifyMarking(c) == 'part_number' && c.length >= 8).toList();
  final distinct = <String>[];
  for (final p in parts) {
    if (distinct.every((d) => !_similar(p, d))) distinct.add(p);
  }
  final multiple = distinct.length > 1;
  if (cands.isEmpty) {
    warnings.add('No legible text found. Move closer, light the chip from the side to '
        'avoid glare, or type the marking.');
  } else if (parts.isEmpty) {
    warnings.add('No line has the shape of a part number - the best candidate may be a '
        'lot or date code. Confirm by eye.');
  }
  if (multiple) {
    warnings.add('${distinct.length} different part numbers in one photo '
        '(${distinct.take(4).join(', ')}). Choose the one you are inspecting, or '
        'photograph one component at a time.');
  }
  return RankedOcr(lines, cands.take(12).toList(), warnings, multiple);
}

bool _similar(String a, String b) {
  if (a.contains(b) || b.contains(a)) return true;
  final n = a.length > b.length ? a.length : b.length;
  var same = 0;
  for (var i = 0; i < a.length && i < b.length; i++) {
    if (a[i] == b[i]) same++;
  }
  return same / n >= 0.8;
}
