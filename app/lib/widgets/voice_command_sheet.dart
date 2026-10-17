// Advanced voice-command sheet (SPEC v2.1 §21).
//
// A bottom sheet that: asks mic permission (reusing the permission-reason
// dialog), shows a clear LISTENING state with an animated pulse, transcribes
// speech on-device via `speech_to_text`, maps the transcript to an intent
// (VoiceMapper → same routes as typed chat), and shows a CONFIRM step naming
// exactly what it understood before any action runs.
//
// Honesty: speech-to-text is DEVICE/engine gated. When no engine is available
// (`SpeechToText.initialize()` returns false) the sheet shows an explicit
// "voice not available on this device" state and NEVER fabricates a transcript.
// We only ever act on words the device actually recognised.
//
// All user-facing strings come from AppLocalizations (bilingual). No Bangla
// literals live in this file (language gate).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import 'permission_reason.dart';
import 'voice_intent.dart';

enum _Phase { idle, listening, understood, unavailable, error }

/// Opens the voice-command sheet. Returns the confirmed transcript (so the
/// caller can run it through its full chat pipeline — backend route + agent),
/// or null if the user cancelled / nothing was confirmed.
Future<String?> showVoiceCommandSheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _VoiceCommandSheet(),
  );
}

class _VoiceCommandSheet extends StatefulWidget {
  const _VoiceCommandSheet();
  @override
  State<_VoiceCommandSheet> createState() => _VoiceCommandSheetState();
}

class _VoiceCommandSheetState extends State<_VoiceCommandSheet>
    with SingleTickerProviderStateMixin {
  final SpeechToText _speech = SpeechToText();
  late final AnimationController _pulse;
  _Phase _phase = _Phase.idle;
  bool _ready = false;
  String _transcript = '';
  VoiceCommand? _cmd;

  AppLocalizations get t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1100))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _speech.cancel();
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _startListening() async {
    HapticFeedback.selectionClick();
    if (!_ready) {
      final okReason = await showPermissionReason(context, PermKind.mic);
      if (!okReason || !mounted) return;
      _ready = await _speech.initialize(
        onStatus: (s) {
          if ((s == 'done' || s == 'notListening') &&
              mounted &&
              _phase == _Phase.listening) {
            _finishListening();
          }
        },
        onError: (_) {
          if (mounted) setState(() => _phase = _Phase.error);
        },
      );
    }
    // HONEST key/device gate: no engine → explicit unavailable state, never a
    // fabricated transcript.
    if (!_ready) {
      if (mounted) setState(() => _phase = _Phase.unavailable);
      return;
    }
    setState(() {
      _phase = _Phase.listening;
      _transcript = '';
      _cmd = null;
    });
    // Recognise in the app's ACTIVE language. Without this the plugin defaults
    // to the DEVICE locale, so a Bangla speaker on a non-Bengali device is not
    // transcribed. 'bn_BD' is passed when the app language is Bengali; if that
    // locale pack isn't installed the plugin safely falls back to the default.
    final localeId = t.localeName.startsWith('bn') ? 'bn_BD' : 'en_US';
    await _speech.listen(
      onResult: (r) {
        if (mounted) setState(() => _transcript = r.recognizedWords);
      },
      listenOptions: SpeechListenOptions(localeId: localeId),
    );
  }

  void _finishListening() {
    _speech.stop();
    final text = _transcript.trim();
    if (text.isEmpty) {
      setState(() => _phase = _Phase.idle);
      return;
    }
    // On-device map (English fast-path). Bangla/Banglish maps to null here and
    // is handled by the backend when the caller sends the transcript on.
    final cmd = VoiceMapper.map(text);
    setState(() {
      _cmd = cmd;
      _phase = _Phase.understood;
    });
  }

  void _stopTap() {
    if (_phase == _Phase.listening) _finishListening();
  }

  void _confirm() {
    HapticFeedback.mediumImpact();
    Navigator.pop(context, _transcript.trim());
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        left: Gap.xl,
        right: Gap.xl,
        top: Gap.md,
        bottom: MediaQuery.of(context).viewInsets.bottom + Gap.xl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(t.voiceTitle,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: Gap.xs),
          Text(
            switch (_phase) {
              _Phase.listening => t.voiceListeningHint,
              _Phase.understood => t.voiceUnderstoodHint,
              _Phase.unavailable => t.voiceUnavailableBody,
              _Phase.error => t.voiceErrorBody,
              _Phase.idle => t.voiceTapToSpeak,
            },
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
          ),
          const SizedBox(height: Gap.xl),
          _body(scheme),
          const SizedBox(height: Gap.xl),
          _actions(scheme),
        ],
      ),
    );
  }

  Widget _body(ColorScheme scheme) {
    switch (_phase) {
      case _Phase.unavailable:
        return _iconState(Icons.mic_off_outlined, scheme.error);
      case _Phase.error:
        return _iconState(Icons.error_outline, scheme.error);
      case _Phase.understood:
        return _understood(scheme);
      case _Phase.listening:
      case _Phase.idle:
        return _micOrb(scheme);
    }
  }

  Widget _iconState(IconData icon, Color color) => Center(
        child: Icon(icon, size: 72, color: color),
      );

  Widget _micOrb(ColorScheme scheme) {
    final listening = _phase == _Phase.listening;
    return Column(children: [
      Semantics(
        button: true,
        label: listening ? t.voiceStop : t.voiceTapToSpeak,
        child: GestureDetector(
          onTap: listening ? _stopTap : _startListening,
          child: AnimatedBuilder(
            animation: _pulse,
            builder: (_, child) {
              final scale = listening ? 1 + _pulse.value * 0.12 : 1.0;
              return Transform.scale(scale: scale, child: child);
            },
            child: Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  colors: [Brand.cyan, Brand.blue, Brand.purple],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                boxShadow: listening
                    ? [
                        BoxShadow(
                            color: Brand.blue.withValues(alpha: 0.45),
                            blurRadius: 28,
                            spreadRadius: 4)
                      ]
                    : null,
              ),
              child: Icon(listening ? Icons.graphic_eq : Icons.mic,
                  size: 44, color: Colors.white),
            ),
          ),
        ),
      ),
      if (listening && _transcript.isNotEmpty) ...[
        const SizedBox(height: Gap.lg),
        Text(_transcript,
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
      ],
    ]);
  }

  Widget _understood(ColorScheme scheme) {
    final cmd = _cmd;
    final label = cmd == null ? t.voiceIntentSend : _intentLabel(cmd.intent);
    return Container(
      padding: const EdgeInsets.all(Gap.lg),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.35)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.check_circle_outline, size: 18, color: scheme.primary),
          const SizedBox(width: Gap.sm),
          Text(t.voiceUnderstoodLabel,
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurfaceVariant,
                  fontSize: 13)),
        ]),
        const SizedBox(height: Gap.sm),
        Text('"$_transcript"',
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        const SizedBox(height: Gap.sm),
        Row(children: [
          Chip(
            visualDensity: VisualDensity.compact,
            avatar: Icon(_intentIcon(cmd?.intent), size: 16),
            label: Text(label),
          ),
        ]),
      ]),
    );
  }

  String _intentLabel(VoiceIntent i) => switch (i) {
        VoiceIntent.open => t.voiceIntentOpen,
        VoiceIntent.reminder => t.voiceIntentReminder,
        VoiceIntent.expense => t.voiceIntentExpense,
        VoiceIntent.call => t.voiceIntentCall,
        VoiceIntent.sos => t.voiceIntentSos,
        VoiceIntent.unknown => t.voiceIntentSend,
      };

  IconData _intentIcon(VoiceIntent? i) => switch (i) {
        VoiceIntent.open => Icons.open_in_new,
        VoiceIntent.reminder => Icons.alarm,
        VoiceIntent.expense => Icons.receipt_long_outlined,
        VoiceIntent.call => Icons.call,
        VoiceIntent.sos => Icons.emergency_outlined,
        _ => Icons.send,
      };

  Widget _actions(ColorScheme scheme) {
    switch (_phase) {
      case _Phase.idle:
        return TextButton(
            onPressed: () => Navigator.pop(context), child: Text(t.cancel));
      case _Phase.listening:
        return FilledButton.icon(
          onPressed: _stopTap,
          icon: const Icon(Icons.stop_circle_outlined),
          label: Text(t.voiceStop),
        );
      case _Phase.understood:
        return Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _startListening,
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(t.retry),
            ),
          ),
          const SizedBox(width: Gap.md),
          Expanded(
            child: FilledButton.icon(
              onPressed: _confirm,
              icon: const Icon(Icons.check, size: 18),
              label: Text(t.voiceConfirm),
            ),
          ),
        ]);
      case _Phase.unavailable:
        return TextButton(
            onPressed: () => Navigator.pop(context), child: Text(t.cancel));
      case _Phase.error:
        return Row(children: [
          Expanded(
            child: OutlinedButton(
                onPressed: () => Navigator.pop(context), child: Text(t.cancel)),
          ),
          const SizedBox(width: Gap.md),
          Expanded(
            child: FilledButton.icon(
              onPressed: _startListening,
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(t.retry),
            ),
          ),
        ]);
    }
  }
}
