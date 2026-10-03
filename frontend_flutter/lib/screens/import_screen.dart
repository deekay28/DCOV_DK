import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../services/api_client.dart';
import '../services/app_state.dart';
import '../theme/dcov_theme.dart';

// database:import is Administrator/Database Manager only on the backend
// (backend/app/core/security.py's PERMISSIONS matrix) - mirrored here.
// The backend enforces this regardless; this just avoids showing an
// Inspector or Viewer a screen that would only ever 403.
bool _canImport(AppState app) =>
    const {'administrator', 'database_manager'}.contains(app.session?.role);

/// The import wizard. Deliberately built slowly and reviewed carefully
/// rather than shipped fast like the previous three screens - see
/// docs/ROADMAP.md's note on why: a careless preview UI here would
/// undermine the backend's entire stage/commit/rollback safety design.
/// The one rule this screen is built around: nothing is committed without
/// the operator having scrolled past every warning, and an origin-verdict
/// flip (a component silently going from cleared to Chinese-origin or back)
/// is never something a fast tap can miss.
class ImportScreen extends StatefulWidget {
  final AppState app;
  const ImportScreen({super.key, required this.app});
  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

enum _Stage { pick, uploading, preview, committing, done }

class _ImportScreenState extends State<ImportScreen> {
  _Stage _stage = _Stage.pick;
  String? _error;
  Map<String, dynamic>? _preview;
  Map<String, dynamic>? _summary;
  bool _applyNew = true;
  bool _applyUpdates = true;
  bool _softDeleteMissing = false;
  bool _reviewed = false;

  Future<void> _pickAndStage() async {
    setState(() { _error = null; });
    // Confirmed via a real `flutter analyze` run (not assumed): this
    // resolved file_picker version exposes pickFiles as an INSTANCE member
    // via the FilePicker.platform singleton, not a static method - the
    // opposite of what I'd guessed when writing this against pub.dev docs
    // alone. Left this note rather than deleting it, as a record of why
    // the call looks like this.
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['xlsx', 'xlsm', 'csv', 'tsv', 'json', 'sql'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return; // user cancelled
    final picked = result.files.first;
    final bytes = picked.bytes;
    if (bytes == null) {
      setState(() => _error =
          'Could not read the file\'s contents (no bytes returned by the '
          'picker). This can happen on some platforms without withData: '
          'true honoured - try a different file location.');
      return;
    }
    await _stage_(bytes, picked.name);
  }

  Future<void> _stage_(Uint8List bytes, String filename) async {
    setState(() { _stage = _Stage.uploading; _error = null; });
    try {
      final preview = await widget.app.api.stageImport(bytes, filename);
      setState(() { _preview = preview; _stage = _Stage.preview; _reviewed = false; });
    } on ApiException catch (e) {
      setState(() { _stage = _Stage.pick; _error = e.message; });
    } catch (e) {
      setState(() { _stage = _Stage.pick; _error = 'Could not reach the server: $e'; });
    }
  }

  Future<void> _commit() async {
    setState(() { _stage = _Stage.committing; _error = null; });
    try {
      final summary = await widget.app.api.commitImport(
        _preview!['batch_id'] as String,
        applyNew: _applyNew, applyUpdates: _applyUpdates,
        softDeleteMissing: _softDeleteMissing,
      );
      setState(() { _summary = summary; _stage = _Stage.done; });
      widget.app.pushNotification(level: 'info', title: 'Import committed',
          body: '${_preview!['filename']}: ${summary['rows_new']} new, '
              '${summary['rows_updated']} updated, ${summary['rows_deleted']} deleted.',
          route: 'import');
    } on ApiException catch (e) {
      setState(() { _stage = _Stage.preview; _error = 'Commit failed: ${e.message}'; });
      widget.app.pushNotification(level: 'error', title: 'Import failed',
          body: '${_preview!['filename']}: ${e.message}', route: 'import');
    } catch (e) {
      setState(() { _stage = _Stage.preview; _error = 'Could not reach the server: $e'; });
    }
  }

  void _startOver() {
    setState(() {
      _stage = _Stage.pick; _preview = null; _summary = null;
      _error = null; _reviewed = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final app = widget.app;
    return Scaffold(
      appBar: AppBar(title: const Text('IMPORT DATABASE'), actions: [
        if (app.isLoggedIn && _canImport(app))
          IconButton(
            icon: const Icon(Icons.history, size: 20),
            tooltip: 'Import history',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ImportHistoryScreen(app: app))),
          ),
      ]),
      body: !app.isLoggedIn || !_canImport(app)
          ? _notice(t, !app.isLoggedIn ? 'Sign in to import data'
                  : 'Not permitted',
              !app.isLoggedIn
                  ? 'Importing requires an Administrator or Database Manager session.'
                  : 'Your role (${app.session?.role}) cannot import data. '
                    'Administrator or Database Manager only.')
          : switch (_stage) {
              _Stage.pick => _pickBody(context, t),
              _Stage.uploading => const Center(child: _Busy(label: 'Uploading and staging...')),
              _Stage.preview => _previewBody(context, t),
              _Stage.committing => const Center(child: _Busy(label: 'Committing...')),
              _Stage.done => _doneBody(context, t),
            },
    );
  }

  Widget _pickBody(BuildContext context, DcovTokens t) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.upload_file_outlined, size: 44, color: t.silk),
            const SizedBox(height: 16),
            const Text('Import a component database',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text('.xlsx, .xlsm, .csv, .tsv, .json, or .sql (INSERT statements only).\n'
                'Nothing is written until you review the preview and commit.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: t.ink2, height: 1.5)),
            const SizedBox(height: 20),
            if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 14),
                child: Container(padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                      border: Border.all(color: DcovColors.forBanner('RED', Theme.of(context).brightness)),
                      borderRadius: BorderRadius.circular(3)),
                  child: Text(_error!, style: TextStyle(fontSize: 12.5,
                      color: DcovColors.forBanner('RED', Theme.of(context).brightness))))),
            FilledButton.icon(onPressed: _pickAndStage,
                icon: const Icon(Icons.folder_open, size: 18),
                label: const Text('CHOOSE FILE')),
          ]),
        ),
      );

  Widget _previewBody(BuildContext context, DcovTokens t) {
    final p = _preview!;
    final warnings = (p['warnings'] as List).cast<String>();
    final flipWarnings = warnings.where((w) => w.contains('origin verdict')).toList();
    final otherWarnings = warnings.where((w) => !w.contains('origin verdict')).toList();
    final sampleNew = (p['sample_new'] as List).cast<Map<String, dynamic>>();
    final sampleUpdated = (p['sample_updated'] as List).cast<Map<String, dynamic>>();
    final validationErrors = (p['validation_errors'] as List).cast<Map<String, dynamic>>();
    final mapping = (p['column_mapping'] as Map).cast<String, dynamic>();
    final unmapped = (p['unmapped_columns'] as List).cast<String>();

    return ListView(padding: const EdgeInsets.all(16), children: [
      Text(p['filename'] as String, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
      Text('${p['file_format']} \u00b7 batch ${p['batch_id']}',
          style: TextStyle(fontFamily: 'RobotoMono', fontSize: 11, color: t.ink2)),
      const SizedBox(height: 14),

      // ---- Origin-flip warnings: unmissable, first thing after the title.
      if (flipWarnings.isNotEmpty)
        Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: DcovColors.forBanner('RED', Theme.of(context).brightness).withValues(alpha: 0.12),
            border: Border.all(color: DcovColors.forBanner('RED', Theme.of(context).brightness), width: 1.5),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.warning_amber_rounded, size: 18,
                  color: DcovColors.forBanner('RED', Theme.of(context).brightness)),
              const SizedBox(width: 8),
              Text('ORIGIN VERDICT CHANGES', style: TextStyle(fontFamily: 'RobotoMono',
                  fontSize: 11.5, letterSpacing: 1, fontWeight: FontWeight.w700,
                  color: DcovColors.forBanner('RED', Theme.of(context).brightness))),
            ]),
            const SizedBox(height: 8),
            for (final w in flipWarnings)
              Padding(padding: const EdgeInsets.only(top: 4),
                  child: Text(w, style: const TextStyle(fontSize: 12.5, height: 1.4))),
          ]),
        ),

      // ---- Row counts.
      Wrap(spacing: 8, runSpacing: 8, children: [
        _countChip(context, '${p['rows_new']}', 'NEW', 'GREEN'),
        _countChip(context, '${p['rows_updated']}', 'UPDATED', 'YELLOW'),
        _countChip(context, '${p['rows_unchanged']}', 'UNCHANGED', null),
        _countChip(context, '${p['rows_duplicate']}', 'DUPLICATE', null),
        _countChip(context, '${p['rows_invalid']}', 'INVALID', 'RED'),
        _countChip(context, '${p['rows_missing_in_file']}', 'MISSING FROM FILE', null),
      ]),

      if (otherWarnings.isNotEmpty)
        _section(t, 'OTHER WARNINGS', Column(crossAxisAlignment: CrossAxisAlignment.start,
            children: [for (final w in otherWarnings)
              Padding(padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Text(w, style: TextStyle(fontSize: 12.5, color: t.ink2)))])),

      _section(t, 'COLUMN MAPPING', Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final e in mapping.entries)
          Padding(padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text('${e.key}  \u2192  ${e.value}',
                  style: const TextStyle(fontSize: 12, fontFamily: 'RobotoMono'))),
        if (unmapped.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text('Unmapped (folded into remarks): ${unmapped.join(', ')}',
              style: TextStyle(fontSize: 11.5, color: t.ink2, fontStyle: FontStyle.italic)),
        ],
      ])),

      if (sampleUpdated.isNotEmpty)
        _section(t, 'CHANGED ROWS (sample of ${sampleUpdated.length})',
            Column(children: [for (final row in sampleUpdated) _diffCard(context, t, row)])),

      if (sampleNew.isNotEmpty)
        _section(t, 'NEW ROWS (sample of ${sampleNew.length})',
            Column(children: [for (final row in sampleNew) _newRowLine(context, t, row)])),

      if (validationErrors.isNotEmpty)
        _section(t, 'ROWS THAT WILL BE SKIPPED (${validationErrors.length})',
            Column(children: [for (final e in validationErrors.take(20))
              Padding(padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Text('Row ${e['row_number']}: ${e['field']} - ${e['message']}',
                      style: TextStyle(fontSize: 11.5, color: t.ink2)))])),

      _section(t, 'APPLY', Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        CheckboxListTile(dense: true, contentPadding: EdgeInsets.zero,
            title: const Text('Apply new rows', style: TextStyle(fontSize: 13)),
            value: _applyNew, onChanged: (v) => setState(() => _applyNew = v ?? true)),
        CheckboxListTile(dense: true, contentPadding: EdgeInsets.zero,
            title: const Text('Apply updates to existing rows', style: TextStyle(fontSize: 13)),
            value: _applyUpdates, onChanged: (v) => setState(() => _applyUpdates = v ?? true)),
        CheckboxListTile(dense: true, contentPadding: EdgeInsets.zero,
            title: Text('Soft-delete ${p['rows_missing_in_file']} row(s) absent from this file',
                style: TextStyle(fontSize: 13,
                    color: _softDeleteMissing ? DcovColors.forBanner('RED', Theme.of(context).brightness) : null)),
            subtitle: const Text(
                'Only enable this if the file is the complete, authoritative catalogue - '
                'a partial export will otherwise delete everything not included in it.',
                style: TextStyle(fontSize: 11)),
            value: _softDeleteMissing, onChanged: (v) => setState(() => _softDeleteMissing = v ?? false)),
      ])),

      const SizedBox(height: 8),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        value: _reviewed,
        onChanged: (v) => setState(() => _reviewed = v ?? false),
        title: Text(
            flipWarnings.isNotEmpty
                ? 'I have reviewed the changes above, including the origin verdict changes.'
                : 'I have reviewed the changes above.',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      ),
      if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 10),
          child: Text(_error!, style: TextStyle(fontSize: 12.5,
              color: DcovColors.forBanner('RED', Theme.of(context).brightness)))),
      Row(children: [
        Expanded(child: OutlinedButton(onPressed: _startOver, child: const Text('CANCEL'))),
        const SizedBox(width: 10),
        Expanded(child: FilledButton(
          onPressed: _reviewed && (_applyNew || _applyUpdates) ? _commit : null,
          child: const Text('COMMIT'),
        )),
      ]),
      const SizedBox(height: 20),
    ]);
  }

  Widget _diffCard(BuildContext context, DcovTokens t, Map<String, dynamic> row) {
    final changed = (row['changed'] as Map).cast<String, dynamic>();
    final flipsOrigin = changed.containsKey('is_chinese');
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: flipsOrigin
          ? DcovColors.forBanner('RED', Theme.of(context).brightness).withValues(alpha: 0.08)
          : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(row['component_name'] as String? ?? row['component_id'] as String,
              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          for (final e in changed.entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: RichText(text: TextSpan(
                style: TextStyle(fontSize: 11.5, fontFamily: 'RobotoMono',
                    color: e.key == 'is_chinese' ? DcovColors.forBanner('RED', Theme.of(context).brightness) : t.ink2),
                children: [
                  TextSpan(text: '${e.key}: ', style: const TextStyle(fontWeight: FontWeight.w600)),
                  TextSpan(text: '${(e.value as Map)['from']}'),
                  const TextSpan(text: '  \u2192  '),
                  TextSpan(text: '${(e.value as Map)['to']}',
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                ],
              )),
            ),
        ]),
      ),
    );
  }

  Widget _newRowLine(BuildContext context, DcovTokens t, Map<String, dynamic> row) {
    final banner = row['is_chinese'] == 'YES' ? 'RED'
        : row['is_chinese'] == 'NO' ? 'GREEN' : 'YELLOW';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Container(width: 4, height: 26, color: DcovColors.forBanner(banner, Theme.of(context).brightness)),
        const SizedBox(width: 10),
        Expanded(child: Text(row['component_name'] as String? ?? '',
            style: const TextStyle(fontSize: 12.5), overflow: TextOverflow.ellipsis)),
        Text(row['country_of_origin'] as String? ?? '\u2014',
            style: TextStyle(fontSize: 11.5, color: t.ink2)),
      ]),
    );
  }

  Widget _countChip(BuildContext context, String count, String label, String? banner) {
    final color = banner == null ? Theme.of(context).colorScheme.outline
        : DcovColors.forBanner(banner, Theme.of(context).brightness);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(border: Border.all(color: color), borderRadius: BorderRadius.circular(3)),
      child: Text('$count $label', style: TextStyle(fontSize: 11, fontFamily: 'RobotoMono', color: color)),
    );
  }

  Widget _section(DcovTokens t, String title, Widget child) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(fontFamily: 'RobotoMono', fontSize: 10,
                letterSpacing: 1.4, color: t.silk, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            child,
          ]),
        ),
      );

  Widget _doneBody(BuildContext context, DcovTokens t) {
    final s = _summary!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.check_circle_outline, size: 44,
              color: DcovColors.forBanner('GREEN', Theme.of(context).brightness)),
          const SizedBox(height: 14),
          const Text('Import committed', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text('${s['rows_new']} new \u00b7 ${s['rows_updated']} updated \u00b7 '
              '${s['rows_deleted']} deleted \u00b7 ${s['rows_unchanged']} unchanged',
              style: TextStyle(fontSize: 12.5, color: t.ink2)),
          const SizedBox(height: 20),
          FilledButton(onPressed: _startOver, child: const Text('IMPORT ANOTHER FILE')),
        ]),
      ),
    );
  }

  Widget _notice(DcovTokens t, String title, String body) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.lock_outline, size: 40, color: t.silk),
            const SizedBox(height: 14),
            Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(body, textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: t.ink2, height: 1.5)),
          ]),
        ),
      );
}

class _Busy extends StatelessWidget {
  final String label;
  const _Busy({required this.label});
  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 14),
        Text(label, style: const TextStyle(fontSize: 13)),
      ]);
}

// --------------------------------------------------------------------- //
/// Every past import batch, and a rollback action on committed ones.
/// Rollback replays the batch's revision snapshots in reverse - rows it
/// created are removed, rows it modified are restored to their pre-import
/// state. See ADMIN_MANUAL.md's import wizard section for the same
/// operation from the API side.
class ImportHistoryScreen extends StatefulWidget {
  final AppState app;
  const ImportHistoryScreen({super.key, required this.app});
  @override
  State<ImportHistoryScreen> createState() => _ImportHistoryScreenState();
}

class _ImportHistoryScreenState extends State<ImportHistoryScreen> {
  List<Map<String, dynamic>>? _batches;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _batches = null; _error = null; });
    try {
      final b = await widget.app.api.importHistory();
      if (mounted) setState(() => _batches = b);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not reach the server: $e');
    }
  }

  Future<void> _rollback(Map<String, dynamic> batch) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => _ReasonDialog(
        title: 'Roll back this import?',
        body: 'This undoes ${batch['filename']} (batch ${(batch['batch_id'] as String).substring(0, 8)}...): '
            '${batch['rows_new']} added row(s) will be removed, '
            '${batch['rows_updated']} updated row(s) will be restored to how '
            'they were before this import. This cannot be undone by rolling '
            'back again - re-importing the original file is how you would '
            'reverse a rollback.',
        confirmLabel: 'ROLL BACK',
      ),
    );
    if (reason == null || reason.trim().isEmpty) return;
    try {
      await widget.app.api.rollbackImport(batch['batch_id'] as String, reason.trim());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Import rolled back.')));
      }
      widget.app.pushNotification(level: 'warning', title: 'Import rolled back',
          body: '${batch['filename']}: $reason', route: 'import');
      _load();
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Rollback failed: ${e.message}')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Scaffold(
      appBar: AppBar(title: const Text('IMPORT HISTORY'), actions: [
        IconButton(icon: const Icon(Icons.refresh, size: 20), onPressed: _load),
      ]),
      body: _error != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24),
              child: Text(_error!, style: TextStyle(color: t.ink2))))
          : _batches == null
              ? const Center(child: CircularProgressIndicator())
              : _batches!.isEmpty
                  ? Center(child: Text('No imports yet.', style: TextStyle(color: t.ink2)))
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: _batches!.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, i) => _batchCard(context, t, _batches![i]),
                    ),
    );
  }

  Widget _batchCard(BuildContext context, DcovTokens t, Map<String, dynamic> b) {
    final status = b['status'] as String;
    final banner = switch (status) {
      'committed' => 'GREEN', 'rolled_back' => 'YELLOW',
      'failed' => 'RED', _ => 'GREY', // staged
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(width: 4, height: 30, color: DcovColors.forBanner(banner, Theme.of(context).brightness)),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(b['filename'] as String? ?? '', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
              Text('${b['format']} \u00b7 ${status.toUpperCase()} \u00b7 ${b['created_at'] ?? ''}',
                  style: TextStyle(fontSize: 11, color: t.ink2)),
            ])),
          ]),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            _tag(t, '${b['rows_new'] ?? 0} new'),
            _tag(t, '${b['rows_updated'] ?? 0} updated'),
            _tag(t, '${b['rows_deleted'] ?? 0} deleted'),
            if ((b['rows_invalid'] as int? ?? 0) > 0) _tag(t, '${b['rows_invalid']} invalid'),
          ]),
          if (status == 'committed') ...[
            const SizedBox(height: 10),
            Align(alignment: Alignment.centerRight,
              child: OutlinedButton(onPressed: () => _rollback(b),
                  child: const Text('ROLL BACK', style: TextStyle(fontSize: 12)))),
          ],
        ]),
      ),
    );
  }

  Widget _tag(DcovTokens t, String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(border: Border.all(color: t.rule), borderRadius: BorderRadius.circular(2)),
        child: Text(text, style: TextStyle(fontSize: 10.5, fontFamily: 'RobotoMono', color: t.ink2)),
      );
}

/// Shared reason-prompt dialog - a rollback (here) and account
/// deactivation-with-reason-style actions elsewhere in the admin screens
/// both want "confirm, with a mandatory written reason", so this is kept
/// generic rather than duplicated.
class _ReasonDialog extends StatefulWidget {
  final String title;
  final String body;
  final String confirmLabel;
  const _ReasonDialog({required this.title, required this.body, required this.confirmLabel});
  @override
  State<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<_ReasonDialog> {
  final _reason = TextEditingController();

  @override
  void initState() {
    super.initState();
    // TextEditingController is itself a Listenable - this is what makes the
    // confirm button's enabled state actually update as the user types,
    // rather than being frozen at whatever it evaluated to on first build.
    _reason.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.body, style: const TextStyle(fontSize: 12.5, height: 1.4)),
          const SizedBox(height: 14),
          TextField(controller: _reason, autofocus: true, maxLines: 2,
              decoration: const InputDecoration(labelText: 'Reason (required, goes to the audit log)')),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('CANCEL')),
        FilledButton(
          onPressed: _reason.text.trim().length >= 3
              ? () => Navigator.pop(context, _reason.text.trim())
              : null,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
