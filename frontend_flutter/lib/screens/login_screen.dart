import 'package:flutter/material.dart';
import '../services/api_client.dart';
import '../services/app_state.dart';
import '../theme/dcov_theme.dart';

class LoginScreen extends StatefulWidget {
  final AppState app;
  final VoidCallback onSkip;
  const LoginScreen({super.key, required this.app, required this.onSkip});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _pin = TextEditingController();
  late final _url = TextEditingController(text: widget.app.store.baseUrl);
  bool _busy = false;
  String? _error;
  bool _showServerField = false;
  // If a PIN was previously enrolled on this device, default to the quick
  // PIN form - that's the whole point of setting one up. "Use password
  // instead" always escapes back to the full form below.
  late bool _usePin = widget.app.pinEnrolledUsername != null;

  String? get _pinUsername => widget.app.pinEnrolledUsername;

  // No server address yet: show the field straight away instead of hiding it
  // behind "Change server address" and failing the first sign-in.
  @override
  void initState() {
    super.initState();
    if (!widget.app.store.hasBaseUrl) _showServerField = true;
  }

  Future<void> _submitPassword() async {
    final url = AppState.normaliseServerUrl(_url.text);
    if (url == null || url.isEmpty) {
      setState(() { _showServerField = true;
        _error = 'Enter the server address first, e.g. http://192.168.1.20:8000'; });
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      await widget.app.setBaseUrl(url);
      await widget.app.login(_user.text.trim(), _pass.text);
      if (!mounted) return;
      final navigator = Navigator.of(context);
      if (widget.app.session?.mustChangePassword == true) {
        await showDialog<void>(context: context, barrierDismissible: false,
            builder: (_) => _ChangePasswordDialog(app: widget.app, current: _pass.text));
      }
      if (mounted) navigator.pop();
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Could not reach ${_url.text.trim()}. Check the address '
          '(Settings > Test connection), or continue offline for now.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submitPin() async {
    final username = _pinUsername;
    if (username == null) return;
    setState(() { _busy = true; _error = null; });
    try {
      await widget.app.loginWithPin(username, _pin.text.trim());
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (e) {
      // A stale/invalid PIN clears itself out of local storage (see
      // AppState.loginWithPin) - reflect that by dropping back to the
      // password form rather than re-showing a PIN field that will just
      // fail again.
      setState(() {
        _error = e.statusCode == 401
            ? 'PIN no longer valid on this device. Sign in with your password.'
            : e.message;
        if (widget.app.pinEnrolledUsername == null) _usePin = false;
      });
    } catch (e) {
      setState(() => _error = 'Could not reach the server. Check the address, or work offline for now.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Scaffold(
      body: SafeArea(child: Center(child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text.rich(TextSpan(children: [
              const TextSpan(text: 'DCOV', style: TextStyle(fontWeight: FontWeight.w800)),
              TextSpan(text: '/verify', style: TextStyle(color: t.silk, fontWeight: FontWeight.w400)),
            ]), style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 24), textAlign: TextAlign.center),
            const SizedBox(height: 28),
            Card(child: Padding(padding: const EdgeInsets.all(20),
              child: (_usePin && _pinUsername != null) ? _pinForm(t) : _passwordForm(t),
            )),
            const SizedBox(height: 14),
            Text(
              'Offline mode uses the bundled catalogue and keeps every scan on this '
              'device only. Sign in once you have a server address to sync the live '
              'catalogue and report findings to the shared audit trail.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: t.ink2, height: 1.5),
            ),
          ]),
        ),
      ))),
    );
  }

  Widget _pinForm(DcovTokens t) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('WELCOME BACK', style: TextStyle(fontFamily: 'RobotoMono', fontSize: 10,
            letterSpacing: 2, color: t.silk, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Text(_pinUsername!, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        const SizedBox(height: 14),
        TextField(controller: _pin, obscureText: true, autofocus: true,
            keyboardType: TextInputType.number, maxLength: 12,
            onSubmitted: (_) => _submitPin(),
            decoration: const InputDecoration(labelText: 'PIN', counterText: '')),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 10),
            child: Text(_error!, style: TextStyle(
                color: DcovColors.forBanner('RED', Theme.of(context).brightness), fontSize: 12.5))),
        const SizedBox(height: 12),
        ElevatedButton(onPressed: _busy ? null : _submitPin,
            child: _busy
                ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('UNLOCK')),
        const SizedBox(height: 10),
        TextButton(onPressed: () => setState(() { _usePin = false; _error = null; }),
            child: const Text('Use password instead', style: TextStyle(fontSize: 12))),
        OutlinedButton(onPressed: widget.onSkip, child: const Text('CONTINUE OFFLINE')),
      ]);

  Widget _passwordForm(DcovTokens t) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('SIGN IN', style: TextStyle(fontFamily: 'RobotoMono', fontSize: 10,
            letterSpacing: 2, color: t.silk, fontWeight: FontWeight.w600)),
        const SizedBox(height: 14),
        TextField(controller: _user, textInputAction: TextInputAction.next,
            decoration: const InputDecoration(labelText: 'Username')),
        const SizedBox(height: 10),
        TextField(controller: _pass, obscureText: true, onSubmitted: (_) => _submitPassword(),
            decoration: const InputDecoration(labelText: 'Password')),
        const SizedBox(height: 10),
        TextButton(onPressed: () => setState(() => _showServerField = !_showServerField),
            child: Text(_showServerField ? 'Hide server address' : 'Change server address',
                style: const TextStyle(fontSize: 12))),
        if (_showServerField)
          TextField(controller: _url,
              decoration: const InputDecoration(labelText: 'Server address',
                  hintText: 'http://192.168.1.20:8000')),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 10),
            child: Text(_error!, style: TextStyle(
                color: DcovColors.forBanner('RED', Theme.of(context).brightness), fontSize: 12.5))),
        const SizedBox(height: 16),
        ElevatedButton(onPressed: _busy ? null : _submitPassword,
            child: _busy
                ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('SIGN IN')),
        const SizedBox(height: 10),
        if (_pinUsername != null)
          TextButton(onPressed: () => setState(() { _usePin = true; _error = null; }),
              child: Text('Use PIN for $_pinUsername instead', style: const TextStyle(fontSize: 12))),
        OutlinedButton(onPressed: widget.onSkip, child: const Text('CONTINUE OFFLINE')),
      ]);
}


/// Forced on first sign-in when the server says must_change_password (new
/// accounts and the bootstrap administrator).
class _ChangePasswordDialog extends StatefulWidget {
  final AppState app;
  final String current;
  const _ChangePasswordDialog({required this.app, required this.current});
  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_new.text.length < 12) {
      setState(() => _error = 'At least 12 characters.');
      return;
    }
    if (_new.text != _confirm.text) {
      setState(() => _error = 'Passwords do not match.');
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      await widget.app.changePassword(widget.current, _new.text);
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (e) {
      setState(() { _busy = false; _error = e.message; });
    } catch (e) {
      setState(() { _busy = false; _error = 'Could not change password: $e'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Set a new password'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('This account must change its password before first use. '
            'At least 12 characters, mixing upper/lower case, digits and a symbol.',
            style: TextStyle(fontSize: 12.5)),
        const SizedBox(height: 10),
        TextField(controller: _new, obscureText: true,
            decoration: const InputDecoration(labelText: 'New password')),
        TextField(controller: _confirm, obscureText: true,
            decoration: const InputDecoration(labelText: 'Confirm new password')),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 8),
            child: Text(_error!, style: TextStyle(fontSize: 12,
                color: DcovColors.forBanner('RED', Theme.of(context).brightness)))),
      ])),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: const Text('LATER')),
        FilledButton(onPressed: _busy ? null : _submit,
            child: _busy ? const SizedBox(width: 16, height: 16,
                child: CircularProgressIndicator(strokeWidth: 2)) : const Text('CHANGE')),
      ],
    );
  }
}
