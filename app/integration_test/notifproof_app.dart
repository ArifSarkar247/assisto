// notifproof — the REAL app (lib/main.dart) for the closed-app notification
// proof (.github/workflows/notif-closed.yml, tools/notifproof/np_driver.py).
//
// This is NOT a widget test: the host kills the app process between cases,
// so nothing may run inside an instrumentation. The only addition to the
// shipped app: on the very first start (no saved session) it signs in the
// seeded CI test account A through the app's own AppState.login (token in
// SecretStore, E2E identity key published) — exactly what the login screen
// does — and then starts lib/main.dart unchanged. Every later cold start
// (after a push tap / full-screen alarm) is a plain app start.
//
// Never the owner account: the CI seed accounts only exist on the throw-away
// backend inside the runner (REALITY_API_BASE).
import 'package:flutter/widgets.dart';

import 'package:assisto/main.dart' as app;
import 'package:assisto/state.dart';

const _phoneA = String.fromEnvironment('REALITY_PHONE_A', defaultValue: '01700000001');
const _password = String.fromEnvironment('REALITY_PASSWORD', defaultValue: 'Reality#2026');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final s = AppState();
    await s.init().timeout(const Duration(seconds: 30));
    if (!s.loggedIn) {
      await s
          .login(identifier: _phoneA, password: _password)
          .timeout(const Duration(seconds: 60));
      // ignore: avoid_print
      print('NOTIFPROOF_LOGIN ok');
    } else {
      // ignore: avoid_print
      print('NOTIFPROOF_LOGIN reused');
    }
  } catch (e) {
    // ignore: avoid_print
    print('NOTIFPROOF_LOGIN fail ${'$e'.split('\n').first}');
  }
  app.main();
}
