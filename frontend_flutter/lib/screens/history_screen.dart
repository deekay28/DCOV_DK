import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/app_state.dart';
import '../theme/dcov_theme.dart';

class HistoryScreen extends StatelessWidget {
  final AppState app;
  const HistoryScreen({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final items = app.history;
    final fmt = DateFormat('MM-dd HH:mm');
    final pending = app.pendingSyncCount;

    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Card(child: Padding(padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('INSPECTION HISTORY \u2014 THIS DEVICE', style: TextStyle(fontFamily: 'RobotoMono',
                fontSize: 10, letterSpacing: 2, color: t.silk, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(
              app.isLoggedIn
                  ? (pending > 0
                      ? '$pending scan(s) captured offline are waiting to sync to the server.'
                      : 'Every scan on this device is recorded here, and mirrored to the '
                        'server audit trail when signed in and online.')
                  : 'Sign in to sync scans to the server audit trail. Until then, '
                    'history stays on this device only.',
              style: TextStyle(fontSize: 12.5, color: t.ink2)),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              // Was `Row(children: [OutlinedButton(...)])` - a single-child
              // Row serving no layout purpose, and the same bug family as
              // the earlier VERIFY button crash: this Column's
              // crossAxisAlignment: start gives the Row unbounded height
              // (Column's normal main-axis passthrough), and a lone
              // non-Expanded Row child inherits that unbounded height
              // alongside loose width - OutlinedButton's internal minimum-
              // height ConstrainedBox can't resolve against an unbounded
              // incoming constraint. Align has no such failure mode: it
              // sizes itself to its child regardless of how loose/unbounded
              // its own incoming constraints are, so it's a strict
              // improvement here even setting the crash aside - this Row
              // never had more than one child to lay out in the first place.
              child: OutlinedButton(onPressed: items.isEmpty ? null : () => app.clearHistory(),
                  child: const Text('CLEAR')),
            ),
          ]),
        )),
      ),
      Expanded(child: items.isEmpty
          ? Center(child: Text('Nothing verified yet on this device', style: TextStyle(color: t.ink2)))
          : ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: items.length,
              separatorBuilder: (_, __) => Divider(color: t.rule, height: 1),
              itemBuilder: (_, i) {
                final h = items[i];
                final color = DcovColors.forBanner(
                    h.banner.isNotEmpty ? h.banner :
                    h.result == 'chinese' ? 'RED' :
                    h.result == 'non_chinese' ? 'GREEN' :
                    h.result == 'unknown_origin' ? 'YELLOW' : 'GREY',
                    Theme.of(context).brightness);
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Container(width: 10, height: 10, margin: const EdgeInsets.only(top: 6),
                      decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                  title: Text(h.raw, style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 13.5)),
                  subtitle: Text(
                      '${h.componentName.isNotEmpty ? h.componentName : 'no catalogue match'} \u00b7 '
                      '${h.method} \u00b7 ${h.score.toStringAsFixed(0)}% \u00b7 ${h.mode}',
                      style: TextStyle(fontSize: 11.5, color: t.ink2)),
                  trailing: Column(mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(fmt.format(h.at),
                        style: TextStyle(fontFamily: 'RobotoMono', fontSize: 11, color: t.silk)),
                    const SizedBox(height: 2),
                    Text(h.status == 'online_verified' ? 'SERVER'
                        : h.status == 'pending_sync' ? 'PENDING' : 'LOCAL',
                        style: TextStyle(fontFamily: 'RobotoMono', fontSize: 9.5,
                            letterSpacing: 1, color: t.ink2)),
                  ]),
                );
              },
            )),
    ]);
  }
}
