import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../push/lock_screen_guard.dart';
import '../state.dart';
import '../theme.dart';
import '../train/dest_alarm_sound.dart';
import 'carecall_alarms.dart';
import 'carecall_api.dart';

/// carecall SCREEN 2 — the receiver's incoming Care Call, full screen like a
/// real call (also over the lock screen: MainActivity allows it for a Care
/// Call launch only). Big fonts and two very large stacked buttons for
/// elderly users. On open the ring stops and the setter's OWN recorded voice
/// plays (STREAM_ALARM, loud even on silent); without a recording a normal
/// on-device Bangla voice reads the text — never an AI voice.
class CareCallRingScreen extends StatefulWidget {
  const CareCallRingScreen({super.key, required this.data, this.api, this.sound, this.autoPlay = true});

  /// The ring payload (push data / local alarm payload, see ccRingData).
  final Map<String, String> data;
  final CareCallApi? api;
  final DestAlarmSound? sound;
  final bool autoPlay;

  /// Slots whose ring screen is on screen now (the cold-start route and the
  /// notification's launch details can both ask for it).
  static final Set<String> open = {};

  /// The route name used for the cold start (MainActivity.getInitialRoute).
  static const route = '/carecall_ring';

  static Route<void> pageRoute(Map<String, String> data, {RouteSettings? settings}) =>
      MaterialPageRoute<void>(
          settings: settings ?? const RouteSettings(name: route),
          fullscreenDialog: true,
          builder: (_) => CareCallRingScreen(data: data));

  /// MaterialApp.onGenerateRoute hook: '/carecall_ring?p=<payload json>'.
  static Route<dynamic>? onGenerateRoute(RouteSettings s) {
    final name = s.name ?? '';
    if (!name.startsWith(route)) return null;
    try {
      final d = CareCallActions.dataOf(Uri.parse(name).queryParameters['p']);
      if (d == null) return null;
      final sk = d['slot_key'] ?? '';
      if (open.contains(sk)) return null;
      return pageRoute(d, settings: s);
    } catch (_) {
      return null;
    }
  }

  /// Open the ring screen once per slot (warm start / foreground push tap).
  static bool openOnce(NavigatorState? nav, Map<String, String> data) {
    final sk = data['slot_key'] ?? '';
    if (nav == null || sk.isEmpty || open.contains(sk)) return nav != null && sk.isNotEmpty;
    unawaited(nav.push(pageRoute(data)));
    return true;
  }

  @override
  State<CareCallRingScreen> createState() => _CareCallRingScreenState();
}

class _CareCallRingScreenState extends State<CareCallRingScreen> {
  late final DestAlarmSound _sound = widget.sound ?? NativeDestAlarmSound();
  bool _busy = false;
  bool _ownVoice = false;
  bool _answered = false;

  Map<String, String> get d => widget.data;
  String get _name => (d['setter_name'] ?? '').trim();
  String get _text => (d['text'] ?? '').trim();
  String get _sk => d['slot_key'] ?? '';

  @override
  void initState() {
    super.initState();
    CareCallRingScreen.open.add(_sk);
    _ownVoice = (int.tryParse(d['voice_rev'] ?? '') ?? 0) > 0;
    // the screen is up: stop the ring (insistent call sound) for this slot
    unawaited(CareCallAlarms.cancelSlot(_sk, attempt: int.tryParse(d['attempt'] ?? '')));
    if (widget.autoPlay) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _play());
    }
  }

  Future<void> _play() async {
    final id = int.tryParse(d['care_call_id'] ?? '') ?? 0;
    final rev = int.tryParse(d['voice_rev'] ?? '') ?? 0;
    String? path = await CareCallVoice.cached(id, rev);
    if (path == null && rev > 0) {
      final api = _api();
      if (api != null) path = await CareCallVoice.ensure(api, id, rev);
    }
    var ok = false;
    if (path != null) ok = await _sound.playClip(path);
    if (!ok) {
      if (mounted && _ownVoice) setState(() => _ownVoice = false);
      if (!mounted) return;
      final t = AppLocalizations.of(context);
      final lang = Localizations.localeOf(context).languageCode == 'en' ? 'en' : 'bn';
      await _sound.speak(
          _text.isEmpty ? t.ccRingTitle(_name) : '${t.ccRingTitle(_name)}। $_text', lang);
    }
  }

  CareCallApi? _api() {
    if (widget.api != null) return widget.api;
    try {
      final app = context.read<AppState>();
      return app.loggedIn ? HttpCareCallApi(app.api) : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _answer(String action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _sound.stop();
    } catch (_) {
      // best-effort: the voice may already have finished
    }
    await CareCallActions.answer(d, action, api: _api());
    if (!mounted) return;
    _answered = true;
    final t = AppLocalizations.of(context);
    final m = ScaffoldMessenger.maybeOf(context);
    Navigator.of(context).maybePop();
    m?.showSnackBar(SnackBar(
        content: Text(action == 'done' ? t.ccRingDoneToast(_name) : t.ccRingSnoozeToast)));
  }

  @override
  void dispose() {
    CareCallRingScreen.open.remove(_sk);
    unawaited(_sound.stop().catchError((_) {}));
    unawaited(LockScreenGuard.release());
    if (!_answered) {
      // closed without an answer: the server's retry (10 min) stays on
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final initial = (d['setter_initial'] ?? '').trim().isNotEmpty
        ? d['setter_initial']!.trim()
        : (_name.isNotEmpty ? _name.substring(0, 1).toUpperCase() : '?');
    return Scaffold(
      backgroundColor: s.surface,
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [s.primaryContainer.withValues(alpha: 0.55), s.surface],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(builder: (context, box) {
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.lg, Gap.xl, Gap.xl),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: box.maxHeight - Gap.lg - Gap.xl),
                child: IntrinsicHeight(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Semantics(
                        header: true,
                        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Icon(Icons.phone_in_talk_rounded, size: 20, color: s.onSurfaceVariant),
                          const SizedBox(width: Gap.xs),
                          Flexible(
                            child: Text(t.ccRingTopLabel,
                                textAlign: TextAlign.center,
                                style: tt.titleSmall?.copyWith(color: s.onSurfaceVariant)),
                          ),
                        ]),
                      ),
                      const Spacer(),
                      const SizedBox(height: Gap.xl),
                      Center(
                        child: ExcludeSemantics(
                          child: Container(
                            width: 148,
                            height: 148,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: s.primary,
                              border: Border.all(color: s.primary.withValues(alpha: 0.25), width: 10,
                                  strokeAlign: BorderSide.strokeAlignOutside),
                            ),
                            alignment: Alignment.center,
                            child: Text(initial,
                                style: tt.displayMedium?.copyWith(
                                    color: s.onPrimary, fontWeight: FontWeight.w700)),
                          ),
                        ),
                      ),
                      const SizedBox(height: Gap.xl),
                      Text(t.ccRingTitle(_name),
                          textAlign: TextAlign.center,
                          style: tt.headlineMedium?.copyWith(
                              fontWeight: FontWeight.w700, color: s.onSurface, fontSize: 30, height: 1.25)),
                      if (_text.isNotEmpty) ...[
                        const SizedBox(height: Gap.lg),
                        Text('“$_text”',
                            textAlign: TextAlign.center,
                            style: tt.headlineSmall?.copyWith(color: s.onSurface, fontSize: 25, height: 1.35)),
                      ],
                      const SizedBox(height: Gap.lg),
                      Center(
                        child: Semantics(
                          button: true,
                          label: t.ccRingPlayAgain,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(24),
                            onTap: _busy ? null : () => _play(),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(minHeight: 48),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
                                child: Row(mainAxisSize: MainAxisSize.min, children: [
                                  Icon(Icons.volume_up_rounded, color: s.primary, size: 26),
                                  const SizedBox(width: Gap.sm),
                                  Flexible(
                                    child: Text(
                                        _ownVoice ? t.ccRingVoicePlaying(_name) : t.ccRingReadingAloud,
                                        style: tt.titleMedium?.copyWith(color: s.primary, fontSize: 19)),
                                  ),
                                ]),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const Spacer(),
                      const SizedBox(height: Gap.xl),
                      ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 76),
                        child: FilledButton.icon(
                          style: Brand.successButton().copyWith(
                            shape: WidgetStatePropertyAll(
                                RoundedRectangleBorder(borderRadius: BorderRadius.circular(38))),
                            textStyle: WidgetStatePropertyAll(
                                tt.titleLarge?.copyWith(fontSize: 24, fontWeight: FontWeight.w700)),
                          ),
                          onPressed: _busy ? null : () => _answer('done'),
                          icon: const Icon(Icons.check_rounded, size: 32),
                          label: Text(t.ccRingDone),
                        ),
                      ),
                      const SizedBox(height: Gap.md),
                      ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 72),
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(36)),
                            side: BorderSide(color: s.outline, width: 2),
                            foregroundColor: s.onSurface,
                            textStyle: tt.titleMedium?.copyWith(fontSize: 20, fontWeight: FontWeight.w600),
                          ),
                          onPressed: _busy ? null : () => _answer('snooze'),
                          icon: const Icon(Icons.snooze_rounded, size: 28),
                          label: Text(t.ccRingSnooze, textAlign: TextAlign.center),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}
