import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import 'permission_reason.dart';

/// Shared live speech-to-text for every chat input (home + Assisto AI).
///
/// * The VOICE language (bn / en) is its own choice, independent of the app's
///   UI language, and is remembered. Bangla UI users can dictate English and
///   the other way round.
/// * The actual recogniser locale is resolved from what THIS phone's speech
///   engine offers (bn_BD → bn_IN → any bn). If the engine has no Bangla at
///   all we say so plainly and explain how to add it — never a fake result.
/// * Press-and-hold the mic to talk, release to stop; a short tap toggles.
///   Text goes into the input box only — it is never auto-sent.
/// * Lazy: the engine is initialised on the first mic use, never at launch.
///   Every call is guarded so the mic can never crash or block the UI.
class VoiceDictation extends ChangeNotifier {
  static const _langKey = 'voice_lang_v1';

  final SpeechToText _speech = SpeechToText();
  bool _ready = false;
  bool _initTried = false;
  List<String> _available = const [];
  String _base = '';
  TextEditingController? _target;
  BuildContext? _ctx;

  bool listening = false;

  /// 'bn' or 'en' — the language the user wants to SPEAK.
  String lang;

  VoiceDictation({required this.lang});

  /// Loads the remembered voice language (falls back to the UI language).
  Future<void> loadLang(String uiLocale) async {
    final saved = await Settings.getString(_langKey);
    lang = (saved == 'bn' || saved == 'en')
        ? saved!
        : (uiLocale.startsWith('bn') ? 'bn' : 'en');
    notifyListeners();
  }

  Future<void> toggleLang() async {
    if (listening) await stop();
    lang = lang == 'bn' ? 'en' : 'bn';
    notifyListeners();
    HapticFeedback.selectionClick();
    try {
      await Settings.setString(_langKey, lang);
    } catch (_) {}
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

  Future<void> toggle(BuildContext context, TextEditingController input) =>
      listening ? stop() : start(context, input);

  Future<void> start(BuildContext context, TextEditingController input) async {
    if (listening) return;
    _ctx = context;
    final t = AppLocalizations.of(context);
    HapticFeedback.selectionClick();
    try {
      if (!_ready) {
        if (!_initTried) {
          final ok = await showPermissionReason(context, PermKind.mic);
          if (!ok || !context.mounted) return;
        }
        _initTried = true;
        _ready = await _speech.initialize(
          onStatus: (s) {
            if ((s == 'done' || s == 'notListening') && listening) {
              listening = false;
              notifyListeners();
            }
          },
          onError: (e) {
            final wasListening = listening;
            listening = false;
            notifyListeners();
            if (wasListening || e.permanent) _report(e.errorMsg);
          },
        );
        if (_ready) {
          try {
            _available =
                (await _speech.locales()).map((l) => l.localeId).toList();
          } catch (_) {
            _available = const [];
          }
        }
      }
      if (!_ready) {
        if (context.mounted)
          _showMessage(context, t.micEnableSpeech, settings: true);
        return;
      }
      final localeId = resolveLocale(_available, lang);
      if (localeId == null) {
        if (context.mounted) {
          _showMessage(
              context, lang == 'bn' ? t.voiceNoBangla : t.voiceNoEnglish,
              settings: false);
        }
        return;
      }
      _target = input;
      _base = input.text;
      if (_base.isNotEmpty && !_base.endsWith(' ')) _base = '$_base ';
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
          localeId: localeId,
          partialResults: true,
          cancelOnError: true,
          listenMode: ListenMode.dictation,
          listenFor: const Duration(seconds: 60),
          pauseFor: const Duration(seconds: 5),
        ),
      );
    } catch (_) {
      listening = false;
      notifyListeners();
      if (context.mounted)
        _showMessage(context, t.micEnableSpeech, settings: true);
    }
  }

  Future<void> stop() async {
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
        _showMessage(ctx, lang == 'bn' ? t.voiceNoBangla : t.voiceNoEnglish,
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
                try {
                  openAppSettings();
                } catch (_) {}
              })
          : null,
    ));
  }

  @override
  void dispose() {
    try {
      _speech.cancel();
    } catch (_) {}
    super.dispose();
  }
}

/// The mic control for a chat input: a small bn/EN voice-language chip plus
/// the mic. Hold to talk (release stops), tap to toggle. Pulses while live.
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
        return Row(mainAxisSize: MainAxisSize.min, children: [
          Semantics(
            button: true,
            label: t.voiceLangToggle,
            child: InkWell(
              borderRadius: BorderRadius.circular(Radii.pill),
              onTap: voice.toggleLang,
              child: Container(
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(voice.lang == 'bn' ? t.voiceChipBn : t.voiceChipEn,
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: scheme.primary)),
              ),
            ),
          ),
          Tooltip(
            message: live ? t.voiceReleaseToStop : t.voiceHoldToTalk,
            child: GestureDetector(
              onLongPressStart: (_) => voice.start(context, input),
              onLongPressEnd: (_) => voice.stop(),
              child: live
                  ? _MicPulse(onTap: voice.stop)
                  : IconButton(
                      onPressed: () => voice.toggle(context, input),
                      icon:
                          Icon(Icons.mic_none, color: scheme.onSurfaceVariant),
                    ),
            ),
          ),
        ]);
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
        child: const Icon(Icons.stop_circle, color: Brand.danger),
      ),
    );
  }
}
