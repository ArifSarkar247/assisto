import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import 'permission_reason.dart';
import '../services/action_feedback.dart'; // db1

/// Shared live speech-to-text for every chat input (home + Assisto AI).
///
/// * The voice language is AUTOMATIC by default (owner order, build 147): no
///   BN/EN chip on the chat screens. Auto listens with the Bangla (bn-BD)
///   recogniser, which also transcribes English words and mixed "Banglish"
///   speech; if this phone's engine has no Bangla at all, Auto falls back to
///   English instead of failing. A manual override (Auto / Bangla / English)
///   lives ONLY in Settings -> Voice ([VoiceDictation.setMode]).
/// * The actual recogniser locale is resolved from what THIS phone's speech
///   engine offers (bn_BD -> bn_IN -> any bn). If the chosen language is missing
///   we say so plainly and explain how to add it -- never a fake result.
/// * Press-and-hold the mic to talk, release to stop; a short tap toggles.
///   Text goes into the input box only -- it is never auto-sent.
/// * Lazy: the engine is initialised on the first mic use, never at launch.
///   Every call is guarded so the mic can never crash or block the UI.
///
/// HONEST LIMIT: speech_to_text 7.x does not pass Android 14's
/// EXTRA_ENABLE_LANGUAGE_DETECTION extras, so true per-utterance language
/// detection is not used yet (see .phaseB/proposals/p1-sidebar.md).
class VoiceDictation extends ChangeNotifier {
  /// Settings key for the Settings -> Voice override.
  static const modeKey = 'voice_mode_v1';
  static const modes = ['auto', 'bn', 'en'];

  /// The rationale dialog is shown once per app run, not once per screen.
  static bool _reasonShown = false;

  /// NOTE: `SpeechToText()` is a process-wide SINGLETON and its `initialize`
  /// registers status/error callbacks only on the FIRST call. Every start()
  /// therefore re-claims the engine's listeners for THIS instance, or a second
  /// screen's mic would never see 'done' / errors (stuck pulsing).
  final SpeechToText _speech;
  final Future<bool> Function(BuildContext context) _askReason;
  final Future<bool> Function() _micDenied;
  List<String> _available = const [];
  String _base = '';
  TextEditingController? _target;
  BuildContext? _ctx;

  bool listening = false;

  /// True while start() is awaiting the dialog / engine init / listen.
  bool _starting = false;

  /// stop() (finger released, or a 2nd tap) arrived while still starting.
  bool _cancelPending = false;

  /// 'auto' (default), 'bn' or 'en' -- the Settings -> Voice choice.
  String mode;

  /// The language actually being listened in right now ('bn' / 'en').
  String activeLang = 'bn';

  // Auto mode: the bn locale was rejected by the engine for this session, so
  // the next listens go straight to English.
  bool _bnRejected = false;

  VoiceDictation(
      {this.mode = 'auto',
      @visibleForTesting SpeechToText? engine,
      @visibleForTesting Future<bool> Function(BuildContext context)? askReason,
      @visibleForTesting Future<bool> Function()? micDenied})
      : _speech = engine ?? SpeechToText(),
        _askReason = askReason ??
            ((c) => showPermissionReason(c, PermKind.mic)),
        _micDenied = micDenied ?? _osMicDenied;

  @visibleForTesting
  static void debugReset() {
    _reasonShown = false;
  }

  /// Reads the saved Settings -> Voice mode (missing/invalid -> 'auto').
  static Future<String> savedMode() async {
    try {
      final v = await Settings.getString(modeKey);
      return modes.contains(v) ? v! : 'auto';
    } catch (_) {
      return 'auto';
    }
  }

  /// Saves the Settings -> Voice mode.
  static Future<void> saveMode(String mode) async {
    if (!modes.contains(mode)) return;
    try {
      await Settings.setString(modeKey, mode);
    } catch (_) {}
  }

  /// Loads the remembered voice mode for this input.
  Future<void> loadMode() async {
    mode = await savedMode();
    notifyListeners();
  }

  /// Picks the recogniser locale for [lang] from the engine's [available]
  /// locale ids (format varies: bn_BD, bn-IN, bn). Returns null when the
  /// engine reports locales but none in that language. An EMPTY list means the
  /// engine didn't say — we then try the standard id anyway.
  static String? resolveLocale(List<String> available, String lang) {
    final prefs = lang == 'bn'
        ? const ['bn_bd', 'bn_in', 'bn']
        : const ['en_us', 'en_in', 'en_gb', 'en'];
    if (available.isEmpty) return lang == 'bn' ? 'bn_BD' : 'en_US';
    final norm = {
      for (final id in available) id.replaceAll('-', '_').toLowerCase(): id
    };
    for (final p in prefs) {
      if (norm.containsKey(p)) return norm[p];
    }
    for (final e in norm.entries) {
      if (e.key.startsWith('${prefs.last}_')) return e.value;
    }
    return null;
  }

  /// The listen plan for [mode]: the (lang, localeId) to use, or null when the
  /// engine has nothing usable. Auto = Bangla first (bn-BD handles Bangla,
  /// English and mixed speech), English only when Bangla is missing or was
  /// rejected ([bnRejected]). Manual bn/en never silently switch language.
  static ({String lang, String localeId})? pickLocale(
      List<String> available, String mode,
      {bool bnRejected = false}) {
    if (mode == 'bn' || mode == 'en') {
      final id = resolveLocale(available, mode);
      return id == null ? null : (lang: mode, localeId: id);
    }
    if (!bnRejected) {
      final bn = resolveLocale(available, 'bn');
      if (bn != null) return (lang: 'bn', localeId: bn);
    }
    final en = resolveLocale(available, 'en');
    return en == null ? null : (lang: 'en', localeId: en);
  }

  /// Which language's "missing" message to show when [pickLocale] is null.
  static String missingLang(String mode) => mode == 'en' ? 'en' : 'bn';

  Future<void> toggle(BuildContext context, TextEditingController input) =>
      (listening || _starting) ? stop() : start(context, input);

  void _onStatus(String s) {
    if ((s == 'done' || s == 'notListening') && listening) {
      listening = false;
      notifyListeners();
    }
  }

  void _onError(SpeechRecognitionError e) {
    final wasListening = listening;
    listening = false;
    notifyListeners();
    if (!(wasListening || e.permanent)) return;
    if (shouldFallBackToEnglish(mode, activeLang, e.errorMsg)) {
      _bnRejected = true;
    }
    _report(e.errorMsg);
  }

  void _claimEngine() {
    _speech.statusListener = _onStatus;
    _speech.errorListener = _onError;
  }

  Future<void> start(BuildContext context, TextEditingController input) async {
    if (listening || _starting) return;
    _starting = true;
    _cancelPending = false;
    _ctx = context;
    final t = AppLocalizations.of(context);
    HapticFeedback.selectionClick();
    try {
      if (!_speech.isAvailable) {
        if (!_reasonShown) {
          final ok = await _askReason(context);
          if (!ok || !context.mounted) return;
          _reasonShown = true;
          // The dialog took the finger off the mic: the release that ended a
          // hold is not a "stop" — carry on in tap-toggle mode.
          _cancelPending = false;
        }
        final ready = await _speech.initialize(
            onStatus: _onStatus, onError: _onError);
        if (!ready) {
          if (context.mounted) await _explainUnavailable(context, t);
          return;
        }
        try {
          _available =
              (await _speech.locales()).map((l) => l.localeId).toList();
        } catch (_) {
          _available = const [];
        }
      } else if (_available.isEmpty) {
        try {
          _available =
              (await _speech.locales()).map((l) => l.localeId).toList();
        } catch (_) {}
      }
      _claimEngine();
      // a very short hold: the finger was already up before the engine was
      // ready — never start an unwanted listening session.
      if (_cancelPending || !context.mounted) return;
      final plan = pickLocale(_available, mode, bnRejected: _bnRejected);
      if (plan == null) {
        _showMessage(context,
            missingLang(mode) == 'bn' ? t.voiceNoBangla : t.voiceNoEnglish,
            settings: false);
        return;
      }
      _target = input;
      _base = input.text;
      if (_base.isNotEmpty && !_base.endsWith(' ')) _base = '$_base ';
      activeLang = plan.lang;
      listening = true;
      notifyListeners();
      await _speech.listen(
        onResult: (r) {
          final live = '$_base${r.recognizedWords}';
          _target?.value = TextEditingValue(
            text: live,
            selection: TextSelection.collapsed(offset: live.length),
          );
        },
        listenOptions: SpeechListenOptions(
          localeId: plan.localeId,
          partialResults: true,
          cancelOnError: true,
          listenMode: ListenMode.dictation,
          listenFor: const Duration(seconds: 60),
          pauseFor: const Duration(seconds: 5),
        ),
      );
      // released while listen() was still spinning up -> stop now
      _starting = false;
      if (_cancelPending) await stop();
    } catch (_) {
      listening = false;
      notifyListeners();
      if (context.mounted)
        _showMessage(context, t.micEnableSpeech, settings: true);
    } finally {
      _starting = false;
    }
  }

  /// Engine init failed: say WHY (mic permission denied vs no speech service).
  Future<void> _explainUnavailable(
      BuildContext context, AppLocalizations t) async {
    var denied = false;
    try {
      denied = await _micDenied().timeout(const Duration(seconds: 3));
    } catch (_) {}
    if (!context.mounted) return;
    _showMessage(context, denied ? t.voiceNoPermission : t.micEnableSpeech,
        settings: true);
  }

  static Future<bool> _osMicDenied() async {
    final st = await Permission.microphone.status;
    return st.isDenied || st.isPermanentlyDenied || st.isRestricted;
  }

  /// Auto mode only: the engine rejected Bangla, so the NEXT listen in this
  /// input goes straight to English. We deliberately do not restart the
  /// recogniser from inside its own error callback (status events of the
  /// failed session could race the new one); the user sees the honest
  /// "Bangla missing" hint and their next tap works in English.
  static bool shouldFallBackToEnglish(
          String mode, String activeLang, String code) =>
      mode == 'auto' &&
      activeLang == 'bn' &&
      (code == 'error_language_not_supported' ||
          code == 'error_language_unavailable');

  Future<void> stop() async {
    if (_starting) {
      _cancelPending = true;
      return;
    }
    try {
      await _speech.stop();
    } catch (_) {}
    if (listening) {
      listening = false;
      notifyListeners();
    }
  }

  // Maps the engine's error code to a specific, honest message.
  void _report(String code) {
    final ctx = _ctx;
    if (ctx == null || !ctx.mounted) return;
    final t = AppLocalizations.of(ctx);
    switch (code) {
      case 'error_no_match':
      case 'error_speech_timeout':
        _showMessage(ctx, t.voiceNoMatch, settings: false);
      case 'error_language_not_supported':
      case 'error_language_unavailable':
        _showMessage(
            ctx, activeLang == 'bn' ? t.voiceNoBangla : t.voiceNoEnglish,
            settings: false);
      case 'error_network':
      case 'error_network_timeout':
      case 'error_server':
      case 'error_server_disconnected':
        _showMessage(ctx, t.voiceNeedsNet, settings: false);
      case 'error_permission':
      case 'error_insufficient_permissions':
        _showMessage(ctx, t.voiceNoPermission, settings: true);
      case 'error_busy':
      case 'error_recognizer_busy':
        _showMessage(ctx, t.voiceBusy, settings: false);
      default:
        _showMessage(ctx, t.micEnableSpeech, settings: true);
    }
  }

  void _showMessage(BuildContext context, String msg,
      {required bool settings}) {
    final t = AppLocalizations.of(context);
    final m = ScaffoldMessenger.maybeOf(context);
    if (m == null) return;
    m.clearSnackBars();
    m.showSnackBar(SnackBar(
      content: Text(msg),
      duration: const Duration(seconds: 6),
      action: settings
          ? SnackBarAction(
              label: t.open,
              onPressed: () {
                // db1: the snackbar is gone by now; a failure is reported and
                // told with a fresh snackbar.
                openAppSettings().then((ok) {
                  if (!ok) throw StateError('app settings unavailable');
                }).catchError((Object e) {
                  if (context.mounted) {
                    showActionFailed(context, 'voice.openSettings', e,
                        open: true);
                  }
                });
              })
          : null,
    ));
  }

  @override
  void dispose() {
    // The engine is shared: only cancel OUR session, and drop our callbacks.
    try {
      if (listening) _speech.cancel();
      if (_speech.statusListener == _onStatus) {
        _speech.statusListener = null;
        _speech.errorListener = null;
      }
    } catch (_) {}
    super.dispose();
  }
}

/// The mic control for a chat input. The voice language is automatic (see
/// [VoiceDictation]); the only override lives in Settings -> Voice, so there is
/// no language chip here. Hold to talk (release stops), tap to toggle. Pulses
/// while live.
class VoiceMicButton extends StatelessWidget {
  final VoiceDictation voice;
  final TextEditingController input;
  final bool debugListening;
  const VoiceMicButton(
      {super.key,
      required this.voice,
      required this.input,
      this.debugListening = false});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: voice,
      builder: (context, _) {
        final live = voice.listening || debugListening;
        // a11y1: ONE node for TalkBack (label + tap + long-press). Separate
        // tooltip/button nodes left an invisible child node behind when the
        // field scrolled off screen at large text (Flutter asserts on it).
        return MergeSemantics(
          child: Tooltip(
            message: live ? t.voiceReleaseToStop : t.voiceHoldToTalk,
            child: GestureDetector(
              onLongPressStart: (_) => voice.start(context, input),
              onLongPressEnd: (_) => voice.stop(),
              child: live
                  ? _MicPulse(onTap: voice.stop)
                  : IconButton(
                      onPressed: () => voice.toggle(context, input),
                      icon: Icon(Icons.mic_none_rounded,
                          color: scheme.onSurfaceVariant,
                          // f2: the outer Tooltip labels the gesture, not
                          // this button's own semantics node.
                          semanticLabel: t.voiceHoldToTalk),
                    ),
            ),
          ),
        );
      },
    );
  }
}

/// Visible "listening" state: a gently pulsing red stop button.
class _MicPulse extends StatefulWidget {
  final VoidCallback onTap;
  const _MicPulse({required this.onTap});
  @override
  State<_MicPulse> createState() => _MicPulseState();
}

class _MicPulseState extends State<_MicPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return IconButton(
      tooltip: t.voiceReleaseToStop,
      onPressed: widget.onTap,
      icon: AnimatedBuilder(
        animation: _c,
        builder: (_, child) =>
            Transform.scale(scale: 1 + _c.value * 0.18, child: child),
        child: const Icon(Icons.stop_circle_rounded, color: Brand.danger),
      ),
    );
  }
}
