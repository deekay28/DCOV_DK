import 'package:flutter/material.dart';
import 'services/app_state.dart';
import 'services/local_store.dart';
import 'screens/home_shell.dart';
import 'theme/dcov_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await LocalStore.open();
  final app = AppState(store);
  await app.boot();
  runApp(DcovApp(app: app));
}

class DcovApp extends StatelessWidget {
  final AppState app;
  const DcovApp({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) => MaterialApp(
        title: 'DCOV',
        debugShowCheckedModeBanner: false,
        theme: DcovTheme.light(),
        darkTheme: DcovTheme.dark(),
        themeMode: app.themeMode == 'light'
            ? ThemeMode.light
            : app.themeMode == 'dark'
                ? ThemeMode.dark
                : ThemeMode.system,
        // Wraps every route (this runs above the Navigator, so it survives
        // pushing/popping screens) in the activity listener and, when
        // locked, the lock overlay. See AppState's screen-lock section for
        // why this is a local PIN check rather than a server round trip.
        builder: (context, child) => _ActivityGate(app: app, child: child!),
        home: app.booting
            ? const _SplashScreen()
            : HomeShell(app: app),
      ),
    );
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();
  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}

class _ActivityGate extends StatelessWidget {
  final AppState app;
  final Widget child;
  const _ActivityGate({required this.app, required this.child});

  @override
  Widget build(BuildContext context) {
    return Listener(
      // translucent: records activity without intercepting the touch -
      // whatever's underneath still gets it too.
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => app.recordActivity(),
      child: Stack(children: [
        child,
        if (app.locked) _LockScreen(app: app),
      ]),
    );
  }
}

class _LockScreen extends StatefulWidget {
  final AppState app;
  const _LockScreen({required this.app});
  @override
  State<_LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<_LockScreen> {
  final _pin = TextEditingController();
  String? _error;

  void _submit() {
    if (widget.app.tryUnlock(_pin.text.trim())) {
      _pin.clear();
      setState(() => _error = null);
    } else {
      setState(() => _error = 'Wrong PIN');
      _pin.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    // A dedicated Material ancestor, not just a colored box - this overlay
    // sits above MaterialApp's own Navigator/Scaffold via the builder hook,
    // so it needs its own Material/Directionality context for text fields
    // and buttons inside it to render correctly.
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.lock_outline, size: 40, color: t.silk),
            const SizedBox(height: 16),
            const Text('Session locked', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text('Enter your screen-lock PIN to continue.',
                style: TextStyle(fontSize: 12.5, color: t.ink2)),
            const SizedBox(height: 20),
            SizedBox(width: 220, child: TextField(
              controller: _pin, obscureText: true, autofocus: true,
              keyboardType: TextInputType.number, maxLength: 12, textAlign: TextAlign.center,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(labelText: 'PIN', counterText: '', errorText: _error),
            )),
            const SizedBox(height: 14),
            ElevatedButton(onPressed: _submit, child: const Text('UNLOCK')),
          ]),
        ),
      ),
    );
  }
}
