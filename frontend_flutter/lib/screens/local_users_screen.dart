import 'package:flutter/material.dart';
import '../services/app_state.dart';
import '../services/local_accounts.dart';
import '../theme/dcov_theme.dart';
import 'device_import_screen.dart';
import 'local_login_screen.dart';
import 'settings_screen.dart';

const Map<String, String> kRoleLabels = {
  'administrator': 'Administrator - users, catalogue import, everything',
  'database_manager': 'Database manager - catalogue import',
  'inspector': 'Inspector - verify components',
  'viewer': 'Viewer - read only',
};

/// Offline account management (administrators only).
class LocalUsersScreen extends StatefulWidget {
  final AppState app;
  const LocalUsersScreen({super.key, required this.app});
  @override
  State<LocalUsersScreen> createState() => _LocalUsersScreenState();
}

class _LocalUsersScreenState extends State<LocalUsersScreen> {
  String? _error;

  Future<void> _run(Future<void> Function() op, [String? ok]) async {
    setState(() => _error = null);
    try {
      await op();
      await widget.app.refreshLocalUser();
      if (ok != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok)));
      }
    } on LocalAuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
    if (mounted) setState(() {});
  }

  Future<void> _add() async {
    final r = await showDialog<(String, String, String)>(context: context,
        builder: (_) => const _UserDialog(title: 'Add user'));
    if (r == null) return;
    await _run(() => widget.app.localAccounts.create(r.$1, r.$2, r.$3, mustChangePassword: true),
        'User ${r.$1} added. They choose their own password at first sign-in.');
  }

  Future<void> _reset(LocalAccountRecord a) async {
    final r = await showDialog<(String, String, String)>(context: context,
        builder: (_) => _UserDialog(title: 'Reset password for ${a.username}', fixedUsername: a.username,
            fixedRole: a.role));
    if (r == null) return;
    await _run(() => widget.app.localAccounts.resetPassword(a.username, r.$2),
        'Temporary password set for ${a.username}.');
  }

  Future<void> _role(LocalAccountRecord a) async {
    final role = await showDialog<String>(context: context, builder: (ctx) => SimpleDialog(
      title: Text('Role for ${a.username}'),
      children: [
        for (final e in kRoleLabels.entries)
          SimpleDialogOption(onPressed: () => Navigator.pop(ctx, e.key),
              child: Text('${e.key == a.role ? '> ' : ''}${e.value}')),
      ],
    ));
    if (role == null || role == a.role) return;
    await _run(() => widget.app.localAccounts.setRole(a.username, role));
  }

  Future<void> _delete(LocalAccountRecord a) async {
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: Text('Remove ${a.username}?'),
      content: const Text('Their past scans keep their name. They can no longer sign in on this device.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('CANCEL')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('REMOVE')),
      ],
    ));
    if (ok == true) await _run(() => widget.app.localAccounts.delete(a.username));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final me = widget.app.localUser?.username;
    final accounts = widget.app.localAccounts.accounts;
    return Scaffold(
      appBar: AppBar(title: const Text('USERS ON THIS DEVICE')),
      floatingActionButton: FloatingActionButton.extended(
          onPressed: _add, icon: const Icon(Icons.person_add), label: const Text('ADD USER')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 96), children: [
        Text('These accounts exist only on this phone. Server accounts are managed on the server.',
            style: TextStyle(fontSize: 12.5, color: t.ink2)),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_error!,
            style: TextStyle(color: DcovColors.forBanner('RED', Theme.of(context).brightness)))),
        const SizedBox(height: 8),
        for (final a in accounts)
          Card(child: ListTile(
            title: Text('${a.username}${a.username == me ? '  (you)' : ''}'),
            subtitle: Text('${a.role}${a.disabled ? ' - DISABLED' : ''}'
                '${a.mustChangePassword ? ' - must change password' : ''}'),
            trailing: PopupMenuButton<String>(
              onSelected: (v) {
                switch (v) {
                  case 'role': _role(a);
                  case 'reset': _reset(a);
                  case 'disable': _run(() => widget.app.localAccounts.setDisabled(a.username, !a.disabled));
                  case 'delete': _delete(a);
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'role', child: Text('Change role')),
                const PopupMenuItem(value: 'reset', child: Text('Reset password')),
                PopupMenuItem(value: 'disable', child: Text(a.disabled ? 'Enable' : 'Disable')),
                const PopupMenuItem(value: 'delete', child: Text('Remove')),
              ],
            ),
          )),
      ]),
    );
  }
}

class _UserDialog extends StatefulWidget {
  final String title;
  final String? fixedUsername;
  final String? fixedRole;
  const _UserDialog({required this.title, this.fixedUsername, this.fixedRole});
  @override
  State<_UserDialog> createState() => _UserDialogState();
}

class _UserDialogState extends State<_UserDialog> {
  late final _user = TextEditingController(text: widget.fixedUsername ?? '');
  final _pass = TextEditingController();
  late String _role = widget.fixedRole ?? 'inspector';
  String? _error;

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  void _ok() {
    final uErr = widget.fixedUsername == null ? LocalAccounts.validateUsername(_user.text) : null;
    final pErr = LocalAccounts.validatePassword(_pass.text, username: _user.text);
    if (uErr != null || pErr != null) {
      setState(() => _error = uErr ?? pErr);
      return;
    }
    Navigator.pop(context, (_user.text.trim(), _pass.text, _role));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (widget.fixedUsername == null)
          TextField(controller: _user, autocorrect: false,
              decoration: const InputDecoration(labelText: 'Username')),
        TextField(controller: _pass, obscureText: true,
            decoration: const InputDecoration(labelText: 'Temporary password (8+ characters)')),
        if (widget.fixedRole == null) ...[
          const SizedBox(height: 12),
          DropdownButton<String>(
            isExpanded: true,
            value: _role,
            items: [
              for (final r in LocalAccounts.roles)
                DropdownMenuItem(value: r, child: Text(r)),
            ],
            onChanged: (v) => setState(() => _role = v ?? 'inspector'),
          ),
        ],
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_error!,
            style: TextStyle(color: DcovColors.forBanner('RED', Theme.of(context).brightness)))),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('CANCEL')),
        FilledButton(onPressed: _ok, child: const Text('OK')),
      ],
    );
  }
}

/// Account sheet for an offline (device) sign-in - counterpart of the server
/// account sheet in home_shell.dart.
class LocalAccountSheet extends StatelessWidget {
  final AppState app;
  const LocalAccountSheet({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final u = app.localUser!;
    final nav = Navigator.of(context);
    void open(Widget w) {
      nav.pop();
      nav.push(MaterialPageRoute(builder: (_) => w));
    }

    return SafeArea(child: SingleChildScrollView(child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(u.username, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        Text('${u.role.toUpperCase()} - THIS DEVICE ONLY', style: TextStyle(fontFamily: 'RobotoMono',
            fontSize: 11, letterSpacing: 1.4, color: t.silk)),
        const SizedBox(height: 6),
        Text('Offline account. Scans are kept on this phone (LOCAL ONLY).',
            style: TextStyle(fontSize: 12, color: t.ink2)),
        const SizedBox(height: 16),
        if (u.canImportCatalogue) ...[
          OutlinedButton.icon(onPressed: () => open(DeviceImportScreen(app: app)),
              icon: const Icon(Icons.upload_file_outlined, size: 18),
              label: const Text('IMPORT CATALOGUE FROM FILE')),
          const SizedBox(height: 8),
        ],
        if (u.canManageUsers) ...[
          OutlinedButton.icon(onPressed: () => open(LocalUsersScreen(app: app)),
              icon: const Icon(Icons.people_outline, size: 18), label: const Text('USERS ON THIS DEVICE')),
          const SizedBox(height: 8),
        ],
        OutlinedButton.icon(
            onPressed: () {
              nav.pop();
              showDialog<void>(context: nav.context, builder: (_) => LocalChangePasswordDialog(app: app));
            },
            icon: const Icon(Icons.key_outlined, size: 18), label: const Text('CHANGE MY PASSWORD')),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: OutlinedButton(onPressed: () => open(SettingsScreen(app: app)),
              child: const Text('SETTINGS'))),
          const SizedBox(width: 8),
          Expanded(child: OutlinedButton(
              onPressed: () { app.localSignOut(); nav.pop(); },
              child: const Text('SIGN OUT'))),
        ]),
      ]),
    )));
  }
}
