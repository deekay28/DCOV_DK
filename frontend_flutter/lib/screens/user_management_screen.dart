import 'package:flutter/material.dart';
import '../services/api_client.dart';
import '../services/app_state.dart';
import '../theme/dcov_theme.dart';

const _roles = ['administrator', 'database_manager', 'inspector', 'viewer'];

/// user:manage is Administrator-only on the backend (security.py's
/// PERMISSIONS matrix) - the strictest single-role gate in the app, and the
/// only screen where that's the entire audience. Deactivate rather than
/// delete is the only path offered here, deliberately: see
/// ADMIN_MANUAL.md's note on why (a hard delete orphans that user's
/// attribution on every historical scan and audit entry).
class UserManagementScreen extends StatefulWidget {
  final AppState app;
  const UserManagementScreen({super.key, required this.app});
  @override
  State<UserManagementScreen> createState() => _UserManagementScreenState();
}

class _UserManagementScreenState extends State<UserManagementScreen> {
  List<Map<String, dynamic>>? _users;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _users = null; _error = null; });
    try {
      final u = await widget.app.api.listUsers();
      if (mounted) setState(() => _users = u);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not reach the server: $e');
    }
  }

  Future<void> _createUser() async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CreateUserSheet(app: widget.app),
    );
    if (result == true) _load();
  }

  Future<void> _openUser(Map<String, dynamic> user) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _UserDetailSheet(app: widget.app, user: user),
    );
    if (changed == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final app = widget.app;
    final isAdmin = app.session?.role == 'administrator';
    return Scaffold(
      appBar: AppBar(title: const Text('USERS'), actions: [
        IconButton(icon: const Icon(Icons.refresh, size: 20), onPressed: _load),
      ]),
      floatingActionButton: !app.isLoggedIn || !isAdmin
          ? null
          : FloatingActionButton.extended(
              onPressed: _createUser,
              icon: const Icon(Icons.person_add_alt, size: 20),
              label: const Text('NEW USER'),
            ),
      body: !app.isLoggedIn || !isAdmin
          ? _notice(t, !app.isLoggedIn ? 'Sign in to manage users' : 'Not permitted',
              !app.isLoggedIn
                  ? 'User management requires an active session.'
                  : 'Your role (${app.session?.role}) cannot manage users. Administrator only.')
          : _error != null
              ? _notice(t, 'Could not load users', _error!)
              : _users == null
                  ? const Center(child: CircularProgressIndicator())
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: _users!.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 6),
                      itemBuilder: (context, i) => _userTile(context, t, _users![i]),
                    ),
    );
  }

  Widget _userTile(BuildContext context, DcovTokens t, Map<String, dynamic> u) {
    final active = u['is_active'] as bool? ?? true;
    return Card(
      child: ListTile(
        enabled: true,
        leading: CircleAvatar(
          radius: 16,
          backgroundColor: active ? t.panel2 : DcovColors.forBanner('GREY', Theme.of(context).brightness),
          child: Text((u['username'] as String? ?? '?').substring(0, 1).toUpperCase(),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
        ),
        title: Row(children: [
          Text(u['username'] as String? ?? '', style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
          if (!active) Padding(padding: const EdgeInsets.only(left: 8),
              child: Text('DEACTIVATED', style: TextStyle(fontSize: 9.5, fontFamily: 'RobotoMono',
                  color: DcovColors.forBanner('GREY', Theme.of(context).brightness)))),
        ]),
        subtitle: Text('${u['role']}${(u['unit'] as String?)?.isNotEmpty == true ? ' \u00b7 ${u['unit']}' : ''}',
            style: TextStyle(fontSize: 11.5, color: t.ink2)),
        trailing: const Icon(Icons.chevron_right, size: 18),
        onTap: () => _openUser(u),
      ),
    );
  }

  Widget _notice(DcovTokens t, String title, String body) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.people_outline, size: 40, color: t.silk),
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
class _CreateUserSheet extends StatefulWidget {
  final AppState app;
  const _CreateUserSheet({required this.app});
  @override
  State<_CreateUserSheet> createState() => _CreateUserSheetState();
}

class _CreateUserSheetState extends State<_CreateUserSheet> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _fullName = TextEditingController();
  final _unit = TextEditingController();
  String _role = 'viewer';
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_username, _password, _fullName, _unit]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() { _busy = true; _error = null; });
    try {
      final user = await widget.app.api.createUser(
        username: _username.text.trim(), password: _password.text,
        fullName: _fullName.text.trim(), unit: _unit.text.trim(), role: _role,
      );
      if (mounted) {
        Navigator.pop(context, true);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
            'Created ${user['username']}. They must change their password on first login.')));
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
            Text('NEW USER', style: TextStyle(fontFamily: 'RobotoMono', fontSize: 10.5,
                letterSpacing: 2, color: t.silk, fontWeight: FontWeight.w600)),
            const SizedBox(height: 14),
            TextField(controller: _username, autocorrect: false,
                decoration: const InputDecoration(labelText: 'Username')),
            const SizedBox(height: 8),
            TextField(controller: _password, obscureText: true,
                decoration: const InputDecoration(labelText: 'Temporary password',
                    helperText: '12+ characters, upper, lower, digit, symbol')),
            const SizedBox(height: 8),
            TextField(controller: _fullName, decoration: const InputDecoration(labelText: 'Full name')),
            const SizedBox(height: 8),
            TextField(controller: _unit, decoration: const InputDecoration(labelText: 'Unit')),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: _role,
              items: [for (final r in _roles) DropdownMenuItem(value: r, child: Text(r))],
              onChanged: (v) => setState(() => _role = v!),
              decoration: const InputDecoration(labelText: 'Role'),
            ),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 10),
                child: Text(_error!, style: TextStyle(fontSize: 12.5,
                    color: DcovColors.forBanner('RED', Theme.of(context).brightness)))),
            const SizedBox(height: 16),
            SizedBox(width: double.infinity, child: FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('CREATE USER'),
            )),
          ],
        ),
      ),
    );
  }
}

// --------------------------------------------------------------------- //
class _UserDetailSheet extends StatefulWidget {
  final AppState app;
  final Map<String, dynamic> user;
  const _UserDetailSheet({required this.app, required this.user});
  @override
  State<_UserDetailSheet> createState() => _UserDetailSheetState();
}

class _UserDetailSheetState extends State<_UserDetailSheet> {
  bool _busy = false;
  String? _error;

  bool get _isSelf => widget.app.session?.userId == widget.user['id'];

  Future<void> _changeRole(String role) async {
    setState(() { _busy = true; _error = null; });
    try {
      await widget.app.api.setUserRole(widget.user['id'] as String, role);
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      setState(() { _busy = false; _error = e.message; });
    } catch (e) {
      setState(() { _busy = false; _error = 'Could not reach the server: $e'; });
    }
  }

  Future<void> _toggleActive(bool active) async {
    setState(() { _busy = true; _error = null; });
    try {
      await widget.app.api.setUserActive(widget.user['id'] as String, active);
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      setState(() { _busy = false; _error = e.message; });
    } catch (e) {
      setState(() { _busy = false; _error = 'Could not reach the server: $e'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final u = widget.user;
    final active = u['is_active'] as bool? ?? true;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(u['username'] as String, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            if ((u['full_name'] as String?)?.isNotEmpty == true)
              Text(u['full_name'] as String, style: TextStyle(fontSize: 13, color: t.ink2)),
            const SizedBox(height: 16),
            if (_isSelf)
              Padding(padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                      'This is your own account. You cannot remove your own '
                      'administrator role - another administrator has to do that, '
                      'so the system is never left without one.',
                      style: TextStyle(fontSize: 12, color: t.ink2))),
            Text('ROLE', style: TextStyle(fontFamily: 'RobotoMono', fontSize: 10,
                letterSpacing: 1.5, color: t.silk)),
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final r in _roles)
                ChoiceChip(
                  label: Text(r),
                  selected: u['role'] == r,
                  onSelected: _busy || (r != 'administrator' && _isSelf && u['role'] == 'administrator')
                      ? null
                      : (_) => _changeRole(r),
                ),
            ]),
            const SizedBox(height: 20),
            Row(children: [
              Expanded(child: Text(active ? 'Account active' : 'Account deactivated',
                  style: const TextStyle(fontSize: 13))),
              if (!_isSelf)
                Switch(value: active, onChanged: _busy ? null : _toggleActive),
            ]),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 10),
                child: Text(_error!, style: TextStyle(fontSize: 12.5,
                    color: DcovColors.forBanner('RED', Theme.of(context).brightness)))),
          ],
        ),
      ),
    );
  }
}
