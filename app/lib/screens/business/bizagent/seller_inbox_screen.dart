import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../bizagent_api.dart';
import '../../../l10n/app_localizations.dart';
import '../../../state.dart';
import '../../../theme.dart';
import '../../../widgets/business_ui.dart';
import '../../../widgets/skeleton.dart';
import 'approvals_screen.dart' show baRiskLabel;
import 'seller_agent_screen.dart' show baChannelIcon, baErrorText;

/// P1 — the seller's inbox of customer chats from the connected Page,
/// Instagram and WhatsApp number.
class SellerInboxScreen extends StatefulWidget {
  const SellerInboxScreen({super.key});
  @override
  State<SellerInboxScreen> createState() => _SellerInboxScreenState();
}

class _SellerInboxScreenState extends State<SellerInboxScreen> {
  bool _loading = true;
  Object? _error;
  List<Map<String, dynamic>> _threads = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await context.read<AppState>().api.bizAgentThreads();
      if (!mounted) return;
      setState(() {
        _threads = r;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(appBar: AppBar(title: Text(t.baInboxTitle)), body: _body(t));
  }

  Widget _body(AppLocalizations t) {
    if (_loading) return const SkeletonList();
    if (_error != null) {
      return StateMessage(
        icon: Icons.cloud_off_outlined,
        title: t.bizLoadFailed,
        message: baErrorText(t, _error!),
        action: FilledButton(onPressed: _load, child: Text(t.bizRetry)),
      );
    }
    if (_threads.isEmpty) {
      return StateMessage(
          icon: Icons.inbox_outlined, title: t.baInboxEmptyTitle, message: t.baInboxEmptyBody);
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        itemCount: _threads.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (_, i) {
          final th = _threads[i];
          final pending = (th['pending'] as num?)?.toInt() ?? 0;
          return ListTile(
            leading: CircleAvatar(child: Icon(baChannelIcon('${th['channel']}'), size: 20)),
            title: Text('${th['customer_name'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              th['handover'] == true
                  ? '${t.baHandoverOnShort} · ${th['last_text'] ?? ''}'
                  : '${th['last_text'] ?? ''}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: pending > 0 ? Badge(label: Text('$pending')) : null,
            onTap: () async {
              await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => SellerChatScreen(threadId: (th['id'] as num).toInt())));
              if (mounted) _load();
            },
          );
        },
      ),
    );
  }
}

/// One customer chat: messages (AI replies are labelled), the human handover
/// switch (AI pauses on this chat until resumed), the seller's composer, the
/// 24 h window note and the order being collected.
class SellerChatScreen extends StatefulWidget {
  final int threadId;
  const SellerChatScreen({super.key, required this.threadId});
  @override
  State<SellerChatScreen> createState() => _SellerChatScreenState();
}

class _SellerChatScreenState extends State<SellerChatScreen> {
  bool _loading = true;
  Object? _error;
  Map<String, dynamic> _d = const {};
  final _c = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await context.read<AppState>().api.bizAgentThread(widget.threadId);
      if (!mounted) return;
      setState(() {
        _d = d;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _handover(bool on) async {
    final t = AppLocalizations.of(context);
    try {
      await context.read<AppState>().api.bizAgentHandover(widget.threadId, on);
      _snack(on ? t.baHandoverOnDone : t.baHandoverOffDone);
    } catch (e) {
      _snack(baErrorText(t, e));
    }
    await _load();
  }

  Future<void> _send() async {
    final t = AppLocalizations.of(context);
    final text = _c.text.trim();
    if (text.isEmpty) return;
    setState(() => _busy = true);
    try {
      final r = await context.read<AppState>().api.bizAgentSend(widget.threadId, text);
      final m = (r['message'] as Map?) ?? const {};
      if (r['ok'] == true) {
        _c.clear();
      } else {
        _snack(_sendError(t, '${m['send_error'] ?? m['status'] ?? ''}'));
      }
    } catch (e) {
      _snack(baErrorText(t, e));
    }
    if (mounted) setState(() => _busy = false);
    await _load();
  }

  String _sendError(AppLocalizations t, String code) {
    switch (code) {
      case 'outside_24h_window':
        return t.baWindowClosed;
      case 'outside_24h_window_template_required':
        return t.baWindowClosedWa;
      case 'no_token':
        return t.baNoToken;
      default:
        return t.baSendFailed(code);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final th = (_d['thread'] as Map?) ?? const {};
    return Scaffold(
      appBar: AppBar(
        title: Text('${th['customer_name'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: _body(t, th),
    );
  }

  Widget _body(AppLocalizations t, Map th) {
    if (_loading) return const SkeletonList();
    if (_error != null) {
      return StateMessage(
        icon: Icons.cloud_off_outlined,
        title: t.bizLoadFailed,
        message: baErrorText(t, _error!),
        action: FilledButton(onPressed: _load, child: Text(t.bizRetry)),
      );
    }
    final msgs = ((_d['messages'] as List?) ?? const []).cast<Map>();
    final handover = th['handover'] == true;
    final inWindow = th['in_window'] == true;
    final draft = (th['order_draft'] as Map?) ?? const {};
    final scheme = Theme.of(context).colorScheme;
    return Column(children: [
      Material(
        color: handover ? Brand.warning.withValues(alpha: 0.12) : scheme.surfaceContainerHighest,
        child: SwitchListTile(
          value: handover,
          secondary: Icon(handover ? Icons.support_agent : Icons.smart_toy_outlined),
          title: Text(handover ? t.baHandoverOn : t.baHandoverOff),
          subtitle: Text(handover ? t.baHandoverOnSub : t.baHandoverOffSub),
          onChanged: _handover,
        ),
      ),
      if (draft.isNotEmpty && draft['product'] != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, 0),
          child: BizNote(
            text: t.baOrderDraft('${draft['product']}', '${draft['qty'] ?? 1}',
                '${draft['phone'] ?? '—'}', '${draft['address'] ?? '—'}'),
            icon: Icons.shopping_bag_outlined,
          ),
        ),
      Expanded(
        child: ListView.builder(
          padding: const EdgeInsets.all(Gap.lg),
          itemCount: msgs.length,
          itemBuilder: (_, i) => _bubble(t, msgs[i]),
        ),
      ),
      if (!inWindow)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
          child: BizNote(
              text: th['channel'] == 'whatsapp_cloud' ? t.baWindowClosedWa : t.baWindowClosed,
              icon: Icons.timer_off_outlined, tint: Brand.warning),
        ),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(Gap.sm),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _c,
                minLines: 1,
                maxLines: 4,
                decoration: InputDecoration(
                    hintText: t.baComposerHint, border: const OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: Gap.sm),
            IconButton.filled(
              tooltip: t.baSend,
              onPressed: _busy ? null : _send,
              icon: const Icon(Icons.send),
            ),
          ]),
        ),
      ),
    ]);
  }

  Widget _bubble(AppLocalizations t, Map m) {
    final out = m['direction'] == 'out';
    final scheme = Theme.of(context).colorScheme;
    final status = '${m['status'] ?? ''}';
    final pending = status == 'pending_approval';
    final failed = status == 'failed' || status == 'blocked' || status == 'queued';
    String meta = '';
    if (out) {
      meta = m['is_ai'] == true ? t.baByAi : t.baByYou;
      if (pending) meta = '${t.baAwaitingApproval} · ${baRiskLabel(t, '${m['risk_reason']}')}';
      if (status == 'rejected') meta = t.baRejected;
      if (failed) meta = '$meta · ${_sendError(t, '${m['send_error'] ?? status}')}';
    }
    return Align(
      alignment: out ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
        child: Container(
          margin: const EdgeInsets.only(bottom: Gap.sm),
          padding: const EdgeInsets.all(Gap.md),
          decoration: BoxDecoration(
            color: pending
                ? Brand.warning.withValues(alpha: 0.14)
                : out
                    ? scheme.primaryContainer
                    : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(Radii.md),
            border: failed ? Border.all(color: Brand.danger) : null,
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${m['text'] ?? ''}',
                style: TextStyle(
                    height: 1.4,
                    color: out ? scheme.onPrimaryContainer : scheme.onSurface)),
            if (meta.isNotEmpty) ...[
              const SizedBox(height: Gap.xs),
              Text(meta,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: out ? scheme.onPrimaryContainer : scheme.onSurfaceVariant)),
            ],
          ]),
        ),
      ),
    );
  }
}
