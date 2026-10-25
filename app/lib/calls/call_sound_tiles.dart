import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_localizations.dart';
import 'call_native.dart';
import 'call_sound_prefs.dart';
import 'tone_generator.dart';
import 'call_log.dart';

/// Settings → Calls "Sounds" rows (c2-calls): ringtone + Assisto melody.
/// [SoundPickTile] with [SoundPickKind.message] is reused by Settings →
/// Notifications (the ONE message-sound picker). The phone's own sound picker
/// (RingtoneManager) is used — Assisto ships no audio files.
class CallSoundsSection extends StatelessWidget {
  const CallSoundsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(t.c2SoundsHeader,
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(color: Theme.of(context).colorScheme.primary)),
        ),
        const SoundPickTile(kind: SoundPickKind.ringtone),
        const AssistoSignatureTile(),
        // The message sound is NOT here: its one picker lives in
        // Settings → Notifications (MsgDeviceNotifSection), same keys.
      ],
    );
  }
}

enum SoundPickKind { ringtone, message, contact }

/// One "pick a phone sound" row. [chatId] is required for [SoundPickKind.contact].
class SoundPickTile extends StatefulWidget {
  const SoundPickTile({super.key, required this.kind, this.chatId = ''});
  final SoundPickKind kind;
  final String chatId;

  @override
  State<SoundPickTile> createState() => _SoundPickTileState();
}

class _SoundPickTileState extends State<SoundPickTile> {
  String? _uri;
  String _title = '';
  bool _set = false; // a custom choice exists

  String get _uriKey => switch (widget.kind) {
        SoundPickKind.ringtone => CallSoundPrefs.callUri,
        SoundPickKind.message => CallSoundPrefs.msgUri,
        SoundPickKind.contact => CallSoundPrefs.contactUri(widget.chatId),
      };
  String get _titleKey => switch (widget.kind) {
        SoundPickKind.ringtone => CallSoundPrefs.callTitle,
        SoundPickKind.message => CallSoundPrefs.msgTitle,
        SoundPickKind.contact => CallSoundPrefs.contactTitle(widget.chatId),
      };

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final p = await SharedPreferences.getInstance();
      _set = p.containsKey(_uriKey);
      _uri = p.getString(_uriKey);
      _title = p.getString(_titleKey) ?? '';
    } catch (e) {
      callLog('call_sound_tiles#1', e);
    }
    if (mounted) setState(() {});
  }

  Future<void> _pick() async {
    final r = await CallNative.pickSound(
        notification: widget.kind == SoundPickKind.message, current: _uri);
    if (r == null) return; // cancelled or no native picker
    try {
      final p = await SharedPreferences.getInstance();
      final uri = r['uri'] as String?;
      await p.setString(_uriKey, uri ?? ''); // '' = silent (messages only)
      await p.setString(_titleKey, '${r['title'] ?? ''}');
    } catch (e) {
      callLog('call_sound_tiles#2', e);
    }
    await _load();
  }

  Future<void> _reset() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(_uriKey);
      await p.remove(_titleKey);
    } catch (e) {
      callLog('call_sound_tiles#3', e);
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final title = switch (widget.kind) {
      SoundPickKind.ringtone => t.c2SoundRingtone,
      SoundPickKind.message => t.c2SoundMessage,
      SoundPickKind.contact => t.c2SoundContactRingtone,
    };
    final String value;
    if (!_set) {
      value = widget.kind == SoundPickKind.contact
          ? t.c2SoundSameAsDefault
          : t.c2SoundPhoneDefault;
    } else if ((_uri ?? '').isEmpty) {
      value = t.c2SoundSilent;
    } else {
      value = _title.isNotEmpty ? _title : t.c2SoundCustom;
    }
    return ListTile(
      key: Key('sound-${widget.kind.name}'),
      leading: Icon(widget.kind == SoundPickKind.message
          ? Icons.notifications_active_rounded
          : Icons.music_note_rounded),
      title: Text(title),
      subtitle: Text(value, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: _set
          ? IconButton(
              tooltip: t.c2SoundReset,
              icon: const Icon(Icons.restart_alt_rounded),
              onPressed: _reset,
            )
          : const Icon(Icons.chevron_right_rounded),
      onTap: _pick,
    );
  }
}

/// Optional ORIGINAL "Assisto" melody (synthesised in code). Turning it on
/// installs it as a phone ringtone (Android 10+) so the locked-screen ring
/// uses it too; where that isn't possible we say so and stay on the phone's
/// ringtone.
class AssistoSignatureTile extends StatefulWidget {
  const AssistoSignatureTile({super.key});

  @override
  State<AssistoSignatureTile> createState() => _AssistoSignatureTileState();
}

class _AssistoSignatureTileState extends State<AssistoSignatureTile> {
  bool _on = false;
  bool _busy = false;
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    unawaited(() async {
      try {
        final p = await SharedPreferences.getInstance();
        _on = p.getBool(CallSoundPrefs.signature) == true;
      } catch (e) {
        callLog('call_sound_tiles#4', e);
      }
      if (mounted) setState(() {});
    }());
  }

  @override
  void dispose() {
    if (_playing) unawaited(CallNative.stopTone());
    super.dispose();
  }

  Future<void> _toggle(bool v) async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _busy = true);
    try {
      final p = await SharedPreferences.getInstance();
      if (v) {
        var uri = p.getString(CallSoundPrefs.signatureUri);
        if (uri == null || uri.isEmpty) {
          uri = await CallNative.installRingtone(
              ToneGenerator.wav(ToneGenerator.signature()), 'Assisto');
        }
        if (uri == null || uri.isEmpty) {
          messenger?.showSnackBar(
              SnackBar(content: Text(t.c2SoundSignatureUnsupported)));
          v = false;
        } else {
          await p.setString(CallSoundPrefs.signatureUri, uri);
        }
      }
      await p.setBool(CallSoundPrefs.signature, v);
      _on = v;
    } catch (e) {
      callLog('call_sound_tiles#5', e);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _preview() async {
    if (_playing) {
      await CallNative.stopTone();
      if (mounted) setState(() => _playing = false);
      return;
    }
    final tone = ToneGenerator.signature();
    final ok = await CallNative.playTone(
        ToneSpec(tone.pcm, tone.sampleRate, loop: false));
    if (!ok || !mounted) return;
    setState(() => _playing = true);
    await Future<void>.delayed(tone.duration);
    if (mounted) setState(() => _playing = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return SwitchListTile(
      key: const Key('sound-signature'),
      secondary: IconButton(
        tooltip: t.c2SoundPreview,
        icon: Icon(
            _playing ? Icons.stop_circle_rounded : Icons.play_circle_outline_rounded),
        onPressed: _preview,
      ),
      title: Text(t.c2SoundSignature),
      subtitle: Text(t.c2SoundSignatureSub),
      value: _on,
      onChanged: _busy ? null : _toggle,
    );
  }
}
