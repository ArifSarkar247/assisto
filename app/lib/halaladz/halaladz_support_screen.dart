import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../config.dart';
import '../l10n/app_localizations.dart';
import '../messaging/media/voice_recorder_sheet.dart' show showVoiceRecorder;
import '../state.dart';
import '../widgets/local_counter.dart';
import '../widgets/local_digits.dart';
import 'halaladz_api.dart';

/// halaladz — "HalalAdz support": the person writes to the HalalAdz team
/// (text, a photo, or a voice note). The owner answers from Owner Admin ->
/// HalalAdz support (unread counts, quick replies, resolved). Replies arrive
/// here + as a notification. Photos / voice notes are stored privately on the
/// Assisto server and only ever served through short-lived signed links.
class HalalAdzSupportScreen extends StatefulWidget {
  const HalalAdzSupportScreen({super.key, this.api});

  /// Tests inject a client; the app uses AppState.api.
  final ApiClient? api;

  @override
  State<HalalAdzSupportScreen> createState() => _HalalAdzSupportScreenState();
}

class _HalalAdzSupportScreenState extends State<HalalAdzSupportScreen> {
  final _text = TextEditingController();
  final _scroll = ScrollController();
  List<Map<String, dynamic>> _msgs = const [];
  bool _resolved = false;
  bool _loading = true;
  bool _error = false;
  bool _sending = false;

  ApiClient get _api => widget.api ?? context.read<AppState>().api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final j = await _api.hzSupport();
      if (!mounted) return;
      setState(() {
        _msgs = [
          for (final m in (j['messages'] as List? ?? const []))
            if (m is Map) Map<String, dynamic>.from(m)
        ];
        _resolved = (j['ticket'] as Map?)?['resolved'] == true;
        _loading = false;
        _error = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = true;
      });
    }
  }

  void _toast(String s) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  Future<void> _send({String? photoB64, String? voiceB64, int durationMs = 0}) async {
    final t = AppLocalizations.of(context);
    final text = photoB64 == null && voiceB64 == null ? _text.text.trim() : '';
    if (text.isEmpty && photoB64 == null && voiceB64 == null) return;
    setState(() => _sending = true);
    try {
      final r = await _api.hzSupportSend(
          text: text, photoB64: photoB64, voiceB64: voiceB64, durationMs: durationMs);
      if (!mounted) return;
      if (r['_status'] == 201) {
        if (text.isNotEmpty) _text.clear();
        await _load();
      } else {
        final m = '${r['message'] ?? ''}';
        _toast(m.isNotEmpty ? m : t.hzSupportFailed);
      }
    } catch (_) {
      if (mounted) _toast(t.hzSupportFailed);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _photo() async {
    try {
      final x = await ImagePicker().pickImage(
          source: ImageSource.gallery, maxWidth: 1600, imageQuality: 80);
      if (x == null) return;
      final bytes = await x.readAsBytes();
      await _send(photoB64: base64Encode(bytes));
    } catch (_) {
      if (mounted) _toast(AppLocalizations.of(context).hzSupportFailed);
    }
  }

  Future<void> _voice() async {
    try {
      final d = await showVoiceRecorder(context, allowViewOnce: false);
      if (d == null) return;
      final bytes = await File(d.path).readAsBytes();
      await _send(voiceB64: base64Encode(bytes), durationMs: d.durationMs ?? 0);
    } catch (_) {
      if (mounted) _toast(AppLocalizations.of(context).hzSupportFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.hzSupportTitle)),
      body: SafeArea(
        child: Column(children: [
          Expanded(child: _list(t)),
          if (_resolved)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(t.hzSupportResolved,
                  key: const Key('hz-resolved'),
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          _composer(t),
        ]),
      ),
    );
  }

  Widget _list(AppLocalizations t) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(t.hzErrNetwork, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(160, 48)),
              onPressed: () {
                setState(() => _loading = true);
                _load();
              },
              child: Text(t.hzRetry)),
        ]),
      );
    }
    if (_msgs.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.support_agent_rounded, size: 56),
            const SizedBox(height: 12),
            Text(t.hzSupportEmpty,
                key: const Key('hz-support-empty'), textAlign: TextAlign.center),
          ]),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      reverse: true,
      padding: const EdgeInsets.all(12),
      itemCount: _msgs.length,
      itemBuilder: (c, i) => _bubble(t, _msgs[_msgs.length - 1 - i]),
    );
  }

  Widget _bubble(AppLocalizations t, Map<String, dynamic> m) {
    final mine = m['sender'] != 'owner';
    final scheme = Theme.of(context).colorScheme;
    final kind = '${m['kind'] ?? 'text'}';
    final url = '${m['media_url'] ?? ''}';
    final abs = url.startsWith('/') ? '${AppConfig.apiBase}$url' : url;
    final text = '${m['text'] ?? ''}';
    return Align(
      alignment: mine ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.8),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: mine ? scheme.primaryContainer : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(mine ? t.hzSupportYou : t.hzSupportTeam,
                style: Theme.of(context).textTheme.labelSmall),
            if (kind == 'photo' && abs.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.network(abs,
                      height: 180,
                      fit: BoxFit.cover,
                      semanticLabel: t.hzSupportPhotoMsg,
                      errorBuilder: (_, __, ___) => Text(t.hzSupportPhotoMsg)),
                ),
              ),
            if (kind == 'voice')
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.mic_rounded, size: 18),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(t.hzSupportVoiceSent(ld(context,
                        (((m['duration_ms'] as num?) ?? 0) / 1000).round()))),
                  ),
                ]),
              ),
            if (text.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(text),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _composer(AppLocalizations t) => Material(
        elevation: 2,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
          child: Row(children: [
            IconButton(
              key: const Key('hz-photo'),
              tooltip: t.hzSupportPhoto,
              onPressed: _sending ? null : _photo,
              icon: const Icon(Icons.photo_rounded),
            ),
            IconButton(
              key: const Key('hz-voice'),
              tooltip: t.hzSupportVoice,
              onPressed: _sending ? null : _voice,
              icon: const Icon(Icons.mic_rounded),
            ),
            Expanded(
              child: TextField(
                key: const Key('hz-text'),
                controller: _text,
                minLines: 1,
                maxLines: 5,
                maxLength: 4000,
                buildCounter: localCounter,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: t.hzSupportHint,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            IconButton(
              key: const Key('hz-send'),
              tooltip: t.hzSupportSend,
              onPressed: _sending ? null : () => _send(),
              icon: _sending
                  ? const SizedBox(
                      width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send_rounded),
            ),
          ]),
        ),
      );
}
