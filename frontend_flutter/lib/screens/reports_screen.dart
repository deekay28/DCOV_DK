import 'dart:io' show File;
import 'dart:typed_data' show Uint8List;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../services/api_client.dart';
import '../services/app_state.dart';
import '../theme/dcov_theme.dart';

class _ReportDef {
  final String key;
  final String title;
  final String description;
  final bool usesDateRange;
  final bool adminOnly;
  const _ReportDef(this.key, this.title, this.description,
      {this.usesDateRange = false, this.adminOnly = false});
}

// Mirrors backend/app/services/reports.py's REPORTS dict and
// docs/ADMIN_MANUAL.md's report table - six report types, three formats
// each. Keep this list in sync if a report is added or renamed server-side;
// nothing here re-derives it from the API, so a drift would show up as a
// report key the backend rejects rather than a compile error.
const _reportDefs = [
  _ReportDef('inspection', 'Inspection Report',
      'Scan log for a date range, or a specific inspection.',
      usesDateRange: true),
  _ReportDef('chinese_components', 'Chinese-Origin Component Report',
      'Every Chinese-origin record in the catalogue, CRITICAL subsystems first.'),
  _ReportDef('unknown_origin', 'Unestablished-Origin Component Report',
      'Every record with no established origin - the needs-verification queue.'),
  _ReportDef('statistics', 'Component Statistics',
      'Catalogue and scan-activity counts.', usesDateRange: true),
  _ReportDef('monthly', 'Monthly Inspection Summary',
      'Scans, findings, and distinct inspectors per calendar month.',
      usesDateRange: true),
  _ReportDef('audit', 'Audit Trail',
      'The audit log itself, plus a hash-chain integrity check.',
      usesDateRange: true, adminOnly: true),
];

class ReportsScreen extends StatelessWidget {
  final AppState app;
  const ReportsScreen({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        final isAdmin = app.session?.role == 'administrator';
        final visible = _reportDefs.where((r) => !r.adminOnly || isAdmin).toList();
        return Scaffold(
          appBar: AppBar(title: const Text('REPORTS')),
          body: !app.isLoggedIn
              ? _signedOutNotice(t)
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: visible.length,
                  itemBuilder: (context, i) => _ReportCard(app: app, def: visible[i]),
                ),
        );
      },
    );
  }

  Widget _signedOutNotice(DcovTokens t) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.lock_outline, size: 40, color: t.silk),
            const SizedBox(height: 14),
            Text('Sign in to generate reports',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(
              'Reports are generated from the live server catalogue and scan '
              'history - they need an active session, even offline mode '
              'catalogue browsing does not provide enough for a report to mean '
              'anything.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: t.ink2, height: 1.5),
            ),
          ]),
        ),
      );
}

class _ReportCard extends StatefulWidget {
  final AppState app;
  final _ReportDef def;
  const _ReportCard({required this.app, required this.def});
  @override
  State<_ReportCard> createState() => _ReportCardState();
}

class _ReportCardState extends State<_ReportCard> {
  bool _busy = false;

  Future<void> _generate(String fmt, int days) async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final bytes = await widget.app.api
          .report(widget.def.key, fmt: fmt, days: days);
      await _saveAndShare(widget.def.key, fmt, bytes);
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(
          e.statusCode == 403
              ? 'Not permitted: ${e.message}'
              : 'Report failed: ${e.message}')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not reach the server: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveAndShare(String key, String fmt, Uint8List bytes) async {
    final stamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    final filename = 'DCOV_${key}_$stamp.$fmt';
    // share_plus's current API: SharePlus.instance.share(ShareParams(...)).
    // The older static Share.shareXFiles(...) is deprecated - deliberately
    // not used here even though it would still compile.
    if (kIsWeb) {
      await SharePlus.instance.share(ShareParams(
        files: [XFile.fromData(bytes, name: filename, mimeType: _mime(fmt))],
        subject: filename,
      ));
      return;
    }
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$filename');
    await file.writeAsBytes(bytes, flush: true);
    await SharePlus.instance.share(ShareParams(
      files: [XFile(file.path, mimeType: _mime(fmt))],
      subject: filename,
    ));
  }

  String _mime(String fmt) => switch (fmt) {
        'pdf' => 'application/pdf',
        'xlsx' => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        _ => 'text/csv',
      };

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(widget.def.title,
                style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700))),
            if (widget.def.adminOnly)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(border: Border.all(color: t.silk),
                    borderRadius: BorderRadius.circular(2)),
                child: Text('ADMIN', style: TextStyle(fontSize: 9, color: t.silk,
                    fontFamily: 'RobotoMono', letterSpacing: 1)),
              ),
          ]),
          const SizedBox(height: 6),
          Text(widget.def.description, style: TextStyle(fontSize: 12.5, color: t.ink2, height: 1.4)),
          const SizedBox(height: 12),
          _busy
              ? const Center(child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: SizedBox(height: 20, width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))))
              : Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final fmt in const ['pdf', 'xlsx', 'csv'])
                    OutlinedButton(
                      onPressed: () => widget.def.usesDateRange
                          ? _pickDaysThenGenerate(fmt)
                          : _generate(fmt, 30),
                      child: Text(fmt.toUpperCase(),
                          style: const TextStyle(fontSize: 11.5, letterSpacing: 1)),
                    ),
                ]),
        ]),
      ),
    );
  }

  Future<void> _pickDaysThenGenerate(String fmt) async {
    final days = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('DATE RANGE', style: TextStyle(fontFamily: 'RobotoMono', fontSize: 10.5,
                  letterSpacing: 2, color: context.tokens.silk, fontWeight: FontWeight.w600)),
              const SizedBox(height: 14),
              for (final opt in const [[7, 'Last 7 days'], [30, 'Last 30 days'],
                                        [90, 'Last 90 days'], [365, 'Last year']])
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(opt[1] as String),
                  onTap: () => Navigator.pop(context, opt[0] as int),
                ),
            ],
          ),
        ),
      ),
    );
    if (days != null) await _generate(fmt, days);
  }
}
