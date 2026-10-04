import 'package:flutter/material.dart';
import '../services/app_state.dart';
import '../services/local_accounts.dart';
import '../theme/dcov_theme.dart';

/// Sign-in with an account stored on this device - no server needed.
/// First use on a device: creates the first (administrator) account.
class LocalLoginScreen extends StatefulWidget {
  final AppState app;
  const LocalLoginScreen({super.key, required this.app});
  @override
  State<LocalLoginScreen> createState() => _LocalLoginScreenState();
}

class _LocalLoginScreenState extends State<LocalLoginScreen> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;
  bool _busy = false;

  bool get _setup => !widget.app.localAccounts.hasAccounts;

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final app = widget.app;
    setState(() { _busy = true; _error = null; });
    try {
      LocalUser u;
      if (_setup) {
        final uErr = LocalAccounts.validateUsername(_user.text);
        final pErr = LocalAccounts.validatePassword(_pass.text, username: _user.text);
        if (uErr != null || pErr != null) throw LocalAuthException(uErr ?? pErr!);
        if (_pass.text != _confirm.text) throw LocalAuthException('Passwords do not match.');
        u = await app.createFirstLocalAdmin(_user.text.trim(), _pass.text);
      } else {
        u = await app.localSignIn(_user.text.trim(), _pass.text);
      }
      if (!mounted) return;
      final navigator = Navigator.of(context);
      if (u.mustChangePassword) {
        await showDialog<void>(context: context, barrierDismissible: false,
            builder: (_) => LocalChangePasswordDialog(app: app, current: _pass.text, forced: true));
      }
      if (mounted) navigator.pop();
    } on LocalAuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not sign in: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final red = DcovColors.forBanner('RED', Theme.of(context).brightness);
    return Scaffold(
      appBar: AppBar(title: Text(_setup ? 'SET UP THIS DEVICE' : 'SIGN IN ON THIS DEVICE')),
      body: SafeArea(child: ListView(padding: const EdgeInsets.all(20), children: [
        Text(_setup
            ? 'No server needed. Create the first administrator for this phone. The administrator '
              'can then add inspectors, import the component catalogue from a file and run the '
              'app fully offline.'
            : 'Accounts on this device only. Scans are attributed to you and kept on this phone '
              '(marked LOCAL ONLY) until exported or synced to a server.',
            style: TextStyle(fontSize: 13, color: t.ink2, height: 1.4)),
        const SizedBox(height: 18),
        TextField(controller: _user, textInputAction: TextInputAction.next,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Username', border: OutlineInputBorder())),
        const SizedBox(height: 12),
        TextField(controller: _pass, obscureText: true,
            textInputAction: _setup ? TextInputAction.next : TextInputAction.done,
            onSubmitted: _setup ? null : (_) => _submit(),
            decoration: InputDecoration(labelText: 'Password',
                helperText: _setup ? 'At least 8 characters' : null,
                border: const OutlineInputBorder())),
        if (_setup) ...[
          const SizedBox(height: 12),
          TextField(controller: _confirm, obscureText: true, onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(labelText: 'Confirm password',
                  border: OutlineInputBorder())),
        ],
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 12),
            child: Text(_error!, style: TextStyle(color: red, fontSize: 12.5))),
        const SizedBox(height: 18),
        ElevatedButton(
          style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(_setup ? 'CREATE ADMINISTRATOR' : 'SIGN IN'),
        ),
        const SizedBox(height: 10),
        TextButton(onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel - continue without signing in')),
        const SizedBox(height: 16),
        Text('Forgotten password: another administrator on this phone can reset it. If the only '
            'administrator password is lost, the offline accounts can only be cleared by removing '
            'the app\'s data (this also deletes local scans - export them first).',
            style: TextStyle(fontSize: 11.5, color: t.ink2, height: 1.4)),
      ])),
    );
  }
}

class LocalChangePasswordDialog extends StatefulWidget {
  final AppState app;
  final String current;
  final bool forced;
  const LocalChangePasswordDialog({super.key, required this.app, this.current = '', this.forced = false});
  @override
  State<LocalChangePasswordDialog> createState() => _LocalChangePasswordDialogState();
}

class _LocalChangePasswordDialogState extends State<LocalChangePasswordDialog> {
  late final _current = TextEditingController(text: widget.current);
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _current.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_new.text != _confirm.text) {
      setState(() => _error = 'Passwords do not match.');
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      await widget.app.changeLocalPassword(_current.text, _new.text);
      if (mounted) Navigator.of(context).pop();
    } on LocalAuthException catch (e) {
      if (mounted) setState(() { _busy = false; _error = e.message; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.forced ? 'Choose a new password' : 'Change password'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (widget.forced)
          const Padding(padding: EdgeInsets.only(bottom: 10),
              child: Text('Your password was reset by an administrator. Choose your own now.')),
        if (!widget.forced)
          TextField(controller: _current, obscureText: true,
              decoration: const InputDecoration(labelText: 'Current password')),
        TextField(controller: _new, obscureText: true,
            decoration: const InputDecoration(labelText: 'New password (8+ characters)')),
        TextField(controller: _confirm, obscureText: true, onSubmitted: (_) => _submit(),
            decoration: const InputDecoration(labelText: 'Confirm new password')),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 10),
            child: Text(_error!, style: TextStyle(
                color: DcovColors.forBanner('RED', Theme.of(context).brightness), fontSize: 12.5))),
      ])),
      actions: [
        if (!widget.forced)
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('CANCEL')),
        FilledButton(onPressed: _busy ? null : _submit, child: const Text('SAVE')),
      ],
    );
  }
}
