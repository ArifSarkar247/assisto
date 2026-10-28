import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import 'va_native.dart';
import 'va_wake.dart';

/// aivoice: reads one chat answer aloud ("Listen" / "Stop reading") through
/// the EXISTING lazy, crash-guarded TextToSpeech channel ([VaNative.speak] —
/// no new plugin, no new native code). The engine is created only on the
/// first Listen tap, never at launch.
///
/// HONEST fallbacks (Gemini shows "No audio generated" for Bangla; we say
/// what is missing and how to fix it):
///   * 'no_voice'  -> the phone has no voice for that language: one snackbar
///                    with "Install" (opens the phone's TTS settings),
///   * 'no_engine' / null (native half missing) -> no TTS engine at all.
class ReplySpeaker extends ChangeNotifier {
  ReplySpeaker({
    @visibleForTesting Future<String?> Function(String text, String lang)? speak,
    @visibleForTesting Future<void> Function()? stop,
  })  : _speakFn = speak ?? VaNative.speak,
        _stopFn = stop ?? VaNative.stopSpeaking;

  final Future<String?> Function(String text, String lang) _speakFn;
  final Future<void> Function() _stopFn;

  /// The key (message id / index) of the answer being read right now.
  String? speakingKey;
  int _seq = 0;
  bool _disposed = false;

  bool isSpeaking(String key) => speakingKey == key;

  /// Android's TextToSpeech rejects very long input
  /// (getMaxSpeechInputLength() is 4000 on most engines); we stay well under.
  static const maxChars = 1500;

  /// Reads [text] aloud. Completes when the utterance has FINISHED (or was
  /// stopped) with the engine's result: 'ok' | 'no_voice' | 'no_engine' |
  /// 'empty' | 'stopped' | null (native missing). Never throws.
  Future<String?> speak(String key, String text, {String? lang}) async {
    final clean = speakable(text);
    if (clean.isEmpty) return 'empty';
    final my = ++_seq;
    try {
      await _stopFn();
    } catch (_) {}
    speakingKey = key;
    _notify();
    String? r;
    try {
      r = await _speakFn(clean, lang ?? langOf(clean));
    } catch (_) {
      r = 'no_engine';
    }
    if (my != _seq) return 'stopped'; // a newer speak/stop took over
    speakingKey = null;
    _notify();
    return r;
  }

  Future<void> stop() async {
    _seq++;
    speakingKey = null;
    _notify();
    try {
      await _stopFn();
    } catch (_) {}
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _seq++;
    if (speakingKey != null) {
      try {
        _stopFn();
      } catch (_) {}
    }
    super.dispose();
  }

  /// 'bn' when Bengali-script letters are at least a third of the letters,
  /// else 'en'. An answer in Bangla with a few English words stays 'bn'.
  static String langOf(String text) {
    var bn = 0, latin = 0;
    for (final r in text.runes) {
      if (r >= 0x0980 && r <= 0x09FF) {
        bn++;
      } else if ((r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A)) {
        latin++;
      }
    }
    if (bn == 0 && latin == 0) return 'bn';
    return bn * 2 >= latin ? 'bn' : 'en';
  }

  static final _fence = RegExp(r'```[\s\S]*?(```|$)');
  static final _url = RegExp(r'https?://\S+|www\.\S+');
  static final _mdMarks = RegExp(r'[*_`#>|~]+');
  static final _bullet = RegExp(r'^\s*([-•]|\d+[.)])\s+', multiLine: true);
  static final _space = RegExp(r'[ \t]+');
  static final _blankLines = RegExp(r'\n{2,}');

  /// The text a voice should read: code blocks, links, markdown marks and
  /// emoji removed; capped at [maxChars] on a sentence end when possible.
  static String speakable(String text) {
    var s = text.replaceAll(_fence, ' ');
    s = s.replaceAll(_url, ' ');
    s = s.replaceAll(_bullet, '');
    s = s.replaceAll(_mdMarks, ' ');
    final b = StringBuffer();
    for (final r in s.runes) {
      final emoji = (r >= 0x1F000 && r <= 0x1FAFF) ||
          (r >= 0x2600 && r <= 0x27BF) ||
          r == 0xFE0F ||
          r == 0x200D;
      if (!emoji) b.writeCharCode(r);
    }
    s = b.toString().replaceAll(_space, ' ').replaceAll(_blankLines, '\n');
    s = s.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).join('\n');
    if (s.length <= maxChars) return s.trim();
    final cut = s.substring(0, maxChars);
    var end = -1;
    for (final mark in const ['।', '.', '?', '!', '\n']) {
      final i = cut.lastIndexOf(mark);
      if (i > end) end = i;
    }
    return (end > maxChars ~/ 2 ? cut.substring(0, end + 1) : cut).trim();
  }

  /// Whether spoken replies are on (Settings -> Voice "Spoken replies").
  static Future<bool> spokenRepliesOn() async {
    try {
      return await Settings.getBool(VaWake.ttsKey, true);
    } catch (_) {
      return true;
    }
  }

  static bool _noVoiceShown = false;

  @visibleForTesting
  static void debugReset() => _noVoiceShown = false;

  /// Shows the honest message for a [speak] result (nothing for 'ok' etc.).
  /// The "no Bangla voice" hint is shown once per app run.
  static void explain(BuildContext context, String? result) {
    if (!context.mounted) return;
    final t = AppLocalizations.of(context);
    final m = ScaffoldMessenger.maybeOf(context);
    if (m == null) return;
    if (result == 'no_voice') {
      if (_noVoiceShown) return;
      _noVoiceShown = true;
      m.clearSnackBars();
      m.showSnackBar(SnackBar(
        content: Text(t.vaNoTtsVoice),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
            label: t.vaInstall, onPressed: () => VaNative.openTtsSettings()),
      ));
    } else if (result == 'no_engine' || result == null) {
      m.clearSnackBars();
      m.showSnackBar(SnackBar(
        content: Text(t.aivTtsNoEngine),
        duration: const Duration(seconds: 8),
      ));
    }
  }
}
