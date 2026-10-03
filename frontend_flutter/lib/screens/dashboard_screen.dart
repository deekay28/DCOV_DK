import 'package:flutter/material.dart';
import '../services/app_state.dart';
import '../theme/dcov_theme.dart';
import 'analytics_screen.dart';
import 'inspections_screen.dart';
import 'reports_screen.dart';

class DashboardScreen extends StatelessWidget {
  final AppState app;
  const DashboardScreen({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final counts = app.catalog.counts;
    final policy = app.catalog.policy;

    final bySub = <String, int>{};
    for (final r in app.catalog.index.rows) {
      if (r['is_chinese'] == 'YES') {
        final s = r['drone_subsystem']?.toString() ?? 'Other';
        bySub[s] = (bySub[s] ?? 0) + 1;
      }
    }
    final entries = bySub.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final maxCount = entries.isEmpty ? 1 : entries.map((e) => e.value).reduce((a, b) => a > b ? a : b);

    return ListView(padding: const EdgeInsets.all(16), children: [
      GridView.count(
        crossAxisCount: 2, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 1, crossAxisSpacing: 1, childAspectRatio: 1.7,
        children: [
          _gauge(context, '${counts['total']}', 'RECORDS', null),
          _gauge(context, '${counts['chinese']}', 'CHINESE ORIGIN', 'RED'),
          _gauge(context, '${counts['non_chinese']}', 'NON-CHINESE', 'GREEN'),
          _gauge(context, '${counts['unknown']}', 'ORIGIN UNKNOWN', 'YELLOW'),
          _gauge(context, '${counts['chinese_critical']}', 'CHINESE + CRITICAL', 'RED'),
          _gauge(context, '${app.history.length}', 'VERIFIED THIS DEVICE', null),
        ],
      ),
      const SizedBox(height: 14),
      OutlinedButton.icon(
        onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => AnalyticsScreen(app: app))),
        icon: const Icon(Icons.insights_outlined, size: 18),
        label: const Text('ANALYTICS',
            style: TextStyle(fontSize: 12, letterSpacing: 1)),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => InspectionsScreen(app: app))),
        icon: const Icon(Icons.assignment_outlined, size: 18),
        label: const Text('INSPECTIONS',
            style: TextStyle(fontSize: 12, letterSpacing: 1)),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => ReportsScreen(app: app))),
        icon: const Icon(Icons.description_outlined, size: 18),
        label: const Text('GENERATE A REPORT',
            style: TextStyle(fontSize: 12, letterSpacing: 1)),
      ),
      const SizedBox(height: 14),
      Card(child: Padding(padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('CHINESE-ORIGIN PARTS BY SUBSYSTEM', style: TextStyle(fontFamily: 'RobotoMono',
              fontSize: 10, letterSpacing: 2, color: t.silk, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          ...entries.map((e) {
            final crit = (policy[e.key]?['level'] == 'CRITICAL');
            final barColor = crit
                ? DcovColors.forBanner('RED', Theme.of(context).brightness)
                : t.silk;
            return Padding(padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(children: [
                SizedBox(width: 110, child: Text(e.key, style: TextStyle(fontSize: 12,
                    color: crit ? barColor : null))),
                Expanded(child: Container(height: 14, decoration: BoxDecoration(color: t.panel2),
                  child: FractionallySizedBox(alignment: Alignment.centerLeft,
                      widthFactor: e.value / maxCount,
                      child: Container(color: barColor)))),
                const SizedBox(width: 8),
                SizedBox(width: 22, child: Text('${e.value}', textAlign: TextAlign.right,
                    style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 12))),
              ]));
          }),
        ]),
      )),
      const SizedBox(height: 14),
      Card(child: Padding(padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('ACCEPTANCE POLICY', style: TextStyle(fontFamily: 'RobotoMono', fontSize: 10,
              letterSpacing: 2, color: t.silk, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text('A Chinese-origin part in a CRITICAL subsystem is an escalation, not a note.',
              style: TextStyle(fontSize: 12.5, color: t.ink2)),
          const SizedBox(height: 10),
          ...policy.entries.map((e) {
            final level = e.value['level']?.toString() ?? '';
            final crit = level == 'CRITICAL';
            return Padding(padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(e.key, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
                  Text(level, style: TextStyle(fontSize: 11,
                      color: crit ? DcovColors.forBanner('RED', Theme.of(context).brightness) : t.ink2)),
                ]),
                const SizedBox(height: 2),
                Text(e.value['policy']?.toString() ?? '', style: TextStyle(fontSize: 12, color: t.ink2)),
              ]));
          }),
        ]),
      )),
    ]);
  }

  Widget _gauge(BuildContext context, String number, String label, String? colorBand) {
    final t = context.tokens;
    final color = colorBand == null ? t.ink : DcovColors.forBanner(colorBand, Theme.of(context).brightness);
    return Container(
      color: t.panel,
      padding: const EdgeInsets.all(13),
      // FittedBox scales the whole number+label block down together when
      // the window narrows, instead of letting the fixed 26px number text
      // overflow its cell - this grid's cells shrink with the window
      // (fixed crossAxisCount: 2) but nothing inside them used to shrink
      // to match, unlike every other screen's ListView/Expanded-based
      // layout, which is why this was the one place that overflowed on
      // resize while the rest of the app adapted fine.
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(number, style: TextStyle(fontFamily: 'RobotoMono', fontSize: 26, fontWeight: FontWeight.w700, color: color)),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(fontFamily: 'RobotoMono', fontSize: 9.5, letterSpacing: 1.4, color: t.silk)),
          ]),
      ),
    );
  }
}
