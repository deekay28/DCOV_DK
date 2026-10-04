import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../services/app_state.dart';
import '../services/catalog_import.dart';
import '../theme/dcov_theme.dart';

/// Import the component catalogue from a file on this phone - no server.
/// Pick -> preview (mapping, counts, errors, origin flips) -> confirm.
class DeviceImportScreen extends StatefulWidget {
  final AppState app;
  const DeviceImportScreen({super.key, required this.app});
  @override
  State<DeviceImportScreen> createState() => _DeviceImportScreenState();
}

class _DeviceImportScreenState extends State<DeviceImportScreen> {
  ImportPreview? _preview;
  bool _busy = false;
  bool _replace = false;
  bool _flipsAcknowledged = false;
  String? _error;
  String? _done;
  bool _canUndo = false;
  List<Map<String, dynamic>> _log = const [];

  @override
  void initState() {
    super.initState();
    _refreshSide();
  }

  Future<void> _refreshSide() async {
    final undo = await widget.app.catalog.canRollback();
    final log = await widget.app.catalog.importLog();
    if (mounted) setState(() { _canUndo = undo; _log = log; });
  }

  Future<void> _pick() async {
    setState(() { _error = null; _done = null; });
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['xlsx', 'xlsm', 'csv', 'tsv', 'txt', 'json'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final f = result.files.first;
    final bytes = f.bytes;
    if (bytes == null) {
      setState(() => _error = 'Could not read the file. Copy it to the phone\'s Downloads folder and retry.');
      return;
    }
    setState(() { _busy = true; _preview = null; _flipsAcknowledged = false; });
    try {
      final p = await widget.app.previewDeviceImport(f.name, bytes);
      if (mounted) setState(() => _preview = p);
    } on FormatException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _apply() async {
    final p = _preview;
    if (p == null) return;
    final after = p.resultRows(widget.app.catalog.index.rows, replace: _replace).length;
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Apply this catalogue?'),
      content: Text('${_replace ? 'REPLACE' : 'MERGE'}: the device catalogue will have $after components '
          '(now ${widget.app.catalog.count}).'
          '${_replace && p.missingFromFile > 0 ? '\n\n${p.missingFromFile} current component(s) are not in the file and will be REMOVED.' : ''}'
          '\n\nYou can undo the last import afterwards.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('CANCEL')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('APPLY')),
      ],
    ));
    if (ok != true) return;
    setState(() { _busy = true; _error = null; });
    try {
      await widget.app.applyDeviceImport(p, replace: _replace);
      if (mounted) {
        setState(() { _done = 'Imported. ${widget.app.catalog.count} components are now active on this device.';
          _preview = null; });
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Import failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refreshSide();
    }
  }

  Future<void> _undo() async {
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Undo the last import?'),
      content: const Text('The catalogue that was active before the last import is restored.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('CANCEL')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('UNDO')),
      ],
    ));
    if (ok != true) return;
    setState(() { _busy = true; _error = null; });
    try {
      await widget.app.undoDeviceImport();
      if (mounted) setState(() => _done = 'Undone. ${widget.app.catalog.count} components active.');
    } catch (e) {
      if (mounted) setState(() => _error = 'Undo failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refreshSide();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final b = Theme.of(context).brightness;
    final p = _preview;
    final info = widget.app.catalog.importInfo;
    return Scaffold(
      appBar: AppBar(title: const Text('IMPORT CATALOGUE (THIS DEVICE)')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text('Active catalogue: ${widget.app.catalog.count} components - '
            '${_sourceLabel(widget.app.catalog.source)}'
            '${info != null ? ' (${info['filename']}, ${info['mode']} by ${info['by']})' : ''}',
            style: TextStyle(fontSize: 12.5, color: t.ink2)),
        const SizedBox(height: 8),
        Text('Excel (.xlsx), CSV or JSON. The first row with column names is used as the header; '
            'names such as "Name of Item", "Chip No", "Mfr", "COO", "Bar Code" are recognised '
            '(same rules as the server import). Old .xls files: open in Excel and Save As .xlsx.',
            style: TextStyle(fontSize: 12, color: t.ink2, height: 1.4)),
        const SizedBox(height: 12),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: _busy ? null : _pick,
          icon: const Icon(Icons.upload_file),
          label: Text(p == null ? 'CHOOSE FILE' : 'CHOOSE A DIFFERENT FILE'),
        ),
        if (_busy) const Padding(padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator())),
        if (_error != null) _box(context, _error!, DcovColors.forBanner('RED', b)),
        if (_done != null) _box(context, _done!, DcovColors.forBanner('GREEN', b)),
        if (p != null) ..._previewWidgets(context, p),
        const SizedBox(height: 20),
        if (_canUndo)
          OutlinedButton.icon(onPressed: _busy ? null : _undo,
              icon: const Icon(Icons.undo, size: 18), label: const Text('UNDO LAST IMPORT')),
        if (_log.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('IMPORT LOG (THIS DEVICE)', style: TextStyle(fontFamily: 'RobotoMono', fontSize: 10.5,
              letterSpacing: 1.5, color: t.silk)),
          const SizedBox(height: 6),
          for (final e in _log.take(20))
            Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(
                '${(e['at'] ?? '').toString().replaceFirst('T', ' ').split('.').first}  '
                '${(e['action'] ?? '').toString().toUpperCase()}  ${e['filename'] ?? ''}  '
                'by ${e['by'] ?? '?'}  -> ${e['rows_after'] ?? '?'} rows'
                '${e['sha256'] != null ? '  sha256 ${e['sha256'].toString().substring(0, 12)}...' : ''}',
                style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 10.5))),
        ],
      ]),
    );
  }

  String _sourceLabel(String s) => switch (s) {
        'server' => 'synced from server',
        'server_cache' => 'last server sync',
        'device_import' => 'imported on this device',
        _ => 'bundled with the app',
      };

  Widget _box(BuildContext context, String text, Color c) => Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(border: Border.all(color: c), borderRadius: BorderRadius.circular(3)),
        child: Text(text, style: TextStyle(color: c, fontSize: 13)),
      );

  List<Widget> _previewWidgets(BuildContext context, ImportPreview p) {
    final t = context.tokens;
    final b = Theme.of(context).brightness;
    final oc = p.originCounts;
    final rejectedRows = p.errors.map((e) => e.row).toSet().length;
    Widget row(String k, String v) => Padding(padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 150, child: Text(k, style: TextStyle(fontSize: 12, color: t.ink2))),
          Expanded(child: Text(v, style: const TextStyle(fontSize: 12.5))),
        ]));
    final flipsBlocking = p.originFlips.isNotEmpty && !_flipsAcknowledged;
    return [
      const SizedBox(height: 16),
      Text('PREVIEW - ${p.filename}', style: TextStyle(fontFamily: 'RobotoMono', fontSize: 10.5,
          letterSpacing: 1.5, color: t.silk)),
      const SizedBox(height: 6),
      row('Valid rows', '${p.validRows.length}'),
      row('New / updated / same', '${p.newCount} / ${p.updatedCount} / ${p.unchangedCount}'),
      row('Origin', 'Chinese ${oc['YES']} - non-Chinese ${oc['NO']} - unknown ${oc['UNKNOWN']}'),
      row('Rejected rows', '$rejectedRows'),
      if (p.duplicates.isNotEmpty) row('Duplicate ids', '${p.duplicates.length} (first kept)'),
      row('Not in file', '${p.missingFromFile} current component(s)'),
      row('Columns used', p.mapping.entries.map((e) => '${e.key} -> ${e.value}').join('\n')),
      if (p.unmapped.isNotEmpty) row('Folded into remarks', p.unmapped.join(', ')),
      for (final n in p.notes) _box(context, n, DcovColors.forBanner('YELLOW', b)),
      if (p.originFlips.isNotEmpty) ...[
        _box(context,
            '${p.originFlips.length} component(s) CHANGE ORIGIN in this file - the highest-risk edit '
            '(a RED part silently turning GREEN is exactly what a tampered file would do):\n'
            '${p.originFlips.take(10).join('\n')}${p.originFlips.length > 10 ? '\n...' : ''}',
            DcovColors.forBanner('RED', b)),
        CheckboxListTile(
          value: _flipsAcknowledged,
          onChanged: (v) => setState(() => _flipsAcknowledged = v ?? false),
          title: const Text('I have checked each origin change against its source document'),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
        ),
      ],
      if (p.errors.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text('Rejected (first 30):', style: TextStyle(fontSize: 12, color: t.ink2)),
        for (final e in p.errors.take(30))
          Text('  $e', style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 10.5)),
      ],
      if (p.warnings.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text('Warnings: ${p.warnings.length} (first 10)', style: TextStyle(fontSize: 12, color: t.ink2)),
        for (final w in p.warnings.take(10))
          Text('  $w', style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 10.5)),
      ],
      const SizedBox(height: 12),
      SegmentedButton<bool>(
        segments: const [
          ButtonSegment(value: false, label: Text('MERGE'), icon: Icon(Icons.merge_type)),
          ButtonSegment(value: true, label: Text('REPLACE'), icon: Icon(Icons.swap_horiz)),
        ],
        selected: {_replace},
        onSelectionChanged: (s) => setState(() => _replace = s.first),
      ),
      const SizedBox(height: 6),
      Text(_replace
          ? 'REPLACE: the catalogue becomes exactly this file'
            '${p.missingFromFile > 0 ? ' - ${p.missingFromFile} current component(s) will be removed' : ''}.'
          : 'MERGE: new components are added, matching ids are updated, everything else is kept.',
          style: TextStyle(fontSize: 12, color: t.ink2)),
      const SizedBox(height: 8),
      FilledButton(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        onPressed: (_busy || !p.canImport || flipsBlocking) ? null : _apply,
        child: Text(flipsBlocking ? 'CONFIRM THE ORIGIN CHANGES FIRST' : 'APPLY IMPORT'),
      ),
    ];
  }
}
