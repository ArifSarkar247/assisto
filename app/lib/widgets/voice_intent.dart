// On-device voice-command intent mapping (English/ASCII fast-path).
//
// Mirrors the deterministic logic of `backend/core/logic/voice_commands.py` and
// reuses the English route vocabulary already in `ChatNav` so a spoken "open
// money" lands on the exact same screen as typed chat — with ZERO latency and
// no network. Bangla / Banglish utterances intentionally fall through to the
// backend (the language gate forbids Bangla literals in Dart); the server's
// `screen_synonyms` + `voice_commands` understand those.
//
// This file holds routing/trigger DATA + pure functions only — no user-facing
// strings (no AppLocalizations) and, per the gate, no Bangla literals.

import 'chatnav.dart';

/// What the app should do with a spoken utterance.
enum VoiceIntent { open, reminder, expense, call, sos, unknown }

/// A confirmable voice command. `confirm` is always true — the UI shows what it
/// understood and waits for an explicit Confirm before acting.
class VoiceCommand {
  final VoiceIntent intent;
  final String? route; // canonical ChatNav route, or null
  final String title; // cleaned subject for display/confirmation
  final num? amount; // expense amount, if spoken
  final String? name; // call target, if spoken
  const VoiceCommand(this.intent, this.title,
      {this.route, this.amount, this.name});
  bool get confirm => true;
}

class VoiceMapper {
  VoiceMapper._();

  // Safety-first: SOS beats everything.
  static const _sos = ['sos', 'emergency', 'help me', 'save me', 'danger'];
  static const _call = ['call ', 'phone ', 'dial ', 'ring '];
  static const _reminder = [
    'remind me', 'set a reminder', 'set reminder', 'set an alarm', 'alarm',
  ];
  static const _expense = [
    'i spent', 'add expense', 'log expense', 'spent ', 'expense of',
  ];

  static bool _has(String low, List<String> words) =>
      words.any((w) => low.contains(w));

  static String _matched(String low, List<String> words) =>
      words.firstWhere((w) => low.contains(w), orElse: () => '');

  static String _strip(String text, String trigger) {
    if (trigger.isEmpty) return text.trim();
    final i = text.toLowerCase().indexOf(trigger);
    if (i < 0) return text.trim();
    final out = text.substring(0, i) + text.substring(i + trigger.length);
    return out.replaceAll(RegExp(r'^[\s,.\-]+|[\s,.\-]+$'), '').trim();
  }

  static num? _firstAmount(String text) {
    final m = RegExp(r'(\d[\d,]*(?:\.\d+)?)').firstMatch(text);
    if (m == null) return null;
    final raw = m.group(1)!.replaceAll(',', '');
    final v = num.tryParse(raw);
    if (v == null) return null;
    return v == v.toInt() ? v.toInt() : v;
  }

  /// Map a (device-produced) transcript to a confirmable command, or null when
  /// empty. ASCII/English only; returns null for text we can't map on-device so
  /// the caller can defer to the backend.
  static VoiceCommand? map(String? text) {
    if (text == null || text.trim().isEmpty) return null;
    final low = text.toLowerCase();

    if (_has(low, _sos)) {
      return VoiceCommand(VoiceIntent.sos, text.trim(), route: 'emergency');
    }
    if (_has(low, _call)) {
      final who = _strip(text, _matched(low, _call));
      return VoiceCommand(VoiceIntent.call, who.isEmpty ? text.trim() : who,
          route: 'circle', name: who.isEmpty ? null : who);
    }
    if (_has(low, _reminder)) {
      final body = _strip(text, _matched(low, _reminder));
      return VoiceCommand(
          VoiceIntent.reminder, body.isEmpty ? text.trim() : body,
          route: 'reminders');
    }
    if (_has(low, _expense)) {
      final body = _strip(text, _matched(low, _expense));
      return VoiceCommand(
          VoiceIntent.expense, body.isEmpty ? text.trim() : body,
          route: 'money', amount: _firstAmount(text));
    }
    // open/show a known screen (reuses ChatNav's English synonym map).
    final route = ChatNav.detectRoute(text);
    if (route != null) {
      return VoiceCommand(VoiceIntent.open, text.trim(), route: route);
    }
    // Couldn't map on-device — let the caller defer to the backend.
    return null;
  }
}
