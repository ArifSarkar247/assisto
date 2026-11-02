import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../blood_panel_api.dart';
import '../../l10n/app_localizations.dart';
import '../../m3_circle_api.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart';
import 'bp_common.dart';

/// blood (owner 2 Nov) — a private donor <-> seeker conversation. No phone
/// numbers are exchanged by the app (Call / SMS appear only when the donor
/// made the number public). My Circle: the seeker can ASK; only the donor
/// accepts or declines — then a normal My Circle request goes out and app
/// calls work. Block stops the conversation both ways.
class BloodThreadScreen extends StatefulWidget {
  const BloodThreadScreen({super.key, required this.threadId});
  final int threadId;

  @override
  State<BloodThreadScreen> createState() => _BloodThreadScreenState();
}

class _BloodThreadScreenState extends State<BloodThreadScreen> {
  ApiClient get _api => context.read<AppState>().api;
  final _ctrl = TextEditingController();
  bool _loading = true;
  bool _failed = false;
  bool _sending = false;
  Map<String, dynamic> _th = const {};
  List<Map<String, dynamic>> _msgs = const [];

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(() {
      if (mounted) setState(() {});
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await _api.bpThread(widget.threadId);
      if (!mounted) return;
      setState(() {
        _th = bpMap(r['thread']);
        _msgs = bpRows(r, 'messages');
        _loading = false;
        _failed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _send() async {
    final t = AppLocalizations.of(context);
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    setState(() => _sending = true);
    try {
      final r = await _api.bpSend(widget.threadId, text);
      if (!mounted) return;
      setState(() => _sending = false);
      if (r['ok'] == true) {
        _ctrl.clear();
        unawaited(_load());
      } else {
        _snack(bpReason(t, r['reason'] as String?));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _sending = false);
      _snack(t.bpErrGeneric);
    }
  }

  Future<void> _circle(String action) async {
    final t = AppLocalizations.of(context);
    try {
      final r = await _api.bpCircle(widget.threadId, action);
      if (!mounted) return;
      if (r['ok'] != true) {
        _snack(bpReason(t, r['reason'] as String?));
      } else if (action == 'accept' && r['circle_to_user_id'] is int) {
        // the donor's own My Circle request (existing limits); the seeker accepts
        try {
          await _api.m3SendRequest(toUserId: r['circle_to_user_id'] as int, relation: 'friend');
          if (mounted) _snack(t.bpCircleSent);
        } catch (_) {
          if (mounted) _snack(t.bpErrGeneric);
        }
      } else {
        _snack(action == 'ask' ? t.bpCircleAsked : t.bpSaved);
      }
    } catch (_) {
      if (mounted) _snack(t.bpErrGeneric);
    }
    unawaited(_load());
  }

  Future<void> _block() async {
    final t = AppLocalizations.of(context);
    final on = _th['blocked_by_me'] != true;
    if (on) {
      final yes = await showAppSheet<bool>(
        context: context,
        builder: (ctx) => Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.md),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(t.bpBlockTitle, style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: Gap.sm),
            Text(t.bpBlockBody),
            const SizedBox(height: Gap.lg),
            ConstrainedBox(constraints: const BoxConstraints(minHeight: 52),
              child: FilledButton(
                key: const ValueKey('bp-block-confirm'),
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(t.bpBlock),
              ),
            ),
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.bpCancel)),
          ]),
        ),
      );
      if (yes != true || !mounted) return;
    }
    try {
      await _api.bpBlock(widget.threadId, on);
    } catch (_) {
      if (mounted) _snack(t.bpErrGeneric);
    }
    unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final name = '${_th['other_name'] ?? ''}';
    return Scaffold(
      appBar: AppBar(
        title: Text(name.isEmpty ? t.bpMessages : name),
        actions: [
          if (!_loading && !_failed)
            PopupMenuButton<String>(
              key: const ValueKey('bp-thread-menu'),
              onSelected: (v) => v == 'block' ? _block() : null,
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'block',
                  child: Text(_th['blocked_by_me'] == true ? t.bpUnblock : t.bpBlock),
                ),
              ],
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _failed
              ? Center(child: BpError(onRetry: _load))
              : Column(children: [
                  _banner(context),
                  Expanded(child: _list(context)),
                  _composer(context),
                ]),
    );
  }

  Widget _banner(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    final side = '${_th['side']}';
    final ask = '${_th['circle_ask'] ?? ''}';
    final phone = _th['phone'] as String?;
    final children = <Widget>[];
    if (side == 'donor' && ask == 'asked') {
      children.add(Text(t.bpCircleAskDonor));
      children.add(Wrap(spacing: Gap.sm, children: [
        ConstrainedBox(constraints: const BoxConstraints(minHeight: 48),
          child: FilledButton(
            key: const ValueKey('bp-circle-accept'),
            onPressed: () => _circle('accept'),
            child: Text(t.bpCircleAccept),
          ),
        ),
        ConstrainedBox(constraints: const BoxConstraints(minHeight: 48),
          child: OutlinedButton(
            key: const ValueKey('bp-circle-decline'),
            onPressed: () => _circle('decline'),
            child: Text(t.bpCircleDecline),
          ),
        ),
      ]));
    } else if (side == 'seeker' && ask.isEmpty && _th['blocked'] != true) {
      children.add(Text(t.bpCallNote));
      children.add(Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 48),
          child: TextButton.icon(
            key: const ValueKey('bp-circle-ask'),
            onPressed: () => _circle('ask'),
            icon: const Icon(Icons.group_add_outlined),
            label: Text(t.bpCircleAsk),
          ),
        ),
      ));
    } else if (ask == 'asked') {
      children.add(Text(t.bpCircleWaiting));
    } else if (ask == 'accepted') {
      children.add(Text(t.bpCircleAccepted));
    } else if (ask == 'declined' && side == 'seeker') {
      children.add(Text(t.bpCircleDeclined));
    }
    if (phone != null && phone.isNotEmpty) {
      children.add(Wrap(spacing: Gap.sm, children: [
        ConstrainedBox(constraints: const BoxConstraints(minHeight: 48),
          child: OutlinedButton.icon(
            onPressed: () => bpLaunch(context, 'tel', phone),
            icon: const Icon(Icons.call_rounded),
            label: Text(t.bpCall),
          ),
        ),
        ConstrainedBox(constraints: const BoxConstraints(minHeight: 48),
          child: OutlinedButton.icon(
            onPressed: () => bpLaunch(context, 'sms', phone),
            icon: const Icon(Icons.sms_outlined),
            label: Text(t.bpSms),
          ),
        ),
      ]));
    }
    if (_th['blocked'] == true) {
      children.add(Text(_th['blocked_by_me'] == true ? t.bpBlockedByMe : t.bpErrBlocked,
          style: TextStyle(color: s.error)));
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      color: s.surfaceContainerHigh,
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.sm),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );
  }

  Widget _list(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    if (_msgs.isEmpty) {
      return Center(
        child: Padding(padding: const EdgeInsets.all(Gap.xl), child: Text(t.bpThreadEmpty, textAlign: TextAlign.center)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(Gap.md),
      itemCount: _msgs.length,
      itemBuilder: (_, i) {
        final m = _msgs[i];
        final mine = m['mine'] == true;
        return Align(
          alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * .78),
            margin: const EdgeInsets.only(bottom: Gap.sm),
            padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
            decoration: BoxDecoration(
              color: mine ? s.primaryContainer : s.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${m['text'] ?? ''}',
                  style: TextStyle(color: mine ? s.onPrimaryContainer : s.onSurface)),
              const SizedBox(height: Gap.xxs),
              Text(bpWhen(context, m['at'] as String?),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: mine ? s.onPrimaryContainer : s.onSurfaceVariant)),
            ]),
          ),
        );
      },
    );
  }

  Widget _composer(BuildContext context) {
    final t = AppLocalizations.of(context);
    final blocked = _th['blocked'] == true;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.sm, Gap.sm),
        child: Row(children: [
          Expanded(
            child: TextField(
              key: const ValueKey('bp-thread-field'),
              controller: _ctrl,
              enabled: !blocked,
              minLines: 1,
              maxLines: 4,
              maxLength: 600,
              decoration: InputDecoration(hintText: t.bpMsgLabel, counterText: '', border: const OutlineInputBorder()),
            ),
          ),
          IconButton(
            key: const ValueKey('bp-thread-send'),
            tooltip: t.bpSend,
            onPressed: blocked || _sending || _ctrl.text.trim().isEmpty ? null : _send,
            icon: const Icon(Icons.send_rounded),
          ),
        ]),
      ),
    );
  }
}
