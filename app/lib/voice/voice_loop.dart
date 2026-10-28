import 'dart:async';

import 'package:flutter/foundation.dart';

enum LoopPhase { off, listening, thinking, speaking }

/// aivoice: the hands-free "voice conversation" loop of the AI chat
/// (ChatGPT Voice / Gemini Live style, without new native code):
///
///   listen -> (speech ends) send -> answer arrives -> read it aloud -> listen
///
/// The UI supplies the three steps, so this class is a pure, testable state
/// machine:
///   * [hear]  starts the mic and completes with what was said when the
///             recogniser stops ('' = heard nothing, null = mic unavailable),
///   * [ask]   sends the text and completes with the answer (null = failed),
///   * [say]   reads the answer aloud and completes when it has finished.
///
/// It ends on its own after [maxSilences] empty listens in a row, when the mic
/// is unavailable, or when an answer fails; [stop] ends it at once (End button,
/// leaving the screen, the app going to the background). It NEVER acts outside
/// the app by itself: the answer path is the normal chat send, and phone
/// actions there still ask first.
class VoiceLoop extends ChangeNotifier {
  VoiceLoop({
    required this.hear,
    required this.ask,
    required this.say,
    required this.cancel,
    this.maxSilences = 2,
  });

  final Future<String?> Function() hear;
  final Future<String?> Function(String said) ask;
  final Future<void> Function(String answer) say;

  /// Stops the mic, the voice and any reply in flight.
  final Future<void> Function() cancel;
  final int maxSilences;

  LoopPhase phase = LoopPhase.off;

  /// Why the last loop ended: 'user' | 'silence' | 'error' | 'mic' | null.
  String? endReason;

  /// Completed question/answer rounds in the current loop.
  int turns = 0;

  int _run = 0;
  bool _disposed = false;

  bool get active => phase != LoopPhase.off;

  void _set(LoopPhase p) {
    phase = p;
    if (!_disposed) notifyListeners();
  }

  /// Starts the loop (no-op while already running).
  Future<void> start() async {
    if (active) return;
    final run = ++_run;
    endReason = null;
    turns = 0;
    var silences = 0;
    while (run == _run) {
      _set(LoopPhase.listening);
      String? said;
      try {
        said = await hear();
      } catch (_) {
        said = null;
      }
      if (run != _run) return;
      if (said == null) return _end(run, 'mic');
      if (said.trim().isEmpty) {
        silences++;
        if (silences >= maxSilences) return _end(run, 'silence');
        continue;
      }
      silences = 0;
      _set(LoopPhase.thinking);
      String? answer;
      try {
        answer = await ask(said.trim());
      } catch (_) {
        answer = null;
      }
      if (run != _run) return;
      if (answer == null) return _end(run, 'error');
      _set(LoopPhase.speaking);
      try {
        await say(answer);
      } catch (_) {}
      if (run != _run) return;
      turns++;
    }
  }

  void _end(int run, String reason) {
    if (run != _run) return;
    _run++;
    endReason = reason;
    _set(LoopPhase.off);
  }

  /// Ends the loop now (End button / leaving / background).
  Future<void> stop() async {
    if (!active) return;
    _run++;
    endReason = 'user';
    _set(LoopPhase.off);
    try {
      await cancel();
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposed = true;
    if (active) {
      _run++;
      phase = LoopPhase.off;
      try {
        cancel();
      } catch (_) {}
    }
    super.dispose();
  }
}
