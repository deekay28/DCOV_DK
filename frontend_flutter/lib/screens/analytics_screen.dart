import 'package:flutter/material.dart';
import '../services/api_client.dart';
import '../services/app_state.dart';
import '../theme/dcov_theme.dart';

/// Surfaces GET /analytics - trends, leaderboards, and heat-map source data
/// that /dashboard doesn't carry. Deliberately hand-rolled bars/lists in the
/// same style as dashboard_screen.dart's subsystem chart rather than a
/// charting package: this app has no chart dependency yet, and pulling one
/// in just for this screen means guessing at another third-party API
/// surface the way share_plus's bit me earlier this project - not worth it
/// for what are, structurally, just sorted bar lists.
class AnalyticsScreen extends StatefulWidget {
  final AppState app;
  const AnalyticsScreen({super.key, required this.app});
  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  Map<String, dynamic>? _data;
  String? _error;
  int _days = 90;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _data = null; _error = null; });
    try {
      final d = await widget.app.api.analytics(days: _days);
      if (mounted) setState(() => _data = d);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not reach the server: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final app = widget.app;
    return Scaffold(
      appBar: AppBar(title: const Text('ANALYTICS'), actions: [
        IconButton(icon: const Icon(Icons.refresh, size: 20), onPressed: _load),
      ]),
      body: !app.isLoggedIn
          ? _notice(t, 'Sign in to view analytics',
              'Trends and leaderboards are computed from the server\'s scan history.')
          : Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Row(children: [
                  Text('WINDOW', style: TextStyle(fontFamily: 'RobotoMono', fontSize: 10,
                      letterSpacing: 1.5, color: t.silk)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Wrap(spacing: 6, children: [
                      for (final d in const [7, 30, 90, 365])
                        ChoiceChip(
                          label: Text('${d}d'),
                          selected: _days == d,
                          onSelected: (_) { setState(() => _days = d); _load(); },
                        ),
                    ]),
                  ),
                ]),
              ),
              Expanded(child: _body(context, t)),
            ]),
    );
  }

  Widget _body(BuildContext context, DcovTokens t) {
    if (_error != null) return _notice(t, 'Could not load analytics', _error!);
    if (_data == null) return const Center(child: CircularProgressIndicator());

    final d = _data!;
    final resultMix = (d['result_mix'] as Map).cast<String, dynamic>();
    final trendMonthly = (d['trend_monthly'] as List).cast<Map<String, dynamic>>();
    final topManufacturers = (d['top_manufacturers'] as List).cast<Map<String, dynamic>>();
    final mostDetected = (d['most_detected_chinese'] as List).cast<Map<String, dynamic>>();
    final unknownComponents = (d['unknown_components'] as List).cast<Map<String, dynamic>>();
    final heatmap = (d['heatmap'] as List).cast<Map<String, dynamic>>()
      ..sort((a, b) => (b['hits'] as int).compareTo(a['hits'] as int));

    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('${d['total_scans']} scan(s) in the last ${d['window_days']} days',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final key in const ['chinese', 'non_chinese', 'unknown_origin', 'not_found'])
          if (resultMix.containsKey(key))
            _resultChip(context, key, resultMix[key] as int),
      ]),

      _section(t, 'MONTHLY TREND', trendMonthly.isEmpty
          ? _empty(t, 'No scans in this window yet.')
          : _monthlyBars(context, t, trendMonthly)),

      _section(t, 'TOP MANUFACTURERS (CHINESE-ORIGIN HITS)', topManufacturers.isEmpty
          ? _empty(t, 'No Chinese-origin scans in this window.')
          : _leaderboard(t, topManufacturers, labelKey: 'manufacturer')),

      _section(t, 'MOST-DETECTED CHINESE COMPONENTS', mostDetected.isEmpty
          ? _empty(t, 'No Chinese-origin scans in this window.')
          : Column(children: [
              for (final m in mostDetected.take(10))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    Container(width: 4, height: 28,
                        color: DcovColors.forBanner('RED', Theme.of(context).brightness)),
                    const SizedBox(width: 10),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text((m['name'] as String?)?.isNotEmpty == true
                              ? m['name'] as String : (m['component_id'] as String? ?? '—'),
                          style: const TextStyle(fontSize: 12.5)),
                      if ((m['manufacturer'] as String?)?.isNotEmpty == true)
                        Text(m['manufacturer'] as String,
                            style: TextStyle(fontSize: 11, color: t.ink2)),
                    ])),
                    Text('${m['hits']}', style: const TextStyle(
                        fontFamily: 'RobotoMono', fontSize: 13, fontWeight: FontWeight.w700)),
                  ]),
                ),
            ])),

      _section(t, 'NEEDS VERIFICATION QUEUE', unknownComponents.isEmpty
          ? _empty(t, 'Nothing waiting on a database manager right now.')
          : Column(children: [
              for (final u in unknownComponents.take(10))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    Icon(Icons.help_outline, size: 15,
                        color: DcovColors.forBanner('YELLOW', Theme.of(context).brightness)),
                    const SizedBox(width: 10),
                    Expanded(child: Text(u['input'] as String? ?? '',
                        style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 12))),
                    Text('${u['hits']}\u00d7', style: TextStyle(fontSize: 11.5, color: t.ink2)),
                  ]),
                ),
            ])),

      _section(t, 'CHINESE-ORIGIN DETECTIONS BY LOCATION \u00d7 WEEKDAY', heatmap.isEmpty
          ? _empty(t, 'No Chinese-origin scans in this window.')
          : Column(children: [
              for (final h in heatmap.take(10))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(children: [
                    Expanded(child: Text(
                        '${h['location']} \u00b7 ${_weekday(h['weekday'] as int)}',
                        style: const TextStyle(fontSize: 12.5))),
                    Text('${h['hits']}', style: const TextStyle(
                        fontFamily: 'RobotoMono', fontSize: 12.5, fontWeight: FontWeight.w600)),
                  ]),
                ),
            ])),
    ]);
  }

  Widget _resultChip(BuildContext context, String key, int count) {
    final banner = switch (key) {
      'chinese' => 'RED', 'non_chinese' => 'GREEN',
      'unknown_origin' => 'YELLOW', _ => 'GREY',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(color: DcovColors.forBanner(banner, Theme.of(context).brightness)),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text('${key.replaceAll('_', ' ')}: $count',
          style: TextStyle(fontSize: 11.5, fontFamily: 'RobotoMono',
              color: DcovColors.forBanner(banner, Theme.of(context).brightness))),
    );
  }

  Widget _monthlyBars(BuildContext context, DcovTokens t, List<Map<String, dynamic>> rows) {
    final maxScans = rows.map((r) => (r['scans'] as int?) ?? 0)
        .fold(1, (a, b) => a > b ? a : b);
    return Column(children: [
      for (final r in rows.take(12))
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [
            SizedBox(width: 58, child: Text(r['month'] as String? ?? '',
                style: TextStyle(fontSize: 11.5, fontFamily: 'RobotoMono', color: t.ink2))),
            Expanded(
              child: Stack(children: [
                Container(height: 14, color: t.panel2),
                FractionallySizedBox(
                  widthFactor: ((r['scans'] as int? ?? 0) / maxScans).clamp(0.02, 1.0),
                  child: Container(height: 14, color: t.silk),
                ),
                if ((r['chinese'] as int? ?? 0) > 0)
                  FractionallySizedBox(
                    widthFactor: ((r['chinese'] as int? ?? 0) / maxScans).clamp(0.02, 1.0),
                    child: Container(height: 14,
                        color: DcovColors.forBanner('RED', Theme.of(context).brightness)),
                  ),
              ]),
            ),
            const SizedBox(width: 8),
            SizedBox(width: 60, child: Text(
                '${r['scans'] ?? 0} (${r['chinese'] ?? 0} \u{1F534})',
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 11, fontFamily: 'RobotoMono'))),
          ]),
        ),
    ]);
  }

  Widget _leaderboard(DcovTokens t, List<Map<String, dynamic>> rows, {required String labelKey}) {
    final maxHits = rows.map((r) => (r['hits'] as int?) ?? 0).fold(1, (a, b) => a > b ? a : b);
    return Column(children: [
      for (final r in rows.take(10))
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [
            SizedBox(width: 130, child: Text(r[labelKey] as String? ?? 'unknown',
                overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12))),
            Expanded(
              child: Stack(children: [
                Container(height: 12, color: t.panel2),
                FractionallySizedBox(
                  widthFactor: ((r['hits'] as int? ?? 0) / maxHits).clamp(0.02, 1.0),
                  child: Container(height: 12, color: t.silk),
                ),
              ]),
            ),
            const SizedBox(width: 8),
            SizedBox(width: 26, child: Text('${r['hits']}', textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 11.5, fontFamily: 'RobotoMono'))),
          ]),
        ),
    ]);
  }

  Widget _section(DcovTokens t, String title, Widget child) => Card(
        margin: const EdgeInsets.only(top: 14),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(fontFamily: 'RobotoMono', fontSize: 10,
                letterSpacing: 1.6, color: t.silk, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            child,
          ]),
        ),
      );

  Widget _empty(DcovTokens t, String msg) =>
      Text(msg, style: TextStyle(fontSize: 12.5, color: t.ink2));

  Widget _notice(DcovTokens t, String title, String body) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.insights_outlined, size: 40, color: t.silk),
            const SizedBox(height: 14),
            Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(body, textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: t.ink2, height: 1.5)),
          ]),
        ),
      );

  String _weekday(int i) => const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][i.clamp(0, 6)];
}
