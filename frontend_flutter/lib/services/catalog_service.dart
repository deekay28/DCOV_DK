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
  String get source => _source; // 'bundled' | 'server' | 'server_cache' | 'device_import'
  Map<String, dynamic>? _importInfo;
  /// Set when the active catalogue was imported from a file on this device.
  Map<String, dynamic>? get importInfo => _importInfo;
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
      final imported = j['source'] == 'device_import';
      _source = imported ? 'device_import' : 'server_cache';
      _importInfo = imported ? (j['import'] as Map?)?.cast<String, dynamic>() : null;
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
    _importInfo = null;
    _loadedAt = DateTime.now();
    try {
      final f = await _cacheFile();
      if (f != null) {
        final tmp = File('${f.path}.tmp');
        await tmp.writeAsString(jsonEncode(
            {'source': 'server', 'synced_at': _loadedAt!.toIso8601String(), 'rows': rows}), flush: true);
        await tmp.rename(f.path); // atomic replace: never a half-written cache
      }
    } catch (_) {/* cache is an optimisation; the in-memory index is current */}
    return rows.length;
  }

  // ------------------------------------------------ on-device import -- //
  Future<File?> _sideFile(String name) async {
    if (kIsWeb) return null;
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$name');
  }

  Future<void> _writeAtomic(File f, String text) async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(text, flush: true);
    await tmp.rename(f.path);
  }

  /// Makes [rows] the active catalogue (persisted, survives restarts). The
  /// catalogue it replaces is kept as a one-step backup for [rollbackDeviceImport].
  Future<void> applyDeviceImport(List<Map<String, dynamic>> rows, Map<String, dynamic> info) async {
    final cache = await _cacheFile();
    final backup = await _sideFile('dcov_catalogue_backup.json');
    if (cache == null || backup == null) throw StateError('No writable storage on this platform.');
    if (await cache.exists()) {
      await _writeAtomic(backup, await cache.readAsString());
    } else {
      await _writeAtomic(backup, jsonEncode({'bundled': true}));
    }
    final now = DateTime.now();
    await _writeAtomic(cache, jsonEncode(
        {'source': 'device_import', 'synced_at': now.toIso8601String(), 'import': info, 'rows': rows}));
    _index = ComponentIndex(rows);
    _source = 'device_import';
    _importInfo = info;
    _loadedAt = now;
    await _log({...info, 'action': 'import', 'at': now.toIso8601String(), 'rows_after': rows.length});
  }

  Future<bool> canRollback() async {
    final b = await _sideFile('dcov_catalogue_backup.json');
    return b != null && await b.exists();
  }

  /// Restores the catalogue that was active before the last device import.
  Future<void> rollbackDeviceImport(String by) async {
    final cache = await _cacheFile();
    final backup = await _sideFile('dcov_catalogue_backup.json');
    if (cache == null || backup == null || !await backup.exists()) {
      throw StateError('Nothing to undo.');
    }
    final j = jsonDecode(await backup.readAsString()) as Map<String, dynamic>;
    if (j['bundled'] == true) {
      if (await cache.exists()) await cache.delete();
      await loadBundled();
      _importInfo = null;
    } else {
      await _writeAtomic(cache, jsonEncode(j));
      await loadCached();
    }
    await backup.delete();
    await _log({'action': 'undo', 'by': by, 'at': DateTime.now().toIso8601String(),
        'rows_after': _index.rows.length, 'restored_source': _source});
  }

  Future<void> _log(Map<String, dynamic> entry) async {
    try {
      final f = await _sideFile('dcov_import_log.json');
      if (f == null) return;
      final list = await importLog();
      list.insert(0, entry);
      await _writeAtomic(f, jsonEncode(list.take(200).toList()));
    } catch (_) {/* the log is informative; never block an import on it */}
  }

  /// Newest first.
  Future<List<Map<String, dynamic>>> importLog() async {
    try {
      final f = await _sideFile('dcov_import_log.json');
      if (f == null || !await f.exists()) return [];
      return (jsonDecode(await f.readAsString()) as List)
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();
    } catch (_) {
      return [];
    }
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
