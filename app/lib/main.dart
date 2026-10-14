import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'l10n/app_localizations.dart';
import 'alerts_fg.dart';
import 'state.dart';
import 'theme.dart';
import 'updater.dart';
import 'notifications.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';
import 'screens/language_picker_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/elderly_home_screen.dart';
import 'widgets/elderly_mode.dart';

void main() {
  // Nothing in startup may crash the app. Every Dart error — sync, async, or
  // framework — is caught here so the UI still opens; a broken feature degrades
  // silently instead of taking the whole app down.
  runZonedGuarded(() {
    WidgetsFlutterBinding.ensureInitialized();

    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      if (kDebugMode) debugPrint('FlutterError: ${details.exceptionAsString()}');
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      debugPrint('Uncaught (platform): $error');
      return true; // handled — do not crash
    };

    // Notifications init is fully self-guarded; fire-and-forget.
    unawaited(Notifications.init());

    runApp(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => AppState()..init()),
          ChangeNotifierProvider(create: (_) => Updater()..check()),
        ],
        child: const AssistoApp(),
      ),
    );
  }, (error, stack) {
    debugPrint('Uncaught (zone): $error\n$stack');
  });
}

class AssistoApp extends StatelessWidget {
  const AssistoApp({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return MaterialApp(
      title: 'Assisto',
      debugShowCheckedModeBanner: false,
      theme: AssistoTheme.light,
      darkTheme: AssistoTheme.dark,
      themeMode: app.themeMode,
      locale: app.locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      localeResolutionCallback: (device, supported) {
        if (app.locale != null) return app.locale;
        // default to Bangla on first launch
        return const Locale('bn');
      },
      home: const _Root(),
    );
  }
}

class _Root extends StatefulWidget {
  const _Root();
  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> with WidgetsBindingObserver {
  // Elderly simple-mode route-swap (SPEC §29). The LOCAL `elderly_mode` flag is
  // the router's source of truth (works offline); resolved once we know the user
  // is past login/onboarding, and re-resolved on resume (so the Settings toggle
  // takes effect). When ON we render ElderlyHomeScreen instead of HomeScreen;
  // its onExit flips our local state straight back to the normal chat home.
  bool _elderly = false;
  bool _resolving = false; // in-flight guard so builds don't stack reads

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // First foreground poll shortly after launch.
    WidgetsBinding.instance.addPostFrameCallback((_) => _pollAlerts());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Realme-safe proactive alerts: check every time the app comes forward.
    if (state == AppLifecycleState.resumed) {
      _pollAlerts();
      // Re-pick up a flag change made while backgrounded (or in Settings).
      _resolveElderly();
    }
  }

  void _pollAlerts() {
    final app = context.read<AppState>();
    if (app.loggedIn) unawaited(AlertPoller.poll(app.api));
  }

  void _resolveElderly() {
    if (_resolving) return;
    _resolving = true;
    final app = context.read<AppState>();
    EldersModeController.resolveForRouting(app).whenComplete(() {
      _resolving = false;
    }).then((v) {
      if (mounted && v != _elderly) setState(() => _elderly = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    if (app.loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (app.locale == null) {
      return const LanguagePickerScreen();
    }
    if (!app.loggedIn) return const LoginScreen();
    if (!app.onboarded) {
      return OnboardingScreen(onDone: app.markOnboarded);
    }
    // Only resolve the home swap once we're past login + onboarding, so the
    // normal startup flow is never disturbed.
    _resolveElderly();
    if (_elderly) {
      return ElderlyHomeScreen(onExit: () => setState(() => _elderly = false));
    }
    return const HomeScreen();
  }
}
