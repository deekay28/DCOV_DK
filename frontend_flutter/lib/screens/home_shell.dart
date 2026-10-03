import 'package:flutter/material.dart';
import '../services/app_state.dart';
import '../theme/dcov_theme.dart';
import 'about_screen.dart';
import 'analytics_screen.dart';
import 'catalog_screen.dart';
import 'dashboard_screen.dart';
import 'history_screen.dart';
import 'import_screen.dart';
import 'inspections_screen.dart';
import 'login_screen.dart';
import 'notifications_screen.dart';
import 'reports_screen.dart';
import 'settings_screen.dart';
import 'user_management_screen.dart';
import 'verify_screen.dart';

class HomeShell extends StatefulWidget {
  final AppState app;
  const HomeShell({super.key, required this.app});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;
  String _pendingMarking = '';
  int _verifySeed = 0;

  void _openInVerify(String marking) {
    setState(() { _pendingMarking = marking; _verifySeed++; _tab = 0; });
  }

  Future<void> _openLogin() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => LoginScreen(app: widget.app, onSkip: () => Navigator.pop(context)),
      fullscreenDialog: true,
    ));
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SettingsScreen(app: widget.app),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final app = widget.app;
    final screens = [
      VerifyScreen(key: ValueKey('verify-$_verifySeed-$_pendingMarking'), app: app),
      CatalogScreen(app: app, onOpen: _openInVerify),
      HistoryScreen(app: app),
      DashboardScreen(app: app),
      AboutScreen(app: app),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text.rich(TextSpan(children: [
          const TextSpan(text: 'DCOV', style: TextStyle(fontWeight: FontWeight.w800)),
          TextSpan(text: '/verify', style: TextStyle(color: t.silk, fontWeight: FontWeight.w400)),
        ])),
        actions: [
          // One combined pill: on a 360 dp phone two pills plus five icon
          // buttons overflowed the app bar.
          _pill(context,
              '${app.online ? 'ONLINE' : 'OFFLINE'}${app.pendingSyncCount > 0 ? ' \u00b7 ${app.pendingSyncCount} PENDING' : ''}'
              '${MediaQuery.of(context).size.width >= 600 ? (app.catalog.source == 'bundled' ? ' \u00b7 DB BUNDLED' : ' \u00b7 DB SYNCED') : ''}',
              live: app.online),
          const SizedBox(width: 2),
          Stack(clipBehavior: Clip.none, children: [
            IconButton(
              icon: const Icon(Icons.notifications_outlined, size: 20),
              tooltip: 'Notifications',
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => NotificationsScreen(app: app))),
            ),
            if (app.unreadNotificationCount > 0)
              Positioned(
                right: 6, top: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: DcovColors.forBanner('RED', Theme.of(context).brightness),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  constraints: const BoxConstraints(minWidth: 14),
                  child: Text('${app.unreadNotificationCount}', textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w700)),
                ),
              ),
          ]),
          IconButton(
            icon: const Icon(Icons.settings_outlined, size: 20),
            tooltip: 'Settings',
            onPressed: _openSettings,
          ),
          IconButton(
            icon: Icon(app.isLoggedIn ? Icons.person : Icons.person_outline, size: 20),
            tooltip: app.isLoggedIn ? app.session!.username : 'Sign in',
            onPressed: app.isLoggedIn
                ? () => showModalBottomSheet(
                    context: context,
                    // isScrollControlled matters beyond just "let it get
                    // taller": without it, a bottom sheet's height is
                    // capped at a fixed fraction of the screen computed
                    // once, rather than recomputed against the window's
                    // actual current constraints - which is why resizing
                    // the window's height (not width) while this sheet was
                    // open left it stuck at the wrong size and unresponsive
                    // to taps in the mismatched area. Combined with the
                    // SingleChildScrollView already inside _AccountSheet,
                    // this makes it correctly interactive at any window
                    // size, not just tall enough to avoid scrolling.
                    isScrollControlled: true,
                    builder: (_) => _AccountSheet(app: app))
                : _openLogin,
          ),
          if (MediaQuery.of(context).size.width >= 600) IconButton(
            icon: const Icon(Icons.brightness_6, size: 20),
            onPressed: () => app.setThemeMode(app.themeMode == 'dark' ? 'light' : 'dark'),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListenableBuilder(listenable: app, builder: (_, __) => IndexedStack(index: _tab, children: screens)),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.center_focus_weak_outlined), label: 'VERIFY'),
          NavigationDestination(icon: Icon(Icons.search), label: 'CATALOGUE'),
          NavigationDestination(icon: Icon(Icons.history), label: 'HISTORY'),
          NavigationDestination(icon: Icon(Icons.bar_chart), label: 'OVERVIEW'),
          NavigationDestination(icon: Icon(Icons.info_outline), label: 'LIMITS'),
        ],
      ),
    );
  }

  Widget _pill(BuildContext context, String text, {bool live = false}) {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(border: Border.all(color: t.rule), borderRadius: BorderRadius.circular(2)),
      child: Text(text, style: TextStyle(fontFamily: 'RobotoMono', fontSize: 9.5, letterSpacing: 1,
          color: live ? t.ink : t.ink2)),
    );
  }
}

class _AccountSheet extends StatelessWidget {
  final AppState app;
  const _AccountSheet({required this.app});
  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final s = app.session!;
    return SafeArea(child: SingleChildScrollView(child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(s.username, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        Text(s.role.toUpperCase(), style: TextStyle(fontFamily: 'RobotoMono', fontSize: 11,
            letterSpacing: 1.4, color: t.silk)),
        const SizedBox(height: 6),
        Text('Server: ${app.store.baseUrl}', style: TextStyle(fontSize: 12, color: t.ink2)),
        if (app.pendingSyncCount > 0)
          Padding(padding: const EdgeInsets.only(top: 6),
              child: Text('${app.pendingSyncCount} scan(s) waiting to sync',
                  style: TextStyle(fontSize: 12, color: DcovColors.forBanner('YELLOW', Theme.of(context).brightness)))),
        const SizedBox(height: 16),
        if (const {'administrator', 'database_manager'}.contains(s.role)) ...[
          OutlinedButton.icon(
            onPressed: () {
              Navigator.pop(context);
              Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ImportScreen(app: app)));
            },
            icon: const Icon(Icons.upload_file_outlined, size: 18),
            label: const Text('IMPORT DATABASE'),
          ),
          const SizedBox(height: 8),
        ],
        if (s.role == 'administrator') ...[
          OutlinedButton.icon(
            onPressed: () {
              Navigator.pop(context);
              Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => UserManagementScreen(app: app)));
            },
            icon: const Icon(Icons.people_outline, size: 18),
            label: const Text('USERS'),
          ),
          const SizedBox(height: 8),
        ],
        OutlinedButton.icon(
          onPressed: () {
            Navigator.pop(context);
            Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => AnalyticsScreen(app: app)));
          },
          icon: const Icon(Icons.insights_outlined, size: 18),
          label: const Text('ANALYTICS'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () {
            Navigator.pop(context);
            Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => InspectionsScreen(app: app)));
          },
          icon: const Icon(Icons.assignment_outlined, size: 18),
          label: const Text('INSPECTIONS'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () {
            Navigator.pop(context);
            Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ReportsScreen(app: app)));
          },
          icon: const Icon(Icons.description_outlined, size: 18),
          label: const Text('REPORTS'),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: OutlinedButton(
              onPressed: () {
                Navigator.pop(context);
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => SettingsScreen(app: app)));
              },
              child: const Text('SETTINGS'))),
          const SizedBox(width: 8),
          Expanded(child: OutlinedButton(onPressed: () { app.logout(); Navigator.pop(context); },
              child: const Text('SIGN OUT'))),
        ]),
      ]),
    )));
  }
}
