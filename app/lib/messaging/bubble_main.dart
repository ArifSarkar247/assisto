import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/a11y_prefs.dart';
import '../widgets/bn_day_periods.dart';
import 'chat_opener.dart';
import 'msg_native.dart';

/// bubbles (owner 2 Nov, part B) — the LIGHTWEIGHT app that runs inside the
/// expanded chat bubble (messaging/BubbleActivity.kt → Dart entrypoint
/// `bubbleMain` in lib/main.dart). One chat, read + reply. Deliberately NOT
/// started here: home, FCM/push, the call runtime, sync, pollers, ads,
/// widgets — the main app owns those, so a bubble can never double-ring a
/// call or double-draw a notification. Everything is guarded: a failure
/// shows an honest "couldn't open" state with Retry + "Open in Assisto".
void runBubbleApp() {
  runZonedGuarded(() {
    WidgetsFlutterBinding.ensureInitialized();
    final a11y = A11yPrefs();
    unawaited(a11y.load());
    final app = AppState();
    unawaited(app.initLite());
    runApp(ChangeNotifierProvider<AppState>.value(
      value: app,
      child: BubbleChatApp(a11y: a11y),
    ));
  }, (e, s) {
    debugPrint('bubble: $e');
  });
}

class BubbleChatApp extends StatelessWidget {
  final A11yPrefs a11y;

  /// Tests inject these; the real app asks the native side.
  final Future<String?> Function()? takeChat;
  final Future<Widget> Function(AppState app, String kind, int id)? buildChat;
  const BubbleChatApp(
      {super.key, required this.a11y, this.takeChat, this.buildChat});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
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
          title: 'Assisto',
          debugShowCheckedModeBanner: false,
          theme: light,
          darkTheme: dark,
          themeMode: app.themeMode,
          locale: app.locale ?? const Locale('bn'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            BnDayPeriods.delegate,
          ],
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
          home: BubbleChatHost(
              app: app, takeChat: takeChat, buildChat: buildChat),
        );
      }),
    );
  }
}

enum BubbleStage { loading, signedOut, failed, ready }

/// Resolves which chat this bubble is for, then shows exactly that chat.
class BubbleChatHost extends StatefulWidget {
  final AppState app;
  final Future<String?> Function()? takeChat;
  final Future<Widget> Function(AppState app, String kind, int id)? buildChat;
  const BubbleChatHost(
      {super.key, required this.app, this.takeChat, this.buildChat});

  @override
  State<BubbleChatHost> createState() => _BubbleChatHostState();
}

class _BubbleChatHostState extends State<BubbleChatHost> {
  BubbleStage _stage = BubbleStage.loading;
  ({String kind, int id})? _chat;
  Widget? _screen;
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    widget.app.addListener(_onApp);
    // a second message for the same bubble window (rare: documentLaunchMode
    // gives each chat its own window) → switch to that chat.
    MsgNative.onOpenChat((key) {
      final c = ChatOpener.parse(key);
      if (c != null && mounted) {
        _chat = c;
        unawaited(_load());
      }
    });
    unawaited(_start());
  }

  @override
  void dispose() {
    widget.app.removeListener(_onApp);
    super.dispose();
  }

  void _onApp() {
    if (!widget.app.loading && _stage == BubbleStage.loading && _chat != null) {
      unawaited(_load());
    }
  }

  Future<void> _start() async {
    String? key;
    try {
      key = await (widget.takeChat ?? MsgNative.takeLaunchChat)();
    } catch (_) {}
    _chat = ChatOpener.parse(key);
    if (_chat == null) {
      if (mounted) setState(() => _stage = BubbleStage.failed);
      return;
    }
    if (!widget.app.loading) await _load();
  }

  Future<void> _load() async {
    final c = _chat;
    if (c == null) return;
    final gen = ++_gen;
    if (widget.app.loading) return; // _onApp resumes
    if (!widget.app.loggedIn) {
      if (mounted) setState(() => _stage = BubbleStage.signedOut);
      return;
    }
    if (mounted) setState(() => _stage = BubbleStage.loading);
    try {
      final build = widget.buildChat ??
          (AppState app, String kind, int id) =>
              ChatOpener.buildScreen(app.api, kind, id, bubble: true);
      final screen = await build(widget.app, c.kind, c.id)
          .timeout(const Duration(seconds: 20));
      if (!mounted || gen != _gen) return;
      setState(() {
        _screen = screen;
        _stage = BubbleStage.ready;
      });
    } catch (_) {
      if (!mounted || gen != _gen) return;
      setState(() => _stage = BubbleStage.failed);
    }
  }

  Future<void> _openInApp() async {
    final c = _chat;
    await MsgNative.openInApp(c?.kind ?? 'member', c?.id ?? 0);
  }

  @override
  Widget build(BuildContext context) {
    if (_stage == BubbleStage.ready && _screen != null) {
      return KeyedSubtree(
          key: ValueKey('bbl-chat-${_chat?.kind}-${_chat?.id}'),
          child: _screen!);
    }
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_stage == BubbleStage.loading) {
      return Scaffold(
        body: Center(
          child: Semantics(
            label: t.bblOpening,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(t.bblOpening, textAlign: TextAlign.center),
            ]),
          ),
        ),
      );
    }
    final signedOut = _stage == BubbleStage.signedOut;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                    signedOut
                        ? Icons.login_rounded
                        : Icons.chat_bubble_outline_rounded,
                    size: 48,
                    color: scheme.primary),
                const SizedBox(height: 12),
                Text(signedOut ? t.bblSignedOut : t.bblCantOpen,
                    key: const Key('bbl-state-title'),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium),
                if (!signedOut) ...[
                  const SizedBox(height: 8),
                  Text(t.bblCantOpenHow, textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  if (_chat != null)
                    OutlinedButton.icon(
                      key: const Key('bbl-retry'),
                      style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(48)),
                      onPressed: _load,
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(t.retry),
                    ),
                ],
                const SizedBox(height: 12),
                FilledButton.icon(
                  key: const Key('bbl-open-app'),
                  style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48)),
                  onPressed: _openInApp,
                  icon: const Icon(Icons.open_in_full_rounded),
                  label: Text(t.bblOpenInApp),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
