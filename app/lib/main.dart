import 'feature_flags.dart' show FeatureFlags; // feature-flags
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'l10n/app_localizations.dart';
import 'feedback/feedback_capture.dart';
import 'alerts_fg.dart';
import 'state.dart';
import 'theme.dart';
import 'updater.dart';
import 'screens/always_on_protection_screen.dart'; // play-fgs
import 'media/photo_picker_setup.dart'; // play-perm
import 'play_update.dart'; // ota1
import 'calls/call_native.dart'; // ring-everywhere: smoke ring hook
import 'calls/fullscreen_call_prompt.dart'; // play-fsi
import 'notifications.dart';
import 'calls/call_mini_bar.dart'; // b1: in-app minimized-call bar
import 'push/push_service.dart';
import 'ads/ads_service.dart' show AdsService;
import 'services/home_widget_service.dart';
import 'services/security_guard.dart' show SecurityHeartbeat;
import 'services/startup_guard.dart';
import 'home_api.dart';
import 'widgets/a11y_prefs.dart';
import 'screens/login_screen.dart';
import 'crypto/key_wiring.dart';
import 'growth/install_ping.dart';
import 'diag/crash_boot.dart';
import 'diag/crash_reporter.dart';
import 'screens/home_v2/home_v2_screen.dart'; // home_v2
import 'screens/language_picker_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/elderly_home_screen.dart';
import 'widgets/elderly_mode.dart';
import 'widgets/chatnav.dart';
import 'widgets/bn_day_periods.dart';
import 'voice/va_launch.dart';
import 'photo_studio/ps_web_import.dart';
import 'screens/web_photo_link_screen.dart';
import 'screens/battery_guidance_screen.dart';
import 'screens/ring_checklist_screen.dart'; // ring-everywhere
import 'calls/ring_checklist.dart'; // ring-everywhere
import 'services/antitheft_resume.dart'; // at-heartbeat
import 'antitheft_api.dart'; // grab-guard
import 'widgets/grab_check_dialog.dart'; // grab-guard
import 'device_id.dart'; // own-device
import 'screens/deletion_grace_screen.dart';

void main() {
  // Nothing in startup may crash the app. Every Dart error — sync, async, or
  // framework — is caught here so the UI still opens; a broken feature degrades
  // silently instead of taking the whole app down.
  runZonedGuarded(() {
    WidgetsFlutterBinding.ensureInitialized();

    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      if (kDebugMode) debugPrint('FlutterError: ${details.exceptionAsString()}');
      // sc1: in-memory capture only (scrubbed + sent after the first frame,
      // once the user is signed in and past onboarding)
      CrashReporter.instance
          .capture(details.exception, details.stack, where: 'flutter');
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      debugPrint('Uncaught (platform): $error');
      CrashReporter.instance.capture(error, stack, where: 'platform');
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

    // play-perm: image/video picks use the system Photo Picker (no media
    // permission). A Dart field flip on the registered plugin — no native call.
    usePhotoPicker();

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
      // e2e-recover: restore-from-PIN gate + key backup hooks, BEFORE any
      // sign-in could create a new key (sync, no I/O, guarded).
      try { KeyWiring.instance.installRecoveryHooks(appState); } catch (_) {}
      // own-device: load the hashed install id for the X-Device-Id header
      // (SharedPreferences only, never throws, not awaited).
      unawaited(DeviceId.get());
      final safe = await StartupGuard.isSafeMode();
      // sc1 crash reporting: 4 s after the first frame, guarded; Crashlytics
      // (Firebase) only outside safe mode, our own server sink always.
      unawaited(Future<void>.delayed(const Duration(seconds: 4), () async {
        try { await CrashBoot.start(appState, safeMode: safe); } catch (_) {}
      }));
      // Notifications (local scheduling) — self-guarded, not a startup blocker.
      // Time-boxed: a hang here must not delay key publishing below.
      try { await Notifications.init().timeout(const Duration(seconds: 5)); } catch (_) {}
      // e2-keys: publish the PUBLIC key on every start / login / accept and
      // run the outbox — pure Dart + HTTP, guarded, a few seconds after the
      // first frame (never on the cold-start path, runs in safe mode too).
      unawaited(Future<void>.delayed(const Duration(seconds: 3), () {
        try { KeyWiring.instance.start(appState); } catch (_) {}
      }));
      // p5-growth: anonymous first-open marker for the owner funnel — pure
      // Dart + HTTP, once, well after the first frame, fully guarded.
      unawaited(Future<void>.delayed(const Duration(seconds: 8), () async {
        try { await InstallPing.run(appState); } catch (_) {}
      }));
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
      } else {
        // ty1: safe mode still rings My Circle calls in-app and shows
        // typing / online (pure Dart polling, no Firebase / native init).
        unawaited(Future<void>.delayed(const Duration(seconds: 4), () async {
          try { await PushService.instance.start(appState, realtimeOnly: true); } catch (_) {}
        }));
      }
    });
  }, (error, stack) {
    CrashReporter.instance.capture(error, stack, where: 'zone');
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
          navigatorObservers: [ScreenTracker.instance], // f1-founders
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
            BnDayPeriods.delegate, // qa1: after Global* (they load the date data)
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
              // f1-founders: the root boundary the feedback sheet renders
              // to a screenshot (AppShot.capture; no plugin, lazy).
              child: RepaintBoundary(
                key: AppShot.boundaryKey,
                // b1-calls: "tap to return to the call" bar while a call is
                // minimized (nothing extra is drawn otherwise).
                child: CallMiniBarHost(child: child ?? const SizedBox.shrink()),
              ),
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
  bool _wasLoggedIn = false;
  // Elderly simple-mode route-swap (SPEC §29). The LOCAL `elderly_mode` flag is
  // the router's source of truth (works offline); resolved once we know the user
  // is past login/onboarding, and re-resolved on resume (so the Settings toggle
  // takes effect). When ON we render ElderlyHomeScreen instead of HomeScreen;
  // its onExit flips our local state straight back to the normal chat home.
  bool _elderly = false;
  bool _resolving = false; // in-flight guard so builds don't stack reads
  bool _adsStarted = false; // p2-money
  bool? _homeV2; // home_v2: decided once per app start

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // First foreground poll shortly after launch.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pollAlerts();
      _maybeSmokeOpen();
      PlayUpdate.checkSoon(); // ota1: Play build only, lazy + guarded
      _maybeNotifOpen(); // play-fgs
      // Part 3: opened by the assist gesture / wake word? (lazy, guarded)
      VaLaunch.maybeOpen(context);
      // w1-webphoto: cold-start App Link (lifeassisto.com/photo/app?t=…)
      WebPhotoLink.maybeOpenColdStart(
          context,
          PlatformDispatcher.instance.defaultRouteName,
          (token) => WebPhotoLinkScreen(token: token));
    });
  }

  /// SMOKE-ONLY launch-safety probe. Lets the CI emulator smoke test open one
  /// named feature screen (via `am start --es ao_open <route>`) so a real
  /// native plugin (camera / health / device-admin / foreground-service) is
  /// exercised once on a device. Active only in debug builds and in the CI
  /// x86_64 smoke APK (a release build compiled with --dart-define=
  /// ASSISTO_SMOKE=true, so release-only R8 bugs are caught). Completely inert
  /// in the shipped arm64 APK (no define) and when no extra is passed, and it
  /// only runs AFTER the first frame — never on the cold-start critical path.
  static const bool _smokeBuild = bool.fromEnvironment('ASSISTO_SMOKE');

  /// play-fgs: a foreground-service notification button can ask to open ONE
  /// allow-listed screen (the anti-theft "Turn off" button opens the
  /// protection screen, where the owner switches it off inside the app).
  Future<void> _maybeNotifOpen() async {
    try {
      const ch = MethodChannel('com.assisto/device_admin');
      final v = await ch.invokeMethod<String>('notifOpen');
      if (v != 'antitheft_off' || !mounted) return;
      appNavigatorKey.currentState?.push(MaterialPageRoute<void>(
          builder: (_) => const AlwaysOnProtectionScreen()));
    } catch (_) {
      // channel missing (tests / non-Android): nothing to open
    }
  }

  Future<void> _maybeSmokeOpen() async {
    if (!kDebugMode && !_smokeBuild) return;
    if (_smokeBuild) {
      // ring-everywhere CI proof (job ring-proof): arm the adb-only native
      // ring-test hook. ONLY the CI smoke APK ever does this.
      try {
        if (await CallNative.armRingTest()) debugPrint('RING_HOOK armed');
      } catch (_) {}
    }
    try {
      const ch = MethodChannel('com.assisto/device_admin');
      final route = await ch.invokeMethod<String>('aoSmokeOpen');
      if (route == null || route.isEmpty || !mounted) return;
      if (route == '__ring__') return; // ring-proof: arming above is all
      if (route == '__fsi__') {
        // play-fsi CI proof (Android 14 emulator job fsi-proof-api34)
        await FullScreenCallPrompt.debugProbe();
        return;
      }
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
    // c3-msg: delivered-sync + realtime presence follow the foreground.
    if (state == AppLifecycleState.resumed ||
        state == AppLifecycleState.paused) {
      try {
        PushService.instance
            .onForegroundChanged(state == AppLifecycleState.resumed);
      } catch (_) {}
    }
    if (state == AppLifecycleState.paused) {
      PlayUpdate.onBackground(); // ota1: install a downloaded Play update
    }
    if (state == AppLifecycleState.resumed) {
      // feature-flags: pick up an owner switch (throttled, ETag, offline-safe).
      try {
        unawaited(FeatureFlags.instance
            .refreshWith(context.read<AppState>().api));
      } catch (_) {}
      _pollAlerts();
      _maybeNotifOpen(); // play-fgs
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
    _resumeProtection();
  }

  /// at-heartbeat: on EVERY app open / resume, bring the always-on
  /// Lost/Stolen engine back if protection is ON (an app update or the OS may
  /// have killed it) — start with the stored token, NO SIM rebaseline. Then a
  /// one-time battery-optimisation guide if Android is throttling Assisto.
  /// Seconds after the frame, fire-and-forget, every step crash-guarded.
  void _resumeProtection() {
    Map<String, String> notif = const {};
    try {
      notif = AntiTheftResume.texts(AppLocalizations.of(context));
    } catch (_) {}
    final nav = Navigator.maybeOf(context);
    final route = ModalRoute.of(context);
    final loggedIn = context.read<AppState>().loggedIn;
    unawaited(Future<void>.delayed(const Duration(seconds: 2), () async {
      try {
        final on = await AntiTheftResume.onAppOpen(notif);
        // grab-guard: a grab detected on THIS phone asks "Was this you?"
        // (Security PIN) before the family hears — crash-guarded inside;
        // not tied to the (throttled) resume result.
        if (loggedIn && nav != null && nav.mounted && mounted) {
          final api = context.read<AppState>().api;
          await GrabCheck.maybeShow(nav.context,
              send: (pin) => api.engineFalseAlarm(pin: pin));
        }
        if (!on || !loggedIn || nav == null || !mounted) return;
        await AntiTheftResume.maybeShowBatteryGuide(
            nav, () => const BatteryGuidanceScreen(),
            stillOk: () => mounted && (route == null || route.isCurrent));
      } catch (_) {}
    }));
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
      AdsService.instance.rootScreen = 'language_picker'; // admob: no ads
      return const LanguagePickerScreen();
    }
    if (!app.loggedIn) {
      // admob: the session right after a sign-in never gets an app-open ad
      AdsService.instance.rootScreen = 'login';
      AdsService.instance.noteSignedOut();
      // Signed out (logout, delete account, expired session): drop every
      // pushed screen (e.g. Settings) so the login screen is really visible.
      if (_wasLoggedIn) {
        _wasLoggedIn = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          appNavigatorKey.currentState?.popUntil((r) => r.isFirst);
        });
      }
      return const LoginScreen();
    }
    _wasLoggedIn = true;
    // dl1: signed in during a deletion grace period -> decide first.
    if (app.deletionGraceAt != null) {
      AdsService.instance.rootScreen = 'deletion_grace';
      return const DeletionGraceScreen();
    }
    if (!app.onboarded) {
      AdsService.instance.rootScreen = 'onboarding';
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
    // tl1: OEM background guide, shown ONCE after login as a pushed route
    // (never part of the home screen). Android only; runs seconds after the
    // first frame, one prefs read + one native lookup, all crash-guarded.
    // ring-everywhere: that guide now lives inside the call ring checklist
    // (notifications + full-screen + the same OEM steps), shown once when
    // something is missing.
    RingCheckGate.schedule(
        context, () => const RingChecklistScreen(firstRun: true));
    // Only resolve the home swap once we're past login + onboarding, so the
    // normal startup flow is never disturbed.
    _resolveElderly();
    // p2-money: app-open ads (Free, day 2+, max N/day, never after a
    // notification/deep-link entry, never in elderly simple mode). Lazy:
    // AdsService waits ~8 s after this before doing anything.
    AdsService.instance.suppressAppOpen = _elderly;
    if (!_adsStarted) {
      _adsStarted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        try {
          unawaited(AdsService.instance.start(app));
        } catch (_) {}
      });
    }
    if (_elderly) {
      AdsService.instance.rootScreen = 'elderly_home';
      return ElderlyHomeScreen(onExit: () => setState(() => _elderly = false));
    }
    AdsService.instance.rootScreen = 'home';
    // home_v2 (owner 26 Oct): the new home behind its flag, read from the
    // CACHED flag set loaded at startup (no network wait). Decided once per
    // app start so a background flag refresh never swaps the home under the
    // user; OFF = the previous home, unchanged (one-week fallback).
    final v2 = _homeV2 ??= FeatureFlags.instance.isOn('home_v2');
    return selectHome(v2: v2);
  }
}
