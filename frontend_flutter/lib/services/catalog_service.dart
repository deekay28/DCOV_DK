import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'matching.dart';
import 'api_client.dart';

/// Owns the component catalogue and its match index. Boots instantly from
/// the bundled seed asset (same 203-row dataset as web_demo/seed_data.js and
/// data/components_seed.json, so a brand-new install works fully offline
/// from the first launch) and can be refreshed from a live backend when one
/// is reachable.
class CatalogService {
  ComponentIndex _index = ComponentIndex(const []);
  DateTime? _loadedAt;
  String _source = 'none';
  Map<String, dynamic> _policy = const {};

  ComponentIndex get index => _index;
  DateTime? get loadedAt => _loadedAt;
  String get source => _source; // 'bundled' | 'server' | 'server_cache'
  Map<String, dynamic> get policy => _policy;
  int get count => _index.rows.length;

  Future<void> loadBundled() async {
    final raw = await rootBundle.loadString('assets/data/components_seed.json');
    final rows = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    _index = ComponentIndex(rows);
    _source = 'bundled';
    _loadedAt = DateTime.now();
    try {
      final polRaw = await rootBundle.loadString('assets/data/policy.json');
      _policy = (jsonDecode(polRaw) as Map<String, dynamic>)['criticality']
              as Map<String, dynamic>? ??
          {};
    } catch (_) {
      _policy = const {};
    }
  }

  /// Loads the last catalogue synced from the server, if this device has
  /// one. Without this, an app restarted in the field (no network) silently
  /// fell back to the bundled seed - which can hold a stale origin for a part
  /// the server has since reclassified. Returns true when a cache was used.
  Future<bool> loadCached() async {
    try {
      final f = await _cacheFile();
      if (f == null || !await f.exists()) return false;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final rows = (j['rows'] as List).cast<Map<String, dynamic>>();
      if (rows.isEmpty) return false;
      _index = ComponentIndex(rows);
      _source = 'server_cache';
      _loadedAt = DateTime.tryParse(j['synced_at']?.toString() ?? '') ?? DateTime.now();
      return true;
    } catch (_) {
      return false; // corrupt cache: keep the bundled catalogue
    }
  }

  Future<File?> _cacheFile() async {
    if (kIsWeb) return null;
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/dcov_catalogue_cache.json');
  }

  /// Server data always wins - the catalogue is authoritative there, and a
  /// device must never keep a stale verdict for a part that has since been
  /// reclassified. See backend/app/api/field_ops.py `sync_pull` for the
  /// matching server-side comment.
  Future<int> refreshFromServer(DcovApiClient client) async {
    final rows = await client.fetchAllComponents();
    if (rows.isEmpty) return 0;
    _index = ComponentIndex(rows);
    _source = 'server';
    _loadedAt = DateTime.now();
    try {
      final f = await _cacheFile();
      if (f != null) {
        final tmp = File('${f.path}.tmp');
        await tmp.writeAsString(jsonEncode(
            {'synced_at': _loadedAt!.toIso8601String(), 'rows': rows}), flush: true);
        await tmp.rename(f.path); // atomic replace: never a half-written cache
      }
    } catch (_) {/* cache is an optimisation; the in-memory index is current */}
    return rows.length;
  }

  Map<String, int> get counts {
    final rows = _index.rows;
    return {
      'total': rows.length,
      'chinese': rows.where((r) => r['is_chinese'] == 'YES').length,
      'non_chinese': rows.where((r) => r['is_chinese'] == 'NO').length,
      'unknown': rows.where((r) => r['is_chinese'] == 'UNKNOWN').length,
      'chinese_critical': rows
          .where((r) => r['is_chinese'] == 'YES' && r['criticality'] == 'CRITICAL')
          .length,
    };
  }

  List<String> distinctValues(String field) {
    final s = _index.rows.map((r) => r[field]?.toString() ?? '').where((v) => v.isNotEmpty).toSet().toList();
    s.sort();
    return s;
  }
}
