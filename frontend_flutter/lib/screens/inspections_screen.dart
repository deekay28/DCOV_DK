import 'package:flutter/material.dart';
import '../services/api_client.dart';
import '../services/app_state.dart';
import '../theme/dcov_theme.dart';

// inspection:create and inspection:sign are Administrator/Inspector only on
// the backend (see backend/app/core/security.py's PERMISSIONS matrix) -
// mirrored here so a Viewer sees a read-only list rather than buttons that
// would just 403. The backend enforces this regardless; this is UI
// courtesy, not the actual security boundary.
bool _canManage(AppState app) =>
    const {'administrator', 'inspector'}.contains(app.session?.role);

class InspectionsScreen extends StatefulWidget {
  final AppState app;
  const InspectionsScreen({super.key, required this.app});
  @override
  State<InspectionsScreen> createState() => _InspectionsScreenState();
}

class _InspectionsScreenState extends State<InspectionsScreen> {
  List<Map<String, dynamic>>? _items;
  String? _error;
  bool _mineOnly = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _items = null; _error = null; });
    try {
      final items = await widget.app.api.listInspections(mine: _mineOnly);
      if (mounted) setState(() => _items = items);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not reach the server: $e');
    }
  }

  Future<void> _createNew() async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CreateInspectionSheet(app: widget.app),
    );
    if (result == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final app = widget.app;
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('INSPECTIONS'), actions: [
          IconButton(icon: const Icon(Icons.refresh, size: 20), onPressed: _load),
        ]),
        floatingActionButton: !app.isLoggedIn || !_canManage(app)
            ? null
            : FloatingActionButton.extended(
                onPressed: _createNew,
                icon: const Icon(Icons.add, size: 20),
                label: const Text('NEW INSPECTION'),
              ),
        body: !app.isLoggedIn
            ? _notice(t, 'Sign in to view inspections',
                'Inspections and their scan history live on the server.')
            : Column(children: [
                if (app.activeInspectionId != null)
                  _activeBanner(context, app),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Row(children: [
                    Text('SHOW', style: TextStyle(fontFamily: 'RobotoMono', fontSize: 10,
                        letterSpacing: 1.5, color: t.silk)),
                    const SizedBox(width: 10),
                    ChoiceChip(label: const Text('MINE'), selected: _mineOnly,
                        onSelected: (v) { setState(() => _mineOnly = true); _load(); }),
                    const SizedBox(width: 6),
                    ChoiceChip(label: const Text('ALL OPEN'), selected: !_mineOnly,
                        onSelected: (v) { setState(() => _mineOnly = false); _load(); }),
                  ]),
                ),
                Expanded(child: _body(t)),
              ]),
      ),
    );
  }

  Widget _activeBanner(BuildContext context, AppState app) => Container(
        width: double.infinity,
        color: DcovColors.forBanner('GREEN', Theme.of(context).brightness).withValues(alpha: 0.12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(children: [
          Icon(Icons.radio_button_checked, size: 15,
              color: DcovColors.forBanner('GREEN', Theme.of(context).brightness)),
          const SizedBox(width: 8),
          Expanded(child: Text('Active: ${app.activeInspectionNumber} - new scans are tagged to it',
              style: const TextStyle(fontSize: 12.5))),
          TextButton(
              // Same fix as the VERIFY/CLEAR button crashes - see the
              // identical banner widget in verify_screen.dart for the
              // full explanation. Applied pre-emptively here rather than
              // waiting for this specific button to crash on tap.
              style: TextButton.styleFrom(minimumSize: const Size(50, 32)),
              onPressed: app.clearActiveInspection,
              child: const Text('STOP', style: TextStyle(fontSize: 11))),
        ]),
      );

  Widget _body(DcovTokens t) {
    if (_error != null) {
      return _notice(t, 'Could not load inspections', _error!);
    }
    if (_items == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items!.isEmpty) {
      return _notice(t, 'No inspections yet',
          _mineOnly ? 'Inspections you create or are assigned will appear here.'
                    : 'No open inspections across the team right now.');
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _items!.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final insp = _items![i];
        final status = insp['status'] as String? ?? 'open';
        final banner = status == 'escalated' ? 'RED' : status == 'completed' ? 'GREEN' : 'GREY';
        final subtitleParts = [insp['platform'], insp['serial_number']]
            .where((s) => (s as String?)?.isNotEmpty == true)
            .join(' \u00b7 ');
        final subtitle = subtitleParts.isEmpty
            ? status.toUpperCase()
            : '$subtitleParts \u00b7 ${status.toUpperCase()}';
        return Card(
          child: ListTile(
            leading: Container(width: 4, height: 40,
                color: DcovColors.forBanner(banner, Theme.of(context).brightness)),
            title: Text(insp['inspection_number'] as String? ?? '',
                style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 13, fontWeight: FontWeight.w700)),
            subtitle: Text(subtitle, style: TextStyle(fontSize: 12, color: t.ink2)),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => InspectionDetailScreen(app: widget.app, id: insp['id'] as String))),
          ),
        );
      },
    );
  }

  Widget _notice(DcovTokens t, String title, String body) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.assignment_outlined, size: 40, color: t.silk),
            const SizedBox(height: 14),
            Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(body, textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: t.ink2, height: 1.5)),
          ]),
        ),
      );
}

// --------------------------------------------------------------------- //
class _CreateInspectionSheet extends StatefulWidget {
  final AppState app;
  const _CreateInspectionSheet({required this.app});
  @override
  State<_CreateInspectionSheet> createState() => _CreateInspectionSheetState();
}

class _CreateInspectionSheetState extends State<_CreateInspectionSheet> {
  final _title = TextEditingController();
  final _platform = TextEditingController();
  final _serial = TextEditingController();
  final _location = TextEditingController();
  final _remarks = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_title, _platform, _serial, _location, _remarks]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() { _busy = true; _error = null; });
    try {
      final insp = await widget.app.startInspection(
        title: _title.text.trim(), platform: _platform.text.trim(),
        serialNumber: _serial.text.trim(), location: _location.text.trim(),
        remarks: _remarks.text.trim(),
      );
      if (mounted) {
        Navigator.pop(context, true);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
            'Started ${insp['inspection_number']} - now your active inspection')));
      }
    } on ApiException catch (e) {
      setState(() { _busy = false; _error = e.message; });
    } catch (e) {
      setState(() { _busy = false; _error = 'Could not reach the server: $e'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('NEW INSPECTION', style: TextStyle(fontFamily: 'RobotoMono', fontSize: 10.5,
                letterSpacing: 2, color: t.silk, fontWeight: FontWeight.w600)),
            const SizedBox(height: 14),
            TextField(controller: _platform,
                decoration: const InputDecoration(labelText: 'Platform / drone type')),
            const SizedBox(height: 8),
            TextField(controller: _serial,
                decoration: const InputDecoration(labelText: 'Serial / tail number')),
            const SizedBox(height: 8),
            TextField(controller: _location,
                decoration: const InputDecoration(labelText: 'Location')),
            const SizedBox(height: 8),
            TextField(controller: _title,
                decoration: const InputDecoration(labelText: 'Title (optional)')),
            const SizedBox(height: 8),
            TextField(controller: _remarks, maxLines: 2,
                decoration: const InputDecoration(labelText: 'Remarks (optional)')),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 10),
                child: Text(_error!, style: TextStyle(fontSize: 12.5,
                    color: DcovColors.forBanner('RED', Theme.of(context).brightness)))),
            const SizedBox(height: 16),
            SizedBox(width: double.infinity, child: FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('START INSPECTION'),
            )),
          ],
        ),
      ),
    );
  }
}

// --------------------------------------------------------------------- //
class InspectionDetailScreen extends StatefulWidget {
  final AppState app;
  final String id;
  const InspectionDetailScreen({super.key, required this.app, required this.id});
  @override
  State<InspectionDetailScreen> createState() => _InspectionDetailScreenState();
}

class _InspectionDetailScreenState extends State<InspectionDetailScreen> {
  Map<String, dynamic>? _detail;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _detail = null; _error = null; });
    try {
      final d = await widget.app.api.getInspection(widget.id);
      if (mounted) setState(() => _detail = d);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not reach the server: $e');
    }
  }

  Future<void> _signOff() async {
    final insp = _detail!['inspection'] as Map<String, dynamic>;
    final tally = (_detail!['tally'] as Map).cast<String, dynamic>();
    final hasChinese = (tally['chinese'] as int? ?? 0) > 0;
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => _SignOffDialog(hasChinese: hasChinese),
    );
    if (result == null) return;
    try {
      await widget.app.api.signInspection(insp['id'] as String,
          verdict: result['verdict']!, remarks: result['remarks'] ?? '');
      if (widget.app.activeInspectionId == insp['id']) {
        widget.app.clearActiveInspection();
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Inspection signed.')));
      }
      _load();
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not sign: ${e.message}')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final app = widget.app;
    return Scaffold(
      appBar: AppBar(title: const Text('INSPECTION')),
      body: _error != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24),
              child: Text(_error!, style: TextStyle(color: t.ink2))))
          : _detail == null
              ? const Center(child: CircularProgressIndicator())
              : _content(context, t, app),
    );
  }

  Widget _content(BuildContext context, DcovTokens t, AppState app) {
    final insp = _detail!['inspection'] as Map<String, dynamic>;
    final tally = (_detail!['tally'] as Map).cast<String, dynamic>();
    final scans = (_detail!['scans'] as List).cast<Map<String, dynamic>>();
    final isOpen = insp['status'] == 'open';
    final isActive = app.activeInspectionId == insp['id'];

    final headerParts = [insp['platform'], insp['serial_number'], insp['location']]
        .where((s) => (s as String?)?.isNotEmpty == true)
        .join(' \u00b7 ');

    return ListView(padding: const EdgeInsets.all(16), children: [
      Text(insp['inspection_number'] as String,
          style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 18, fontWeight: FontWeight.w700)),
      const SizedBox(height: 4),
      Text(headerParts, style: TextStyle(fontSize: 13, color: t.ink2)),
      const SizedBox(height: 14),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final e in tally.entries)
          Chip(label: Text('${e.key}: ${e.value}',
              style: const TextStyle(fontSize: 11.5, fontFamily: 'RobotoMono'))),
      ]),
      const SizedBox(height: 16),
      if (isOpen && _canManage(app))
        Row(children: [
          if (!isActive)
            Expanded(child: OutlinedButton(
                onPressed: () => app.setActiveInspection(
                    insp['id'] as String, insp['inspection_number'] as String),
                child: const Text('SET AS ACTIVE'))),
          if (!isActive) const SizedBox(width: 8),
          Expanded(child: FilledButton(onPressed: _signOff, child: const Text('SIGN OFF'))),
        ]),
      if (!isOpen)
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(border: Border.all(color: t.rule), borderRadius: BorderRadius.circular(3)),
          child: Text(
              'Signed ${insp['signed_at'] ?? ''} - verdict: ${insp['verdict']}. '
              'Signed inspections are immutable.',
              style: TextStyle(fontSize: 12, color: t.ink2)),
        ),
      const SizedBox(height: 20),
      Text('SCANS (${scans.length})', style: TextStyle(fontFamily: 'RobotoMono', fontSize: 10.5,
          letterSpacing: 2, color: t.silk, fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      for (final s in scans)
        Card(
          margin: const EdgeInsets.only(bottom: 6),
          child: ListTile(
            dense: true,
            leading: Container(width: 4, height: 32, color: DcovColors.forBanner(
                s['result'] == 'chinese' ? 'RED'
                  : s['result'] == 'non_chinese' ? 'GREEN'
                  : s['result'] == 'unknown_origin' ? 'YELLOW' : 'GREY',
                Theme.of(context).brightness)),
            title: Text(s['raw_input'] as String? ?? '',
                style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 12.5)),
            subtitle: Text(
                '${s['result']}${(s['criticality'] as String?)?.isNotEmpty == true ? ' \u00b7 ${s['criticality']}' : ''}',
                style: TextStyle(fontSize: 11, color: t.ink2)),
          ),
        ),
    ]);
  }
}

class _SignOffDialog extends StatefulWidget {
  final bool hasChinese;
  const _SignOffDialog({required this.hasChinese});
  @override
  State<_SignOffDialog> createState() => _SignOffDialogState();
}

class _SignOffDialogState extends State<_SignOffDialog> {
  late String _verdict = widget.hasChinese ? 'chinese_found' : 'clear';
  final _remarks = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Sign off inspection'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.hasChinese)
            Padding(padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                    'This inspection has Chinese-origin findings - it cannot be '
                    'signed off as "clear". The server will reject that.',
                    style: TextStyle(fontSize: 12, color: DcovColors.forBanner(
                        'RED', Theme.of(context).brightness)))),
          DropdownButtonFormField<String>(
            initialValue: _verdict,
            items: const [
              DropdownMenuItem(value: 'clear', child: Text('Clear')),
              DropdownMenuItem(value: 'chinese_found', child: Text('Chinese found')),
              DropdownMenuItem(value: 'inconclusive', child: Text('Inconclusive')),
            ],
            onChanged: (v) => setState(() => _verdict = v!),
            decoration: const InputDecoration(labelText: 'Verdict'),
          ),
          const SizedBox(height: 10),
          TextField(controller: _remarks, maxLines: 3,
              decoration: const InputDecoration(labelText: 'Remarks')),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('CANCEL')),
        FilledButton(
          onPressed: () => Navigator.pop(context, {'verdict': _verdict, 'remarks': _remarks.text}),
          child: const Text('SIGN'),
        ),
      ],
    );
  }
}
