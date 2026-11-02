import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../missing_alert_api.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart';
import 'ma_common.dart';

/// missing (owner 2 Nov) — one PRIVATE tip thread between a tipster and the
/// family. The family sees "Anonymous tipster #NNN" unless the tipster chose
/// to share their name (and number). Nobody else can read it; there are no
/// public comments anywhere.
class MissingThreadScreen extends StatefulWidget {
  const MissingThreadScreen({super.key, required this.threadId});
  final int threadId;

  @override
  State<MissingThreadScreen> createState() => _MissingThreadScreenState();
}

class _MissingThreadScreenState extends State<MissingThreadScreen> {
  ApiClient get _api => context.read<AppState>().api;
  final _text = TextEditingController();
  bool _loading = true;
  bool _failed = false;
  bool _busy = false;
  bool _family = false;
  String _alertState = '';
  Map<String, dynamic> _th = const {};

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
    unawaited(_load());
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final r = await _api.maThread(widget.threadId);
      if (!mounted) return;
      setState(() {
        _family = r['family'] == true;
        _alertState = '${r['alert_state'] ?? ''}';
        _th = (r['thread'] is Map) ? Map<String, dynamic>.from(r['thread'] as Map) : const {};
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  Future<void> _send() async {
    final t = AppLocalizations.of(context);
    final msg = _text.text.trim();
    if (msg.isEmpty) return;
    setState(() => _busy = true);
    try {
      final r = await _api.maReply(widget.threadId, msg);
      if (!mounted) return;
      setState(() => _busy = false);
      if (r['ok'] == true) {
        _text.clear();
        setState(() => _th = Map<String, dynamic>.from(r['thread'] as Map));
      } else {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(maReason(t, r['reason'] as String?))));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.maErrGeneric)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final who = _family ? '${_th['tipster'] ?? ''}' : t.maThreadFamily;
    return Scaffold(
      appBar: AppBar(title: Text(_loading ? t.maTipsTitle : who)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _failed
              ? Center(child: MaError(onRetry: _load))
              : Column(children: [
                  Expanded(child: _messages(context)),
                  _composer(context),
                ]),
    );
  }

  Widget _messages(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    final msgs = maRows(_th, 'messages');
    final phone = '${_th['tipster_phone'] ?? ''}';
    return ListView(
      padding: const EdgeInsets.all(Gap.lg),
      children: [
        Text(_family
            ? (_th['share_identity'] == true
                ? (phone.isEmpty ? t.maThreadShared : t.maThreadSharedPhone(phone))
                : t.maThreadAnon)
            : t.maThreadTipsterNote,
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: Gap.md),
        for (final m in msgs)
          Align(
            alignment: (m['by_family'] == true) == _family ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 520),
              margin: const EdgeInsets.only(bottom: Gap.sm),
              padding: const EdgeInsets.all(Gap.md),
              decoration: BoxDecoration(
                color: (m['by_family'] == true) == _family ? s.primaryContainer : s.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(Radii.md),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${m['text'] ?? ''}',
                    style: TextStyle(
                        color: (m['by_family'] == true) == _family ? s.onPrimaryContainer : s.onSurface)),
                if (m['point'] is Map)
                  Text(t.maThreadPoint, style: Theme.of(context).textTheme.bodySmall),
                Text(maAgo(context, m['at'] as String?), style: Theme.of(context).textTheme.bodySmall),
              ]),
            ),
          ),
      ],
    );
  }

  Widget _composer(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (_alertState != 'active' && !_family) {
      return Padding(
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
        child: Text(t.maThreadClosed),
      );
    }
    return Padding(
      padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.md)),
      child: Row(children: [
        Expanded(
          child: TextField(
            key: const ValueKey('ma-thread-text'),
            controller: _text,
            minLines: 1,
            maxLines: 4,
            maxLength: 600,
            decoration: InputDecoration(
              hintText: t.maThreadHint,
              counterText: '',
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(width: Gap.sm),
        IconButton.filled(
          key: const ValueKey('ma-thread-send'),
          tooltip: t.maTipSend,
          onPressed: _busy || _text.text.trim().isEmpty ? null : _send,
          icon: const Icon(Icons.send_rounded),
        ),
      ]),
    );
  }
}
