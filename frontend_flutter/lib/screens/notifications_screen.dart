import 'package:flutter/material.dart';
import '../models/models.dart';
import '../services/app_state.dart';
import '../theme/dcov_theme.dart';

/// In-app notification center. Deliberately in-app only, not push - see
/// docs/ROADMAP.md's Phase 3 note. Sourced entirely from AppState's local
/// list (AppState.pushNotification), populated at the handful of points in
/// this app that generate one: an unknown-component scan, an import
/// commit/failure/rollback, and a detected catalogue change on sync.
class NotificationsScreen extends StatelessWidget {
  final AppState app;
  const NotificationsScreen({super.key, required this.app});

  IconData _icon(String level) => switch (level) {
        'error' => Icons.error_outline,
        'warning' => Icons.warning_amber_rounded,
        _ => Icons.info_outline,
      };

  String _banner(String level) => switch (level) {
        'error' => 'RED', 'warning' => 'YELLOW', _ => 'GREY',
      };

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('NOTIFICATIONS'), actions: [
          if (app.notifications.isNotEmpty) ...[
            TextButton(onPressed: app.markAllNotificationsRead,
                child: const Text('MARK ALL READ', style: TextStyle(fontSize: 11.5))),
            IconButton(icon: const Icon(Icons.delete_outline, size: 20),
                tooltip: 'Clear all', onPressed: () => _confirmClear(context)),
          ],
        ]),
        body: app.notifications.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.notifications_none, size: 40, color: t.silk),
                    const SizedBox(height: 14),
                    const Text('Nothing yet', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    Text(
                        'Unknown components, import results, and catalogue updates '
                        'will show up here as they happen.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12.5, color: t.ink2, height: 1.5)),
                  ]),
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: app.notifications.length,
                separatorBuilder: (_, __) => const SizedBox(height: 6),
                itemBuilder: (context, i) => _tile(context, t, app.notifications[i]),
              ),
      ),
    );
  }

  Future<void> _confirmClear(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear all notifications?'),
        content: const Text('This only clears this list on this device - it does not undo '
            'anything the notifications were about.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('CANCEL')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('CLEAR')),
        ],
      ),
    );
    if (ok == true) app.clearNotifications();
  }

  Widget _tile(BuildContext context, DcovTokens t, AppNotification n) => Card(
        color: n.read ? null : Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        child: ListTile(
          leading: Icon(_icon(n.level), size: 20,
              color: DcovColors.forBanner(_banner(n.level), Theme.of(context).brightness)),
          title: Text(n.title, style: TextStyle(fontSize: 13,
              fontWeight: n.read ? FontWeight.w500 : FontWeight.w700)),
          subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (n.body.isNotEmpty) Text(n.body, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 3),
            Text(_relativeTime(n.at), style: TextStyle(fontSize: 10.5, color: t.ink2)),
          ]),
          isThreeLine: n.body.isNotEmpty,
          onTap: () => app.markNotificationRead(n.id),
        ),
      );

  String _relativeTime(DateTime at) {
    final diff = DateTime.now().difference(at);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}
