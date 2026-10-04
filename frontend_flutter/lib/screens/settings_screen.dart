import 'package:flutter/material.dart';
import '../services/api_client.dart';
import '../services/app_state.dart';
import '../theme/dcov_theme.dart';

/// Reachable from the gear icon in the app bar regardless of login state -
/// server address and theme matter before you've ever signed in. Sections
/// that need an active session (PIN enrollment, sign-out) disable
/// themselves with an explanation rather than disappearing, so the layout
/// doesn't shift depending on auth state.
class SettingsScreen extends StatefulWidget {
  final AppState app;
  const SettingsScreen({super.key, required this.app});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _url =
      TextEditingController(text: widget.app.store.baseUrl);
  final _pinController = TextEditingController();
  final _pinConfirmController = TextEditingController();
  bool _savingUrl = false;
  bool _savingPin = false;
  String? _pinError;
  String? _pinSuccess;

  @override
  void dispose() {
    _url.dispose();
    _pinController.dispose();
    _pinConfirmController.dispose();
    super.dispose();
  }

  String? _testResult;
  bool _testing = false;
  bool _syncingNow = false;

  Future<void> _saveUrl() async {
    final clean = AppState.normaliseServerUrl(_url.text);
    if (clean == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('That is not a valid address. Example: http://192.168.1.20:8000')));
      return;
    }
    setState(() => _savingUrl = true);
    await widget.app.setBaseUrl(clean);
    _url.text = clean;
    if (mounted) {
      setState(() => _savingUrl = false);
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Server address saved.')));
    }
  }

  bool _updatingCatalogue = false;
  String? _catalogueResult;

  Future<void> _updateCatalogue() async {
    setState(() { _updatingCatalogue = true; _catalogueResult = null; });
    final r = await widget.app.updateCatalogueNow();
    if (mounted) setState(() { _updatingCatalogue = false; _catalogueResult = r; });
  }

  Future<void> _testUrl() async {
    setState(() { _testing = true; _testResult = null; });
    final r = await widget.app.testServer(_url.text);
    if (mounted) setState(() { _testing = false; _testResult = r; });
  }

  Future<void> _syncNow() async {
    setState(() => _syncingNow = true);
    await widget.app.checkServer();
    final n = await widget.app.flushPendingScans();
    if (!mounted) return;
    setState(() => _syncingNow = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
        !widget.app.online ? 'Server not reachable - scans stay queued.'
        : !widget.app.isLoggedIn ? 'Sign in to upload queued scans.'
        : '$n scan(s) uploaded.')));
  }

  Future<void> _setupPin() async {
    setState(() { _pinError = null; _pinSuccess = null; });
    final pin = _pinController.text.trim();
    if (pin.length < 4 || pin.length > 12 || !RegExp(r'^\d+$').hasMatch(pin)) {
      setState(() => _pinError = 'PIN must be 4-12 digits.');
      return;
    }
    if (pin != _pinConfirmController.text.trim()) {
      setState(() => _pinError = 'PINs do not match.');
      return;
    }
    setState(() => _savingPin = true);
    try {
      await widget.app.setupPin(pin);
      if (!mounted) return;
      setState(() {
        _savingPin = false;
        _pinSuccess = 'PIN set up for quick unlock on this device.';
        _pinController.clear();
        _pinConfirmController.clear();
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() { _savingPin = false; _pinError = e.message; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _savingPin = false; _pinError = 'Could not set up PIN: $e'; });
    }
  }

  Future<void> _disablePin() async {
    await widget.app.disablePin();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final app = widget.app;
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('SETTINGS')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _section(t, 'CONNECTION', [
              _row('Status', app.online ? 'Online - server reachable' : 'Offline'),
              if (app.serverStatusDetail.isNotEmpty) _row('Detail', app.serverStatusDetail),
              _row('Catalogue source', app.catalog.source == 'server'
                  ? 'Synced from server' : app.catalog.source == 'server_cache'
                  ? 'Last server sync (cached on device)' : 'Bundled with app'),
              _row('Catalogue records', '${app.catalog.count}'
                  '${app.catalog.loadedAt != null && app.catalog.source != 'bundled' ? ' - synced ${app.catalog.loadedAt!.toLocal().toString().substring(0, 16)}' : ''}'),
              const SizedBox(height: 6),
              OutlinedButton.icon(
                onPressed: _updatingCatalogue ? null : _updateCatalogue,
                icon: _updatingCatalogue
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.sync, size: 16),
                label: const Text('UPDATE CATALOGUE NOW')),
              if (_catalogueResult != null) Padding(padding: const EdgeInsets.only(top: 6),
                  child: Text(_catalogueResult!, style: const TextStyle(fontSize: 12)))
              else if (!app.isLoggedIn) Padding(padding: const EdgeInsets.only(top: 6),
                  child: Text('Needs a signed-in server connection. Offline, the app uses the '
                      'catalogue bundled with it or the last one downloaded.',
                      style: TextStyle(fontSize: 11.5, color: t.ink2))),
              const SizedBox(height: 10),
              Text('Server address', style: TextStyle(fontSize: 11.5, letterSpacing: 1,
                  color: t.silk, fontFamily: 'RobotoMono')),
              const SizedBox(height: 6),
              Row(children: [
                Expanded(child: TextField(controller: _url,
                    decoration: const InputDecoration(
                        hintText: 'http://192.168.1.20:8000', isDense: true,
                        border: OutlineInputBorder()))),
                const SizedBox(width: 8),
                FilledButton(
                    // Same shape as the VERIFY button crash (bare Material
                    // button beside an Expanded TextField, in a Row) -
                    // fixed pre-emptively with the same proven technique
                    // rather than waiting for this one to crash on tap.
                    style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
                    onPressed: _savingUrl ? null : _saveUrl,
                    child: _savingUrl
                        ? const SizedBox(width: 16, height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('SAVE')),
              ]),
              const SizedBox(height: 4),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _testing ? null : _testUrl,
                icon: _testing
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.wifi_tethering, size: 16),
                label: const Text('TEST CONNECTION')),
              if (_testResult != null) Padding(padding: const EdgeInsets.only(top: 6),
                  child: Text(_testResult!, style: const TextStyle(fontSize: 12))),
              const SizedBox(height: 8),
              Text('Physical phone: the LAN address of the PC running the server, e.g. '
                  'http://192.168.1.20:8000 (shown by scripts/run_lan_server). '
                  'Android emulator: http://10.0.2.2:8000. Production: https://your-domain. '
                  'Do not use 127.0.0.1 on a phone - that is the phone itself.',
                  style: TextStyle(fontSize: 11.5, color: t.ink2)),
            ]),

            _section(t, 'SECURITY', [
              if (!app.isLoggedIn) ...[
                Text('Sign in with your password to set up a PIN for quick '
                    'unlock on this device.', style: TextStyle(fontSize: 13, color: t.ink2)),
              ] else if (app.pinEnrolledUsername == app.session?.username) ...[
                Row(children: [
                  Icon(Icons.check_circle, size: 16, color: DcovColors.forBanner(
                      'GREEN', Theme.of(context).brightness)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(
                      'PIN unlock is set up for ${app.session!.username} on this device.',
                      style: const TextStyle(fontSize: 13))),
                ]),
                const SizedBox(height: 10),
                OutlinedButton(onPressed: _disablePin,
                    child: const Text('REMOVE PIN FROM THIS DEVICE')),
              ] else ...[
                Text('Set a PIN to unlock the app quickly on this device without '
                    'typing your full password every time. The PIN only ever works '
                    'from this device - it is meaningless to anyone who does not '
                    'already have it in their hands.',
                    style: TextStyle(fontSize: 13, color: t.ink2)),
                const SizedBox(height: 12),
                TextField(controller: _pinController, obscureText: true,
                    keyboardType: TextInputType.number, maxLength: 12,
                    decoration: const InputDecoration(labelText: 'New PIN (4-12 digits)',
                        isDense: true, border: OutlineInputBorder())),
                TextField(controller: _pinConfirmController, obscureText: true,
                    keyboardType: TextInputType.number, maxLength: 12,
                    decoration: const InputDecoration(labelText: 'Confirm PIN',
                        isDense: true, border: OutlineInputBorder())),
                if (_pinError != null)
                  Padding(padding: const EdgeInsets.only(top: 4),
                      child: Text(_pinError!, style: TextStyle(fontSize: 12,
                          color: DcovColors.forBanner('RED', Theme.of(context).brightness)))),
                if (_pinSuccess != null)
                  Padding(padding: const EdgeInsets.only(top: 4),
                      child: Text(_pinSuccess!, style: TextStyle(fontSize: 12,
                          color: DcovColors.forBanner('GREEN', Theme.of(context).brightness)))),
                const SizedBox(height: 10),
                FilledButton(onPressed: _savingPin ? null : _setupPin,
                    child: _savingPin
                        ? const SizedBox(width: 16, height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('SET UP PIN')),
              ],
              const SizedBox(height: 14),
              Text('Biometric unlock (fingerprint/face) is supported by the server '
                  'but not yet wired up in this app build.',
                  style: TextStyle(fontSize: 11.5, color: t.ink2, fontStyle: FontStyle.italic)),
            ]),

            _section(t, 'SCREEN LOCK', [
              Text(
                  'Separate from the sign-in PIN above: locks the app screen '
                  'after it sits idle, and unlocks with no network needed at '
                  'all - it never contacts the server. Protects an unattended '
                  'unlocked device, not your account.',
                  style: TextStyle(fontSize: 12, color: t.ink2, height: 1.4)),
              const SizedBox(height: 12),
              if (app.appLockEnabled) ...[
                Row(children: [
                  Icon(Icons.check_circle, size: 16, color: DcovColors.forBanner(
                      'GREEN', Theme.of(context).brightness)),
                  const SizedBox(width: 8),
                  const Expanded(child: Text('Screen lock is on', style: TextStyle(fontSize: 13))),
                ]),
                const SizedBox(height: 10),
                Row(children: [
                  const Expanded(child: Text('Lock after idle for', style: TextStyle(fontSize: 13))),
                  DropdownButton<int>(
                    value: app.autoLockMinutes,
                    items: const [1, 5, 15, 30, 60]
                        .map((m) => DropdownMenuItem(value: m, child: Text('$m min')))
                        .toList(),
                    onChanged: (v) { if (v != null) app.setAutoLockMinutes(v); },
                  ),
                ]),
                const SizedBox(height: 8),
                OutlinedButton(onPressed: () async {
                  await app.disableAppLock();
                  if (mounted) setState(() {});
                }, child: const Text('TURN OFF SCREEN LOCK')),
              ] else
                _ScreenLockSetup(app: app, onDone: () => setState(() {})),
            ]),

            _section(t, 'APPEARANCE', [
              Row(children: [
                Expanded(child: Text('Theme', style: TextStyle(fontSize: 13))),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'dark', label: Text('DARK')),
                    ButtonSegment(value: 'light', label: Text('LIGHT')),
                  ],
                  selected: {app.themeMode},
                  onSelectionChanged: (s) => app.setThemeMode(s.first),
                ),
              ]),
            ]),

            _section(t, 'DEVICE', [
              _row('Device ID', app.store.deviceId),
              _row('Pending scans to sync', '${app.pendingSyncCount}'),
              const SizedBox(height: 8),
              OutlinedButton(onPressed: _syncingNow ? null : _syncNow,
                  child: Text(_syncingNow ? 'SYNCING\u2026' : 'SYNC NOW')),
            ]),

            if (app.isLoggedIn)
              _section(t, 'SESSION', [
                _row('Signed in as', app.session!.username),
                _row('Role', app.session!.role),
                const SizedBox(height: 10),
                OutlinedButton(
                  onPressed: () async {
                    // Capture the Navigator *before* the await, not just
                    // guard the BuildContext use afterward with `mounted` -
                    // the first attempt (an `if (!mounted) return;` guard
                    // immediately before `Navigator.of(context)`) still
                    // tripped use_build_context_synchronously on a second
                    // real analyze run. Capturing the NavigatorState ahead
                    // of the async gap removes any BuildContext-derived call
                    // from after the gap entirely, which is the version of
                    // this pattern the lint actually accepts unconditionally.
                    final navigator = Navigator.of(context);
                    await app.logout();
                    if (!mounted) return;
                    navigator.pop();
                  },
                  child: const Text('SIGN OUT'),
                ),
              ]),
          ],
        ),
      ),
    );
  }

  Widget _section(DcovTokens t, String title, List<Widget> children) => Card(
        margin: const EdgeInsets.only(bottom: 14),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(fontFamily: 'RobotoMono', fontSize: 10.5,
                letterSpacing: 2, color: t.silk, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            ...children,
          ]),
        ),
      );

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          SizedBox(width: 140, child: Text(label, style: const TextStyle(fontSize: 12.5))),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 12.5,
              fontFamily: 'RobotoMono'), overflow: TextOverflow.ellipsis)),
        ]),
      );
}

class _ScreenLockSetup extends StatefulWidget {
  final AppState app;
  final VoidCallback onDone;
  const _ScreenLockSetup({required this.app, required this.onDone});
  @override
  State<_ScreenLockSetup> createState() => _ScreenLockSetupState();
}

class _ScreenLockSetupState extends State<_ScreenLockSetup> {
  final _pin = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final pin = _pin.text.trim();
    if (pin.length < 4 || pin.length > 12 || !RegExp(r'^\d+$').hasMatch(pin)) {
      setState(() => _error = 'PIN must be 4-12 digits.');
      return;
    }
    if (pin != _confirm.text.trim()) {
      setState(() => _error = 'PINs do not match.');
      return;
    }
    await widget.app.setAppLockPin(pin);
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextField(controller: _pin, obscureText: true, keyboardType: TextInputType.number,
          maxLength: 12,
          decoration: const InputDecoration(labelText: 'New screen-lock PIN', isDense: true,
              border: OutlineInputBorder())),
      TextField(controller: _confirm, obscureText: true, keyboardType: TextInputType.number,
          maxLength: 12,
          decoration: const InputDecoration(labelText: 'Confirm', isDense: true,
              border: OutlineInputBorder())),
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 4, bottom: 4),
          child: Text(_error!, style: TextStyle(fontSize: 12,
              color: DcovColors.forBanner('RED', Theme.of(context).brightness)))),
      const SizedBox(height: 6),
      FilledButton(onPressed: _submit, child: const Text('TURN ON SCREEN LOCK')),
    ]);
  }
}
