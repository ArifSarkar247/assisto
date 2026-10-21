import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'l10n/app_localizations.dart';
import 'alerts_fg.dart';
import 'state.dart';
import 'theme.dart';
import 'updater.dart';
import 'notifications.dart';
import 'push/push_service.dart';
import 'services/home_widget_service.dart';
import 'services/security_guard.dart' show SecurityHeartbeat;
import 'services/startup_guard.dart';
import 'home_api.dart';
import 'widgets/a11y_prefs.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';
import 'screens/language_picker_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/elderly_home_screen.dart';
import 'widgets/elderly_mode.dart';
import 'widgets/chatnav.dart';
import 'voice/va_launch.dart';
import 'photo_studio/ps_web_import.dart';
import 'screens/web_photo_link_screen.dart';

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

    // STARTUP SAFETY (hotfix after the build-99 launch ANR on Realme/ColorOS):
    // NOTHING native runs before the first frame. Optional/native init is
    // deferred to AFTER the UI is on screen, each self-guarded, so a plugin can
    // never block or ANR the launch. A breadcrumb detects a bad previous launch
    // and enters SAFE MODE (skip the deferred native init) + records it.
    StartupGuard.markLaunchStart();

    // Accessibility prefs (#200) — pure SharedPreferences read (no native plugin
    // channel), needed before first frame so text-scale/contrast apply app-wide.
    final a11y = A11yPrefs();
    unawaited(a11y.load());

    // Held here (not only inside the provider) so the deferred push init below
    // can reach it without a BuildContext.
    final appState = AppState()..init();

    runApp(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => appState),
          ChangeNotifierProvider(create: (_) => Updater()..check()),
        ],
        child: AssistoApp(a11y: a11y),
      ),
    );

    // Deferred, post-first-frame, SAFE-MODE-aware init. If the previous launch
    // never reached the home screen, we SKIP all of this and the app still opens.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final safe = await StartupGuard.isSafeMode();
      // Notifications (local scheduling) — self-guarded, not a startup blocker.
      try { await Notifications.init(); } catch (_) {}
      if (!safe) {
        // #196 home-widget plugin — only touch the native widget bridge when the
        // last launch was healthy; never at cold start.
        try { await HomeWidgetService.init(); } catch (_) {}
        // Push (FCM) — lazy, after the first frame and after local
        // notifications are initialised; silently off when this build has no
        // Firebase config. Never blocks or crashes the launch.
        unawaited(Future<void>.delayed(const Duration(seconds: 2), () async {
          try { await PushService.instance.start(appState); } catch (_) {}
        }));
      }
    });
  }, (error, stack) {
    StartupGuard.recordError('$error\n$stack');
    debugPrint('Uncaught (zone): $error\n$stack');
  });
}

class AssistoApp extends StatelessWidget {
  const AssistoApp({super.key, required this.a11y});

  /// One-shot guard so we only clear the launch breadcrumb / upload once.
  static bool _markedHealthy = false;

  /// The app-wide accessibility preferences (#200). Provided via [A11yScope] so
  /// every screen can read/toggle it, and applied app-wide in [build] below.
  final A11yPrefs a11y;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    // Once the first real UI frame renders, the launch is HEALTHY — clear the
    // bad-launch flag and (best-effort) upload any error captured last time.
    if (!_markedHealthy) {
      _markedHealthy = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await StartupGuard.markReachedHome();
        try {
          final err = await StartupGuard.takeError();
          if (err != null && app.loggedIn) {
            await app.api.reportStartupCrash(err);
          }
        } catch (_) {}
      });
    }
    // A11yScope rebuilds this subtree whenever a preference changes, so the
    // text-scale / high-contrast / reduce-motion overrides re-apply instantly.
    return A11yScope(
      prefs: a11y,
      child: Builder(builder: (context) {
        final a = A11yScope.of(context);
        final light = a.highContrast
            ? applyHighContrast(AssistoTheme.light)
            : AssistoTheme.light;
        final dark = a.highContrast
            ? applyHighContrast(AssistoTheme.dark)
            : AssistoTheme.dark;
        return MaterialApp(
          navigatorKey: appNavigatorKey,
          title: 'Assisto',
          debugShowCheckedModeBanner: false,
          theme: light,
          darkTheme: dark,
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
          // App-wide accessibility overrides (#200). We merge our text-scale,
          // high-contrast and reduce-motion prefs into the MediaQuery every
          // screen reads, so no screen needs per-screen wiring.
          builder: (context, child) {
            final mq = MediaQuery.of(context);
            return MediaQuery(
              data: mq.copyWith(
                textScaler: TextScaler.linear(a.textScale),
                highContrast: mq.highContrast || a.highContrast,
                disableAnimations: mq.disableAnimations || a.reduceMotion,
              ),
              child: child ?? const SizedBox.shrink(),
            );
          },
          home: const _Root(),
          // w1-webphoto: https://lifeassisto.com/photo/app?t=… (Android App
          // Link, Flutter's built-in deep linking — no plugin). Only that
          // path is handled; every other name returns null exactly as before.
          onGenerateRoute: (s) => WebPhotoLink.route(
              s, (token) => WebPhotoLinkScreen(token: token)),
        );
      }),
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pollAlerts();
      _maybeSmokeOpen();
      // Part 3: opened by the assist gesture / wake word? (lazy, guarded)
      VaLaunch.maybeOpen(context);
      // w1-webphoto: cold-start App Link (lifeassisto.com/photo/app?t=…)
      WebPhotoLink.maybeOpenColdStart(
          context,
          PlatformDispatcher.instance.defaultRouteName,
          (token) => WebPhotoLinkScreen(token: token));
    });
  }

  /// DEBUG-ONLY launch-safety probe. Lets the CI emulator smoke test open one
  /// named feature screen (via `am start --es ao_open <route>`) so a real
  /// native plugin (camera / health / device-admin / foreground-service) is
  /// exercised once on a device. Completely inert in the shipped release APK
  /// (kDebugMode == false) and when no extra is passed, and it only runs AFTER
  /// the first frame — never on the cold-start critical path.
  Future<void> _maybeSmokeOpen() async {
    if (!kDebugMode) return;
    try {
      const ch = MethodChannel('com.assisto/device_admin');
      final route = await ch.invokeMethod<String>('aoSmokeOpen');
      if (route == null || route.isEmpty || !mounted) return;
      if (route == '__tour__') {
        // CI calls this once, on the very first (race-free) cold start, to walk
        // every re-enabled native-plugin screen in a SINGLE process — so the
        // real camera / foreground-service / device-admin / sensor plugins each
        // load once. A native crash kills the process (caught by the smoke
        // test's logcat + liveness check); Dart-level errors stay guarded.
        const tour = ['voice_sos', 'lost_stolen', 'watch_feed', 'fall_detect',
            'voice_settings'];
        for (final r in tour) {
          if (!mounted) return;
          try {
            final nav = Navigator.of(context);
            ChatNav.push(context, r);
            await Future.delayed(const Duration(seconds: 3));
            if (nav.canPop()) nav.pop();
            await Future.delayed(const Duration(milliseconds: 700));
          } catch (_) {}
        }
      } else {
        ChatNav.push(context, route);
      }
    } catch (_) {}
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
      // Part 3: assist gesture / wake word while Assisto was in background.
      VaLaunch.maybeOpen(context);
    }
  }

  void _pollAlerts() {
    final app = context.read<AppState>();
    if (app.loggedIn) {
      unawaited(AlertPoller.poll(app.api));
      // Anti-theft Batch 5: best-effort FOREGROUND heartbeat — fires only if
      // the server says protection is armed. Lazy, crash-guarded, throttled,
      // never blocks resume (same fire-and-forget pattern as the alert poll).
      unawaited(SecurityHeartbeat.maybeSend(app.api));
    }
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
    // w1-webphoto: a website-photo link that arrived signed out opens now.
    final webTok = WebPhotoLink.pending;
    if (webTok != null) {
      WebPhotoLink.pending = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        try {
          Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => WebPhotoLinkScreen(token: webTok)));
        } catch (_) {}
      });
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
