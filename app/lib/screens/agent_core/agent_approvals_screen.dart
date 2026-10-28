import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/offline_banner.dart';
import 'agent_core_push.dart';
import 'agent_core_source.dart';
import 'agent_core_widgets.dart';

/// agent-core WP-APP: the Approval inbox — every step the agent wants to do
/// that messages, posts, pays, books or deletes waits here for one tap.
/// Opened from the agent screen, the drawer route `agent_approvals`, or an
/// `agent_approval` push ([focusId] = that approval; [fromApproveAction] =
/// the user tapped "Approve" in the notification, so the card says to
/// confirm here — a notification never approves blind).
class AgentApprovalsScreen extends StatefulWidget {
  final AgentCoreSource? source;
  final int? focusId;
  final bool fromApproveAction;
  const AgentApprovalsScreen(
      {super.key, this.source, this.focusId, this.fromApproveAction = false});

  @override
  State<AgentApprovalsScreen> createState() => _AgentApprovalsScreenState();
}

class _AgentApprovalsScreenState extends State<AgentApprovalsScreen> {
  late final AgentCoreSource _src = widget.source ??
      ApiAgentCoreSource(Provider.of<AppState>(context, listen: false).api);
  List<AcApproval>? _items;
  String? _error;
  final Set<int> _busy = {};
  final Map<int, String> _done = {}; // id -> 'approve' | 'reject'

  @override
  void initState() {
    super.initState();
    AgentCorePush.approvalsChanged.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    AgentCorePush.approvalsChanged.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final j = await _src.approvals();
      if (!mounted) return;
      setState(() {
        _error = null;
        _items = [
          for (final a in (j['approvals'] as List? ?? const []))
            if (a is Map) AcApproval.fromJson(a),
        ];
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e is ApiException ? e.message : '');
    }
  }

  Future<void> _decide(AcApproval ap, String decision) async {
    if (_busy.contains(ap.id)) return;
    setState(() => _busy.add(ap.id));
    try {
      final j = await _src.decide(ap.id, decision);
      final st = ((j['approval'] as Map?)?['status'] ?? '').toString();
      if (!mounted) return;
      final t = AppLocalizations.of(context);
      setState(() => _done[ap.id] = st == 'approved'
          ? 'approve'
          : (st == 'rejected' ? 'reject' : 'gone'));
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(st == 'approved'
              ? t.acApApproved
              : (st == 'rejected' ? t.acApRejected : t.acApGone))));
      unawaited(AgentCorePush.cancelFor(ap.id));
    } catch (e) {
      if (!mounted) return;
      final t = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e is ApiException && e.message.isNotEmpty
              ? e.message
              : t.acErrorLoad)));
    } finally {
      if (mounted) setState(() => _busy.remove(ap.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final items = _items;
    Widget body;
    if (items == null && _error == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (items == null) {
      body = Center(
          child: AcMessage(
              icon: Icons.cloud_off_rounded,
              body: (_error ?? '').isNotEmpty ? _error! : t.acErrorLoad,
              action: t.acRetry,
              onAction: () {
                setState(() => _error = null);
                _load();
              }));
    } else {
      final focus = widget.focusId;
      final ordered = [
        ...items.where((a) => a.id == focus),
        ...items.where((a) => a.id != focus),
      ];
      final missingFocus = focus != null && !items.any((a) => a.id == focus);
      body = RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(Gap.lg),
          children: [
            const OfflineBanner(),
            if (missingFocus && !_done.containsKey(focus))
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.md),
                child: Text(t.acApGone,
                    key: const ValueKey('ac_focus_gone'),
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ),
            if (ordered.isEmpty)
              AcMessage(icon: Icons.verified_user_outlined, body: t.acApprovalsEmpty),
            for (final a in ordered)
              if (_done.containsKey(a.id))
                ListTile(
                  key: ValueKey('ac_decided_${a.id}'),
                  leading: Icon(_done[a.id] == 'approve'
                      ? Icons.check_circle_rounded
                      : Icons.block_rounded),
                  title: Text(a.title),
                  subtitle: Text(_done[a.id] == 'approve'
                      ? t.acApApproved
                      : (_done[a.id] == 'reject' ? t.acApRejected : t.acApGone)),
                )
              else
                AcApprovalCard(
                  ap: a,
                  busy: _busy.contains(a.id),
                  fromNotification: widget.fromApproveAction && a.id == focus,
                  onApprove: () => _decide(a, 'approve'),
                  onReject: () => _decide(a, 'reject'),
                ),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(t.acApprovals)),
      body: SafeArea(child: body),
    );
  }
}
