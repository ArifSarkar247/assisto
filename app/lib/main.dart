import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'state.dart';
import 'updater.dart';
import 'notifications.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  Notifications.init();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppState()..init()),
        ChangeNotifierProvider(create: (_) => Updater()..check()),
      ],
      child: const AssistoApp(),
    ),
  );
}

const seed = Color(0xFF0E7C66); // Assisto green accent

class AssistoApp extends StatelessWidget {
  const AssistoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Assisto',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'NotoSansBengali',
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          isDense: true,
        ),
      ),
      home: const _Root(),
    );
  }
}

class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    if (app.loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return app.loggedIn ? const HomeScreen() : const LoginScreen();
  }
}
