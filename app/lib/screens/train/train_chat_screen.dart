import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../train/train_api.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/notif_models.dart' show notifLocalizeDigits;

/// train: chat for passengers of the SAME train on the SAME date.
///  * nickname only — the server never sends a name, phone or user id, so
///    there is nothing to open: no profile anywhere;
///  * "Add to My Circle" sends a REQUEST; the other person accepts or not;
///  * report / block on every message; rate limits on the server;
///  * deleted after the trip;
///  * emergency words show 999 and the rail hotline 131 (one tap opens the
///    dialer — never auto-dial). No ads on this screen.
class TrainChatScreen extends StatefulWidget {
  final String no, date, title;
  const TrainChatScreen({super.key, required this.no, required this.date, required this.title});

  @override
  State<TrainChatScreen> createState() => _TrainChatScreenState();
}

class _TrainChatScreenState extends State<TrainChatScreen> {
  ApiClient get _api => context.read<AppState>().api;
  final _nick = TextEditingController();
  final _text = TextEditingController();
  Map<String, dynamic>? _me;
  final List<Map<String, dynamic>> _msgs = [];
  List<Map<String, dynamic>> _reqs = const [];
  bool _loading = true, _failed = false, _sending = false;
  bool _emergency = false;
  String? _error;
  Timer? _poll;
  List<String> _bnWords = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    unawaited(rootBundle
        .loadString('assets/train/emergency_words.json')
        .then((r) => _bnWords = parseEmergencyWords(r))
        .catchError((_) => _bnWords));
    _poll = Timer.periodic(const Duration(seconds: 8), (_) => _load(quiet: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    _nick.dispose();
    _text.dispose();
    super.dispose();
  }

  int get _last => _msgs.isEmpty ? 0 : (_msgs.last['id'] as num).toInt();

  Future<void> _load({bool quiet = false, bool full = false}) async {
    try {
      final r = await _api.trainChat(widget.no, widget.date, after: full ? 0 : _last);
      if (!mounted) return;
      setState(() {
        _me = r['me'] is Map ? Map<String, dynamic>.from(r['me'] as Map) : null;
        if (full) _msgs.clear();
        final seen = {for (final m in _msgs) m['id']};
        for (final m in (r['messages'] as List? ?? const [])) {
          final mm = Map<String, dynamic>.from(m as Map);
          if (seen.add(mm['id'])) _msgs.add(mm);
        }
        _reqs = [for (final x in (r['circle_requests'] as List? ?? const [])) Map<String, dynamic>.from(x as Map)];
        _emergency = _emergency || _msgs.any((m) => m['emergency'] == true);
        _loading = false;
        _failed = false;
      });
    } catch (_) {
      if (!mounted || quiet) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  String _reason(AppLocalizations t, Object e) {
    final s = '$e';
    if (s.contains('rate_limited')) return t.trChatSlowDown;
    if (s.contains('nickname')) return t.trNickRule;
    if (s.contains('trip_over')) return t.trChatOver;
    return t.trLoadFailed;
  }

  Future<void> _join() async {
    final t = AppLocalizations.of(context);
    try {
      await _api.trainChatJoin(widget.no, widget.date, _nick.text.trim());
      await _load(full: true);
    } catch (e) {
      if (mounted) setState(() => _error = _reason(t, e));
    }
  }

  Future<void> _send() async {
    final t = AppLocalizations.of(context);
    final text = _text.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    final local = trainIsEmergency(text, _bnWords);
    try {
      final r = await _api.trainChatSay(widget.no, widget.date, text);
      _text.clear();
      if (r['emergency'] == true || local) setState(() => _emergency = true);
      await _load(quiet: true);
    } catch (e) {
      if (local) setState(() => _emergency = true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_reason(t, e))));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _msgMenu(Map<String, dynamic> m) async {
    final t = AppLocalizations.of(context);
    final pick = await showAppSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          leading: const Icon(Icons.person_add_alt_rounded),
          title: Text(t.trAddCircle),
          subtitle: Text(t.trAddCircleSub),
          onTap: () => Navigator.pop(ctx, 'circle'),
        ),
        ListTile(
          leading: const Icon(Icons.flag_rounded),
          title: Text(t.trReport),
          onTap: () => Navigator.pop(ctx, 'report'),
        ),
        ListTile(
          leading: const Icon(Icons.block_rounded),
          title: Text(t.trBlock),
          subtitle: Text(t.trBlockSub),
          onTap: () => Navigator.pop(ctx, 'block'),
        ),
      ]),
    );
    if (pick == null || !mounted) return;
    try {
      await _api.trainMsgAction((m['id'] as num).toInt(), pick,
          reason: pick == 'report' ? 'other' : null);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(pick == 'circle'
              ? t.trRequestSent
              : (pick == 'block' ? t.trBlocked : t.trReported))));
      if (pick == 'block') await _load(full: true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_reason(t, e))));
      }
    }
  }

  Future<void> _act(Map<String, dynamic> r, String action) async {
    try {
      await _api.trainRequestAct((r['id'] as num).toInt(), action);
    } catch (_) {
      // best-effort: the list refreshes below
    }
    await _load(quiet: true);
  }

  Future<void> _leave() async {
    try {
      await _api.trainChatLeave(widget.no, widget.date);
    } catch (_) {
      // best-effort: the room is deleted after the trip anyway
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(notifLocalizeDigits(context, '${widget.title} · ${t.trChat}')),
        actions: [
          if (_me != null)
            IconButton(
                tooltip: t.trLeave, icon: const Icon(Icons.logout_rounded), onPressed: _leave),
        ],
      ),
      body: SafeArea(top: false, child: _body(t)),
    );
  }

  Widget _hotlines(AppLocalizations t) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, 0),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.trEmergencyTitle,
            style: AType.titleSmall.copyWith(color: cs.onErrorContainer, fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.sm),
        Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
          FilledButton.icon(
            style: FilledButton.styleFrom(
                minimumSize: const Size(48, 48), backgroundColor: cs.error, foregroundColor: cs.onError),
            icon: const Icon(Icons.call_rounded),
            label: Text(notifLocalizeDigits(context, t.trCall999)),
            onPressed: () => launchUrl(trainTelUri('999')),
          ),
          FilledButton.tonalIcon(
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            icon: const Icon(Icons.train_rounded),
            label: Text(notifLocalizeDigits(context, t.trCall131)),
            onPressed: () => launchUrl(trainTelUri('131')),
          ),
        ]),
      ]),
    );
  }

  Widget _body(AppLocalizations t) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_failed) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(t.trLoadFailed, textAlign: TextAlign.center, style: AType.bodyLarge),
            const SizedBox(height: Gap.md),
            FilledButton.icon(
                onPressed: () => _load(full: true),
                icon: const Icon(Icons.refresh_rounded),
                label: Text(t.trRetry)),
          ]),
        ),
      );
    }
    if (_me == null) {
      return ListView(
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
        children: [
          Text(t.trChatJoinTitle, style: AType.titleLarge),
          const SizedBox(height: Gap.sm),
          Text(t.trChatRules, style: AType.bodyMedium),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _nick,
            maxLength: 20,
            decoration: InputDecoration(
                labelText: t.trNickname,
                helperText: t.trNickRule,
                errorText: _error,
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.sm),
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            icon: const Icon(Icons.forum_rounded),
            label: Text(t.trChatJoin),
            onPressed: _join,
          ),
          const SizedBox(height: Gap.lg),
          _hotlines(t),
        ],
      );
    }
    return Column(children: [
      if (_emergency) _hotlines(t),
      for (final r in _reqs)
        Card(
          margin: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, 0),
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.trRequestFrom('${r['nick']}'), style: AType.bodyMedium),
              Text(t.trRequestNote, style: AType.bodySmall),
              const SizedBox(height: Gap.sm),
              Wrap(spacing: Gap.sm, children: [
                FilledButton(
                    style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                    onPressed: () => _act(r, 'accept'),
                    child: Text(t.trAccept)),
                OutlinedButton(
                    style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                    onPressed: () => _act(r, 'decline'),
                    child: Text(t.trDecline)),
              ]),
            ]),
          ),
        ),
      Expanded(
        child: _msgs.isEmpty
            ? Center(
                child: Padding(
                padding: const EdgeInsets.all(Gap.lg),
                child: Text(t.trChatEmpty, textAlign: TextAlign.center, style: AType.bodyMedium),
              ))
            : ListView.builder(
                padding: const EdgeInsets.all(Gap.md),
                itemCount: _msgs.length,
                itemBuilder: (_, i) => _bubble(t, _msgs[i]),
              ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, Gap.md),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: _text,
              minLines: 1,
              maxLines: 4,
              maxLength: 500,
              decoration: InputDecoration(
                  hintText: t.trChatHint, counterText: '', border: const OutlineInputBorder()),
            ),
          ),
          const SizedBox(width: Gap.sm),
          IconButton.filled(
            tooltip: t.trSend,
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            icon: const Icon(Icons.send_rounded),
            onPressed: _sending ? null : _send,
          ),
        ]),
      ),
    ]);
  }

  Widget _bubble(AppLocalizations t, Map<String, dynamic> m) {
    final cs = Theme.of(context).colorScheme;
    final mine = m['mine'] == true;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Semantics(
        button: !mine,
        hint: mine ? null : t.trMsgMenuHint,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onLongPress: mine ? null : () => _msgMenu(m),
          onTap: mine ? null : () => _msgMenu(m),
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            margin: const EdgeInsets.symmetric(vertical: Gap.xs),
            padding: const EdgeInsets.all(Gap.md),
            decoration: BoxDecoration(
              color: m['emergency'] == true
                  ? cs.errorContainer
                  : (mine ? cs.primaryContainer : cs.surfaceContainerHighest),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(mine ? t.trYou : '${m['nick']}',
                  style: AType.labelMedium.copyWith(fontWeight: FontWeight.w700)),
              Text('${m['text']}', style: AType.bodyMedium),
            ]),
          ),
        ),
      ),
    );
  }
}
