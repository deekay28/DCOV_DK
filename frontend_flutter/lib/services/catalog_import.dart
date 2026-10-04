import 'dart:convert';
import 'package:archive/archive.dart' as arc;
import 'package:crypto/crypto.dart' as crypto;
import 'matching.dart';

/// On-device catalogue import (offline mode): .xlsx / .csv / .tsv / .json ->
/// column mapping -> validation -> diff against the current catalogue ->
/// preview. Nothing is applied here; CatalogService.applyDeviceImport does
/// that after the operator confirms.
///
/// Ported from backend/app/services/importer.py so a worksheet that imports
/// cleanly on the server imports the same way on the phone: same header
/// synonyms, same required fields, same origin derivation
/// (derive_is_chinese), same "unknown country => UNKNOWN, never NO" rule.
/// Differences, deliberately: no manufacturer alias table (manufacturer is
/// kept as written), and generated ids are prefixed DEV- so a device-made id
/// is never mistaken for a server id.

const List<String> kCanonicalFields = [
  'component_id', 'component_name', 'part_number', 'chip_number', 'manufacturer',
  'manufacturer_country', 'country_of_origin', 'is_chinese', 'category',
  'drone_subsystem', 'criticality', 'criticality_policy', 'alternative_manufacturer',
  'military_grade', 'barcode', 'qr_code', 'function', 'remarks', 'image_path',
  'datasheet_url', 'supplier', 'verified_by', 'verification_source', 'confidence_score',
];

const Map<String, List<String>> kHeaderSynonyms = {
  'component_id': ['component id', 'comp id', 'id', 'ser no', 'ser', 'sl no'],
  'component_name': ['component name', 'name of item', 'item', 'main component',
      'nomenclature', 'description', 'sys/ sub sys'],
  'part_number': ['part number', 'part no', 'pn', 'model no', 'model/make', 'model'],
  'chip_number': ['chip number', 'chip no', 'chip', 'sub component / chip no',
      'chinese component chip name', 'sub component', 'ic ref', 'chinese ic ref', 'marking'],
  'manufacturer': ['manufacturer', 'mfr', 'oem', 'make', 'manufacturer of component',
      'vendor', 'supplier name'],
  'manufacturer_country': ['manufacturer country', 'mfr country', 'oem country'],
  'country_of_origin': ['country of origin', 'coo', 'origin', 'country', 'country of origin (coo)'],
  'is_chinese': ['chinese', 'chinese (yes/no)', 'is chinese', 'chinese origin'],
  'category': ['category', 'type', 'component category'],
  'drone_subsystem': ['drone subsystem', 'sub sys', 'subsystem', 'drone system',
      'sub system where typically likely to be found', 'sub sys where typically likely to be found'],
  'criticality': ['criticality', 'critical', 'critical/non critical'],
  'alternative_manufacturer': ['alternative manufacturer', 'alternative', 'alternate',
      'alternative parts', 'substitute'],
  'military_grade': ['military grade', 'mil grade', 'mil spec'],
  'barcode': ['barcode', 'bar code', 'ean', 'upc'],
  'qr_code': ['qr code', 'qr'],
  'function': ['function', 'purpose', 'role'],
  'remarks': ['remarks', 'notes', 'any other details', 'comment', 'observation',
      'photograph / remarks'],
  'image_path': ['image', 'photograph', 'photo', 'image path'],
  'datasheet_url': ['datasheet', 'datasheet url', 'spec sheet'],
  'supplier': ['supplier', 'procured from', 'source'],
  'verified_by': ['verified by', 'inspector', 'checked by'],
  'verification_source': ['verification source', 'evidence', 'source'],
  'confidence_score': ['confidence score', 'confidence', 'conf %'],
  'criticality_policy': ['criticality policy', 'policy', 'acceptance policy'],
};

const Set<String> kIgnoredHeaders = {'date added', 'last updated', 'created at', 'updated at',
    'revision', 'search key', 'id', 'row', 'photograph'};

const List<String> _chinaPhrases = ['MADE IN CHINA', 'COO CHINA', 'COO: CHINA', 'ORIGIN CHINA', 'PRC'];
const List<String> _chinaCountries = ['CHINA', 'PRC', 'HONG KONG', 'MACAU', 'SHENZHEN', 'CHN'];
const Set<String> _unknownCountryValues = {'UNKNOWN', 'UNK', 'N/A', 'NA', '-', '--', '?', 'TBD',
    'TBC', 'NOT KNOWN', 'NOT ESTABLISHED', 'NONE', 'NIL', 'UNDETERMINED'};

const List<String> kCompareFields = ['component_name', 'part_number', 'chip_number', 'manufacturer',
    'manufacturer_country', 'country_of_origin', 'is_chinese', 'category', 'drone_subsystem',
    'criticality', 'criticality_policy', 'alternative_manufacturer', 'military_grade', 'barcode',
    'qr_code', 'function', 'remarks', 'datasheet_url', 'supplier', 'verified_by',
    'verification_source', 'confidence_score'];

const int kMaxImportBytes = 20 * 1024 * 1024;
const int kMaxImportRows = 50000;

/// Same rule as backend derive_is_chinese.
String deriveIsChinese(String country, [String remarks = '', String declared = '']) {
  final d = declared.trim().toUpperCase();
  if (const {'YES', 'Y', 'TRUE', '1'}.contains(d)) return 'YES';
  if (const {'NO', 'N', 'FALSE', '0'}.contains(d)) return 'NO';
  final blob = '$country $remarks'.toUpperCase();
  if (_chinaPhrases.any(blob.contains)) return 'YES';
  final cu = country.trim().toUpperCase();
  if (cu.isEmpty || _unknownCountryValues.contains(cu)) return 'UNKNOWN';
  if (_chinaCountries.any(cu.contains)) return 'YES';
  return 'NO';
}

String cleanHeader(String h) => h
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r'[_\-]+'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

double _ratio(String a, String b) {
  if (a.isEmpty || b.isEmpty) return 0;
  final longest = a.length > b.length ? a.length : b.length;
  return 1 - damerauLevenshtein(a, b) / longest;
}

/// header -> canonical field. Exact synonym first, then fuzzy >= 0.82.
Map<String, String> autoMapColumns(List<String> headers) {
  final mapping = <String, String>{};
  final taken = <String>{};
  for (final h in headers) {
    final cl = cleanHeader(h);
    if (cl.isEmpty) continue;
    for (final e in kHeaderSynonyms.entries) {
      if (taken.contains(e.key)) continue;
      if (cl == e.key.replaceAll('_', ' ') || e.value.contains(cl)) {
        mapping[h] = e.key;
        taken.add(e.key);
        break;
      }
    }
  }
  for (final h in headers) {
    if (mapping.containsKey(h)) continue;
    final cl = cleanHeader(h);
    if (cl.isEmpty || kIgnoredHeaders.contains(cl)) continue;
    String? best;
    var bestScore = 0.0;
    for (final e in kHeaderSynonyms.entries) {
      if (taken.contains(e.key)) continue;
      for (final cand in [e.key.replaceAll('_', ' '), ...e.value]) {
        final s = _ratio(cl, cand);
        if (s > bestScore) {
          best = e.key;
          bestScore = s;
        }
      }
    }
    if (best != null && bestScore >= 0.82) {
      mapping[h] = best;
      taken.add(best);
    }
  }
  return mapping;
}

// --------------------------------------------------------------- parsing -- //

/// RFC 4180 CSV. Delimiter auto-detected among , ; and TAB.
List<List<String>> parseCsv(String text) {
  if (text.startsWith('﻿')) text = text.substring(1);
  final firstLine = text.split(RegExp(r'\r?\n')).firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
  var delim = ',';
  var best = -1;
  for (final d in [',', ';', '\t']) {
    final n = d.allMatches(firstLine).length;
    if (n > best) {
      best = n;
      delim = d;
    }
  }
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var inQuotes = false;
  var i = 0;
  while (i < text.length) {
    final ch = text[i];
    if (inQuotes) {
      if (ch == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i += 2;
          continue;
        }
        inQuotes = false;
      } else {
        field.write(ch);
      }
    } else if (ch == '"' && field.isEmpty) {
      inQuotes = true;
    } else if (ch == delim) {
      row.add(field.toString());
      field.clear();
    } else if (ch == '\n' || ch == '\r') {
      row.add(field.toString());
      field.clear();
      rows.add(row);
      row = <String>[];
      if (ch == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
    } else {
      field.write(ch);
    }
    i++;
  }
  if (field.isNotEmpty || row.isNotEmpty) {
    row.add(field.toString());
    rows.add(row);
  }
  return rows;
}

String _xmlUnescape(String s) => s
    .replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'),
        (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)))
    .replaceAllMapped(RegExp(r'&#(\d+);'), (m) => String.fromCharCode(int.parse(m.group(1)!)))
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');

final RegExp _tText = RegExp(r'<t(?:\s[^>]*)?>([\s\S]*?)</t>');

int _colIndex(String ref) {
  var n = 0;
  for (final c in ref.codeUnits) {
    if (c >= 65 && c <= 90) {
      n = n * 26 + (c - 64);
    } else if (c >= 97 && c <= 122) {
      n = n * 26 + (c - 96);
    } else {
      break;
    }
  }
  return n - 1;
}

String _numberText(String v) {
  // Excel stores 8907625371046 as a number; keep it as written, not 8.9E12.
  final d = double.tryParse(v);
  if (d == null) return v;
  if (d == d.roundToDouble() && d.abs() < 1e15) return d.toStringAsFixed(0);
  return v;
}

/// Minimal .xlsx reader: shared strings, inline strings, numbers, booleans.
/// Returns the largest worksheet (the server importer picks the same).
List<List<String>> readXlsx(List<int> bytes) {
  final archive = arc.ZipDecoder().decodeBytes(bytes);
  String? fileText(String name) {
    for (final f in archive.files) {
      if (f.isFile && f.name == name) {
        return utf8.decode(f.content as List<int>, allowMalformed: true);
      }
    }
    return null;
  }

  final shared = <String>[];
  final ss = fileText('xl/sharedStrings.xml');
  if (ss != null) {
    for (final si in RegExp(r'<si>([\s\S]*?)</si>').allMatches(ss)) {
      shared.add(_xmlUnescape(_tText.allMatches(si.group(1)!).map((m) => m.group(1)!).join()));
    }
  }

  List<List<String>> best = const [];
  var bestCells = -1;
  final sheetNames = archive.files
      .where((f) => f.isFile && RegExp(r'^xl/worksheets/sheet\d+\.xml$').hasMatch(f.name))
      .map((f) => f.name)
      .toList()
    ..sort();
  for (final name in sheetNames) {
    final xml = fileText(name) ?? '';
    final rows = <List<String>>[];
    var cells = 0;
    for (final rm in RegExp(r'<row\b[^>]*?(?:/>|>([\s\S]*?)</row>)').allMatches(xml)) {
      final body = rm.group(1) ?? '';
      final row = <String>[];
      var next = 0;
      for (final cm in RegExp(r'<c\b([^>]*?)(?:/>|>([\s\S]*?)</c>)').allMatches(body)) {
        final attrs = cm.group(1) ?? '';
        final inner = cm.group(2) ?? '';
        final ref = RegExp(r'\br="([A-Za-z]+)\d*"').firstMatch(attrs)?.group(1);
        final col = ref != null ? _colIndex(ref) : next;
        final type = RegExp(r'\bt="([^"]+)"').firstMatch(attrs)?.group(1) ?? 'n';
        final v = RegExp(r'<v>([\s\S]*?)</v>').firstMatch(inner)?.group(1);
        String text;
        if (type == 's') {
          final idx = int.tryParse(v ?? '');
          text = (idx != null && idx >= 0 && idx < shared.length) ? shared[idx] : '';
        } else if (type == 'inlineStr') {
          text = _xmlUnescape(_tText.allMatches(inner).map((m) => m.group(1)!).join());
        } else if (type == 'b') {
          text = v == '1' ? 'TRUE' : (v == null ? '' : 'FALSE');
        } else if (type == 'str' || type == 'e') {
          text = _xmlUnescape(v ?? '');
        } else {
          text = v == null ? '' : _numberText(v);
        }
        while (row.length < col) {
          row.add('');
        }
        if (row.length == col) {
          row.add(text);
        } else {
          row[col] = text;
        }
        if (text.isNotEmpty) cells++;
        next = col + 1;
      }
      rows.add(row);
    }
    if (cells > bestCells) {
      bestCells = cells;
      best = rows;
    }
  }
  if (bestCells < 0) throw const FormatException('No worksheet found in the .xlsx file.');
  return best;
}

/// First row in the first 15 with >= 2 non-empty cells, mostly non-numeric.
int detectHeaderRow(List<List<String>> rows) {
  for (var i = 0; i < rows.length && i < 15; i++) {
    final cells = rows[i].map((c) => c.trim()).where((c) => c.isNotEmpty).toList();
    if (cells.length < 2) continue;
    final texty = cells.where((c) => double.tryParse(c) == null).length;
    if (texty / cells.length >= 0.6) return i;
  }
  return -1;
}

// --------------------------------------------------------------- preview -- //

class ImportIssue {
  final int row; // 1-based row number in the file (header = its own row number)
  final String field;
  final String severity; // error | warning
  final String message;
  const ImportIssue(this.row, this.field, this.severity, this.message);
  @override
  String toString() => 'row $row - $field: $message';
}

class ImportPreview {
  final String filename;
  final String format;
  final String sha256;
  final List<String> headers;
  final Map<String, String> mapping;
  final List<String> unmapped;
  final List<Map<String, dynamic>> validRows;
  final List<ImportIssue> errors;
  final List<ImportIssue> warnings;
  final List<String> duplicates;
  final int newCount;
  final int updatedCount;
  final int unchangedCount;
  final int missingFromFile;
  final List<String> originFlips;
  final List<String> notes;

  const ImportPreview({
    required this.filename, required this.format, required this.sha256, required this.headers,
    required this.mapping, required this.unmapped, required this.validRows, required this.errors,
    required this.warnings, required this.duplicates, required this.newCount,
    required this.updatedCount, required this.unchangedCount, required this.missingFromFile,
    required this.originFlips, required this.notes,
  });

  bool get canImport => validRows.isNotEmpty;

  Map<String, int> get originCounts {
    final m = {'YES': 0, 'NO': 0, 'UNKNOWN': 0};
    for (final r in validRows) {
      final k = r['is_chinese']?.toString() ?? 'UNKNOWN';
      m[k] = (m[k] ?? 0) + 1;
    }
    return m;
  }

  /// Rows the catalogue will contain after applying.
  List<Map<String, dynamic>> resultRows(List<Map<String, dynamic>> current, {required bool replace}) {
    if (replace) return validRows.map((r) => Map<String, dynamic>.from(r)).toList();
    final byId = <String, int>{};
    final out = <Map<String, dynamic>>[];
    for (final r in current) {
      final copy = Map<String, dynamic>.from(r);
      byId[copy['component_id']?.toString() ?? ''] = out.length;
      out.add(copy);
    }
    for (final r in validRows) {
      final id = r['component_id']?.toString() ?? '';
      final at = byId[id];
      if (at == null) {
        byId[id] = out.length;
        out.add(Map<String, dynamic>.from(r));
      } else {
        final merged = Map<String, dynamic>.from(out[at]);
        r.forEach((k, v) {
          if (k == 'date_added') return; // keep the original
          if (v != null && v.toString().isNotEmpty) merged[k] = v;
        });
        merged.remove('search_key'); // recomputed by ComponentIndex
        out[at] = merged;
      }
    }
    return out;
  }
}

String _text(dynamic v) => v == null ? '' : v.toString().trim();

String _stableId(Map<String, dynamic> row) {
  final key = normalizeMarking(_text(row['chip_number']).isNotEmpty
      ? _text(row['chip_number'])
      : (_text(row['part_number']).isNotEmpty ? _text(row['part_number']) : _text(row['component_name'])));
  final mfr = _text(row['manufacturer']).toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  final h = crypto.sha1.convert(utf8.encode('$key|$mfr')).toString().substring(0, 8).toUpperCase();
  return 'DEV-$h';
}

/// Parses [bytes] and compares the result with [current] (the catalogue now
/// on the device). Throws FormatException for unreadable files.
ImportPreview buildImportPreview(String filename, List<int> bytes,
    List<Map<String, dynamic>> current, {DateTime? now}) {
  if (bytes.length > kMaxImportBytes) {
    throw FormatException('File is larger than ${kMaxImportBytes ~/ (1024 * 1024)} MB.');
  }
  final lower = filename.toLowerCase();
  final digest = crypto.sha256.convert(bytes).toString();
  final today = (now ?? DateTime.now()).toIso8601String().substring(0, 10);
  final notes = <String>[];

  late String format;
  late List<String> headers;
  late List<Map<String, String>> records; // header -> raw value
  late List<int> fileRowNo;

  if (lower.endsWith('.json')) {
    format = 'json';
    final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    final list = decoded is List
        ? decoded
        : (decoded is Map && decoded['rows'] is List ? decoded['rows'] as List : null);
    if (list == null) throw const FormatException('JSON must be a list of records, or {"rows": [...]}.');
    final hs = <String>[];
    records = [];
    for (final e in list) {
      if (e is! Map) continue;
      final m = <String, String>{};
      e.forEach((k, v) {
        final key = k.toString();
        if (!hs.contains(key)) hs.add(key);
        m[key] = _text(v);
      });
      records.add(m);
    }
    headers = hs;
    fileRowNo = List<int>.generate(records.length, (i) => i + 1);
  } else {
    List<List<String>> table;
    if (lower.endsWith('.xlsx') || lower.endsWith('.xlsm')) {
      format = 'xlsx';
      try {
        table = readXlsx(bytes);
      } catch (e) {
        throw FormatException('Could not read the Excel file ($e). Save it as .xlsx or CSV and retry.');
      }
    } else if (lower.endsWith('.csv') || lower.endsWith('.tsv') || lower.endsWith('.txt')) {
      format = 'csv';
      table = parseCsv(utf8.decode(bytes, allowMalformed: true));
    } else {
      throw const FormatException('Unsupported file type. Use .xlsx, .csv, .tsv or .json. '
          '(Old .xls: open in Excel and "Save As" .xlsx.)');
    }
    final h = detectHeaderRow(table);
    if (h < 0) throw const FormatException('No header row found in the first 15 rows.');
    if (h > 0) notes.add('Header found on row ${h + 1}; $h row(s) above it were skipped.');
    headers = table[h].map((c) => c.trim()).toList();
    records = [];
    fileRowNo = [];
    for (var i = h + 1; i < table.length; i++) {
      final cells = table[i];
      if (cells.every((c) => c.trim().isEmpty)) continue;
      final m = <String, String>{};
      for (var c = 0; c < headers.length; c++) {
        if (headers[c].isEmpty) continue;
        m[headers[c]] = c < cells.length ? cells[c].trim() : '';
      }
      records.add(m);
      fileRowNo.add(i + 1);
    }
  }
  if (records.length > kMaxImportRows) {
    throw FormatException('${records.length} rows - the limit on a phone is $kMaxImportRows.');
  }

  final mapping = autoMapColumns(headers.where((x) => x.isNotEmpty).toList());
  final unmapped = headers
      .where((x) => x.isNotEmpty && !mapping.containsKey(x) && !kIgnoredHeaders.contains(cleanHeader(x)))
      .toList();
  if (!mapping.values.contains('component_name')) {
    notes.add('No column maps to "component name" - every row will be rejected. '
        'Rename the column (e.g. "Component Name") and retry.');
  }
  if (!mapping.values.contains('part_number') && !mapping.values.contains('chip_number')) {
    notes.add('No column maps to a part number or chip number - rows cannot be matched by a scan.');
  }
  if (!mapping.values.contains('country_of_origin') && !mapping.values.contains('is_chinese')) {
    notes.add('No origin column (country of origin / Chinese yes-no) - rows import as UNKNOWN (yellow).');
  }

  final currentById = <String, Map<String, dynamic>>{
    for (final r in current) _text(r['component_id']): r,
  };

  final valid = <Map<String, dynamic>>[];
  final errors = <ImportIssue>[];
  final warnings = <ImportIssue>[];
  final duplicates = <String>[];
  final flips = <String>[];
  final seen = <String, int>{};
  var newCount = 0, updated = 0, unchanged = 0;

  for (var i = 0; i < records.length; i++) {
    final n = fileRowNo[i];
    final raw = records[i];
    final row = <String, dynamic>{for (final f in kCanonicalFields) f: ''};
    final extras = <String>[];
    raw.forEach((h, v) {
      final canon = mapping[h];
      if (canon != null) {
        row[canon] = v;
      } else if (!kIgnoredHeaders.contains(cleanHeader(h)) && v.isNotEmpty) {
        extras.add('$h: $v');
      }
    });
    if (extras.isNotEmpty) {
      final note = extras.join('; ');
      row['remarks'] = _text(row['remarks']).isEmpty ? note : '${row['remarks']} | $note';
    }

    final rowErrors = <ImportIssue>[];
    if (_text(row['component_name']).isEmpty) {
      rowErrors.add(ImportIssue(n, 'component_name', 'error', 'required field is empty'));
    }
    if (_text(row['part_number']).isEmpty && _text(row['chip_number']).isEmpty) {
      rowErrors.add(ImportIssue(n, 'part_number', 'error',
          'neither a part number nor a chip number - can never be matched by a scan'));
    }
    var conf = _text(row['confidence_score']).replaceAll('%', '').trim();
    if (conf.isNotEmpty) {
      final c = double.tryParse(conf);
      if (c == null || c < 0 || c > 100) {
        rowErrors.add(ImportIssue(n, 'confidence_score', 'error', 'must be a number 0-100 (got "$conf")'));
      }
    }
    if (rowErrors.isNotEmpty) {
      errors.addAll(rowErrors);
      continue;
    }
    final mil = _text(row['military_grade']).toUpperCase();
    if (mil.isNotEmpty && mil != 'YES' && mil != 'NO') {
      warnings.add(ImportIssue(n, 'military_grade', 'warning', 'expected YES or NO; value ignored'));
      row['military_grade'] = '';
    } else {
      row['military_grade'] = mil;
    }
    final bc = _text(row['barcode']);
    if (bc.isNotEmpty && !RegExp(r'^[A-Za-z0-9\-._/ ]{4,64}$').hasMatch(bc)) {
      warnings.add(ImportIssue(n, 'barcode', 'warning', 'unusual characters for a barcode payload'));
    }
    if (_text(row['country_of_origin']).isEmpty && _text(row['remarks']).isEmpty &&
        _text(row['is_chinese']).isEmpty) {
      warnings.add(ImportIssue(n, 'country_of_origin', 'warning',
          'no origin evidence - will import as UNKNOWN (yellow banner)'));
    }

    row['is_chinese'] = deriveIsChinese(
        _text(row['country_of_origin']), _text(row['remarks']), _text(row['is_chinese']));
    row['criticality'] = _text(row['criticality']).toUpperCase();
    row['confidence_score'] = conf.isEmpty ? '100' : conf;
    if (_text(row['component_id']).isEmpty) row['component_id'] = _stableId(row);
    if (_text(row['verification_source']).isEmpty) {
      row['verification_source'] = 'Imported on device from $filename';
    }
    row['date_added'] = today;
    row['last_updated'] = today;

    final id = _text(row['component_id']);
    if (seen.containsKey(id)) {
      duplicates.add('row $n repeats $id (first seen on row ${seen[id]}) - skipped');
      continue;
    }
    seen[id] = n;

    final live = currentById[id];
    if (live == null) {
      newCount++;
    } else {
      final changed = kCompareFields.where((f) =>
          _text(row[f]).isNotEmpty && _text(row[f]) != _text(live[f])).toList();
      if (changed.isEmpty) {
        unchanged++;
      } else {
        updated++;
        if (changed.contains('is_chinese')) {
          flips.add('$id ${_text(row['component_name'])}: ${_text(live['is_chinese'])} -> ${_text(row['is_chinese'])}');
        }
      }
    }
    valid.add(row);
  }

  final missing = currentById.keys.where((id) => id.isNotEmpty && !seen.containsKey(id)).length;

  return ImportPreview(
    filename: filename, format: format, sha256: digest, headers: headers, mapping: mapping,
    unmapped: unmapped, validRows: valid, errors: errors, warnings: warnings,
    duplicates: duplicates, newCount: newCount, updatedCount: updated,
    unchangedCount: unchanged, missingFromFile: missing, originFlips: flips, notes: notes,
  );
}
