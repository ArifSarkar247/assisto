import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../bizagent_api.dart';
import '../../../l10n/app_localizations.dart';
import '../../../state.dart';
import '../../../theme.dart';
import '../../../widgets/business_ui.dart';
import '../../../widgets/skeleton.dart';
import 'approvals_screen.dart' show ApprovalsScreen, baRiskLabel;
import 'seller_agent_screen.dart' show baChannelIcon, baChannelLabel, baErrorText, bd;
import 'seller_setup_screen.dart' show SellerSetupScreen;

/// The Business inbox: every customer chat from the owner's own Facebook
/// Page, Instagram, WhatsApp number and website widget in one list, with who
/// is replying (AI handled / handed over to you / needs reply), unread
/// counts, filters and search. Server: GET /bizagent/inbox
/// (views_bizagent_v2.py).
class SellerInboxScreen extends StatefulWidget {
  const SellerInboxScreen({super.key});
  @override
  State<SellerInboxScreen> createState() => _SellerInboxScreenState();
}

/// Status chip label for one chat (server: bizagent_guard.thread_status).
String bv2StatusLabel(AppLocalizations t, String s) {
  switch (s) {
    case 'owner':
      return t.bv2StatusOwner;
    case 'attention':
      return t.bv2StatusAttention;
    default:
      return t.bv2StatusAgent;
  }
}

Color bv2StatusColor(BuildContext c, String s) {
  switch (s) {
    case 'owner':
      return Theme.of(c).colorScheme.primary;
    case 'attention':
      return AssistoTokens.of(c).warning;
    default:
      return AssistoTokens.of(c).success;
  }
}

class _SellerInboxScreenState extends State<SellerInboxScreen> {
  bool _loading = true;
  Object? _error;
  List<Map<String, dynamic>> _threads = const [];
  Map<String, dynamic> _counts = const {};
  Map<String, dynamic> _features = const {};
  String _status = '';
  bool _unread = false;
  final _q = TextEditingController();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _threads.isEmpty;
      _error = null;
    });
    try {
      final r = await context
          .read<AppState>()
          .api
          .bizAgentInbox(status: _status, q: _q.text, unread: _unread);
      if (!mounted) return;
      setState(() {
        _threads = ((r['threads'] ?? const []) as List).cast<Map<String, dynamic>>();
        _counts = Map<String, dynamic>.from((r['counts'] as Map?) ?? const {});
        _features = Map<String, dynamic>.from((r['features'] as Map?) ?? const {});
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

  void _onSearch(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _load);
    setState(() {}); // the clear button follows the text
  }

  void _pick(String status, bool unread) {
    setState(() {
      _status = status;
      _unread = unread;
    });
    _load();
  }

  void _showAll() {
    _debounce?.cancel();
    _q.clear();
    _pick('', false);
  }

  Future<void> _openSetup() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const SellerSetupScreen()));
    if (mounted) _load();
  }

  int _n(String k) => (_counts[k] as num?)?.toInt() ?? 0;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(appBar: AppBar(title: Text(t.bv2InboxTitle)), body: _body(t));
  }

  /// sales2: the seller's three questions as filters — what needs my reply,
  /// what the AI handled, what was handed over to me — plus All / Unread.
  Widget _filters(AppLocalizations t) {
    Widget chip(String label, String status, bool unread) {
      final sel = _status == status && _unread == unread;
      return Padding(
        padding: const EdgeInsetsDirectional.only(end: Gap.sm),
        child: ChoiceChip(
          label: Text(bd(context, label)),
          selected: sel,
          onSelected: (_) => _pick(status, unread),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
      child: Row(children: [
        chip(t.bv2FilterAll(_n('all')), '', false),
        chip(t.s2FilterNeedsReply(_n('attention')), 'attention', false),
        chip(t.s2FilterAiHandled(_n('agent')), 'agent', false),
        chip(t.s2FilterHandedOver(_n('owner')), 'owner', false),
        chip(t.bv2FilterUnread(_n('unread')), '', true),
      ]),
    );
  }

  /// First run: what the inbox gives (benefit), one button, one how-to line.
  Widget _empty(AppLocalizations t) {
    final connected = _features['inbox'] == true;
    return StateMessage(
      icon: Icons.forum_rounded,
      title: connected ? t.baInboxEmptyTitle : t.s2InboxEmptyTitle,
      message: connected
          ? t.s2InboxNoChatsHow
          : '${t.s2InboxEmptyBenefit}\n\n${t.s2InboxEmptyHow}',
      action: Wrap(
        alignment: WrapAlignment.center,
        spacing: Gap.sm,
        runSpacing: Gap.sm,
        children: [
          FilledButton.icon(
            onPressed: _openSetup,
            icon: Icon(connected ? Icons.settings_rounded : Icons.add_link_rounded),
            label: Text(connected ? t.s2InboxCheckChannels : t.s2InboxConnect),
          ),
          if (connected) TextButton(onPressed: _load, child: Text(t.bizRefresh)),
        ],
      ),
    );
  }

  Widget _body(AppLocalizations t) {
    if (_loading) return const SkeletonList();
    if (_error != null) {
      return StateMessage(
        icon: Icons.cloud_off_rounded,
        title: t.bizLoadFailed,
        message: baErrorText(t, _error!),
        action: FilledButton(onPressed: _load, child: Text(t.bizRetry)),
      );
    }
    final filtered = _status.isNotEmpty || _unread || _q.text.trim().isNotEmpty;
    if (_threads.isEmpty && !filtered) return _empty(t);
    return SafeArea(
      top: false,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.sm),
          child: TextField(
            controller: _q,
            onChanged: _onSearch,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: t.bv2SearchHint,
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _q.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: t.s2ClearSearch,
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () {
                        _q.clear();
                        _onSearch('');
                      },
                    ),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        _filters(t),
        const SizedBox(height: Gap.sm),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: _threads.isEmpty
                ? ListView(children: [
                    Padding(
                      padding: const EdgeInsets.all(Gap.xl),
                      child: Column(children: [
                        Text(t.bv2NoMatch, textAlign: TextAlign.center),
                        const SizedBox(height: Gap.sm),
                        TextButton(onPressed: _showAll, child: Text(t.s2ShowAllChats)),
                      ]),
                    ),
                  ])
                : ListView.separated(
                    itemCount: _threads.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) => _row(t, _threads[i]),
                  ),
          ),
        ),
      ]),
    );
  }

  Widget _row(AppLocalizations t, Map<String, dynamic> th) {
    final pending = (th['pending'] as num?)?.toInt() ?? 0;
    final unread = (th['unread'] as num?)?.toInt() ?? 0;
    final status = '${th['status'] ?? 'agent'}';
    final channel = '${th['channel']}';
    final small = Theme.of(context).textTheme.bodySmall;
    return ListTile(
      leading: Tooltip(
        message: baChannelLabel(t, channel),
        child: CircleAvatar(child: Icon(baChannelIcon(channel), size: 20)),
      ),
      title: Text(bd(context, th['customer_name']),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: unread > 0 ? const TextStyle(fontWeight: FontWeight.w700) : null),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(bd(context, '${th['last_text'] ?? ''}'),
            maxLines: 2, overflow: TextOverflow.ellipsis),
        const SizedBox(height: Gap.xs),
        Wrap(
          spacing: Gap.sm,
          runSpacing: Gap.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            BizStatusChip(label: bv2StatusLabel(t, status), color: bv2StatusColor(context, status)),
            Text(baChannelLabel(t, channel), style: small),
          ],
        ),
      ]),
      isThreeLine: true,
      trailing: (unread + pending) > 0 ? Badge(label: Text(bd(context, unread + pending))) : null,
      onTap: () async {
        await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => SellerChatScreen(threadId: (th['id'] as num).toInt())));
        if (mounted) _load();
      },
    );
  }
}

/// One customer chat: the handoff card (why the AI handed over, what the
/// customer wants) with one-tap Take over / Give back to AI, messages (AI
/// replies are labelled), draft / payment cards, catalog quick replies above
/// the composer (they fill the box — the seller still taps Send), the 24 h
/// window note.
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
  List<Map<String, dynamic>> _quick = const [];
  final _c = TextEditingController();
  final _focus = FocusNode();
  bool _busy = false;
  bool _modeBusy = false;

  @override
  void initState() {
    super.initState();
    _c.addListener(_onText);
    _load();
    _loadQuick();
  }

  // Send is enabled only when there is text (no dead taps).
  void _onText() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
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

  /// Quick replies are a helper: when they cannot load the row is simply
  /// not shown (the composer keeps working).
  Future<void> _loadQuick() async {
    try {
      final q = await context.read<AppState>().api.bizAgentQuickReplies(widget.threadId);
      if (!mounted) return;
      setState(() => _quick = q.where((r) => '${r['text'] ?? ''}'.trim().isNotEmpty).toList());
    } catch (_) {
      if (mounted) setState(() => _quick = const []);
    }
  }

  void _retry() {
    setState(() {
      _loading = true;
      _error = null;
    });
    _load();
    _loadQuick();
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(bd(context, m))));

  /// g1 per-chat toggle: 'human' = I will reply · 'ai' = Let AI reply.
  Future<void> _mode(String mode) async {
    if (_modeBusy) return;
    final t = AppLocalizations.of(context);
    setState(() => _modeBusy = true);
    try {
      await context.read<AppState>().api.bizAgentReplyMode(widget.threadId, mode);
      _snack(mode == 'human' ? t.baHandoverOnDone : t.baHandoverOffDone);
    } catch (e) {
      _snack(baErrorText(t, e));
    }
    await _load();
    if (mounted) setState(() => _modeBusy = false);
  }

  Future<void> _verify(int orderId, String status) async {
    final t = AppLocalizations.of(context);
    try {
      await context.read<AppState>().api.bizAgentVerifyPayment(orderId, status);
      _snack(status == 'verified' ? t.g1PaymentVerifiedDone : t.g1PaymentRejectedDone);
    } catch (e) {
      _snack(baErrorText(t, e));
    }
    await _load();
  }

  /// biz-v2: the owner confirms / cancels the agent's photo DRAFT order.
  Future<void> _draft(int orderId, bool confirm) async {
    final t = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    try {
      if (confirm) {
        await api.bizAgentConfirmDraft(orderId);
      } else {
        await api.bizAgentCancelDraft(orderId);
      }
      _snack(confirm ? t.bv2DraftConfirmed : t.bv2DraftCancelled);
    } catch (e) {
      _snack(baErrorText(t, e));
    }
    await _load();
  }

  Future<void> _openApprovals() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ApprovalsScreen()));
    if (mounted) _load();
  }

  /// A quick reply only FILLS the composer — the seller reads, edits and
  /// taps Send himself (never an auto-send).
  void _useQuick(Map<String, dynamic> r) {
    final text = '${r['text'] ?? ''}';
    _c.value = TextEditingValue(
        text: text, selection: TextSelection.collapsed(offset: text.length));
    _focus.requestFocus();
  }

  String _clock(String iso) {
    final d = DateTime.tryParse(iso)?.toLocal();
    if (d == null) return '';
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _send() async {
    final t = AppLocalizations.of(context);
    final text = _c.text.trim();
    if (text.isEmpty || _busy) return;
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
        title: Text(bd(context, th['customer_name']), maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: _body(t, th),
    );
  }

  /// The "who replies" header when there is NO open handoff (the handoff
  /// card carries the same two actions, so the two never show together).
  Widget _modeHeader(AppLocalizations t, Map th) {
    final handover = th['handover'] == true;
    final pausedUntil = '${th['paused_until'] ?? ''}';
    return Material(
      color: handover || pausedUntil.isNotEmpty
          ? AssistoTokens.of(context).warning.withValues(alpha: 0.12)
          : Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.sm),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SegmentedButton<String>(
            segments: [
              ButtonSegment(
                  value: 'ai',
                  icon: const Icon(Icons.smart_toy_rounded),
                  label: Text(t.g1LetAiReply)),
              ButtonSegment(
                  value: 'human',
                  icon: const Icon(Icons.support_agent_rounded),
                  label: Text(t.g1IWillReply)),
            ],
            selected: {handover ? 'human' : 'ai'},
            onSelectionChanged: _modeBusy ? null : (v) => _mode(v.first),
          ),
          const SizedBox(height: Gap.xs),
          Text(
            bd(context, handover
                ? ('${th['handback_at'] ?? ''}'.isNotEmpty
                    ? '${t.baHandoverOnSub} ${t.bv2HandbackAt(_clock('${th['handback_at']}'))}'
                    : t.baHandoverOnSub)
                : pausedUntil.isNotEmpty
                    ? t.g1PausedNote(_clock(pausedUntil))
                    : t.g1AiRepliesNote),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.4),
          ),
          if (!handover && pausedUntil.isNotEmpty)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                  onPressed: _modeBusy ? null : () => _mode('ai'), child: Text(t.g1ResumeNow)),
            ),
        ]),
      ),
    );
  }

  /// sales2: ONE handoff card at the top of the chat (the newest unresolved
  /// handoff — server: bizagent_guard.open_handoff): why the AI handed over,
  /// what the customer wants, their last question and mood, and one tap to
  /// take over or give the chat back to the AI.
  Widget _handoffCard(AppLocalizations t, Map th, Map card) {
    final lang = Localizations.localeOf(context).languageCode == 'bn' ? 'bn' : 'en';
    final lines = (((card['lines'] as Map?) ?? const {})[lang] as List?) ?? const [];
    final handover = th['handover'] == true;
    final pending = card['pending'] == true;
    final handbackAt = '${th['handback_at'] ?? ''}';
    final warn = AssistoTokens.of(context).warning;
    final small = Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.4);
    return Container(
      key: const ValueKey('s2-handoff-card'),
      width: double.infinity,
      color: warn.withValues(alpha: 0.12),
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.sm),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.support_agent_rounded, size: 20, color: warn),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(t.s2HandoffTitle,
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700)),
          ),
        ]),
        const SizedBox(height: Gap.xs),
        BizStatusChip(label: baRiskLabel(t, '${card['reason'] ?? ''}'), color: warn),
        const SizedBox(height: Gap.xs),
        for (final l in lines)
          Padding(
            padding: const EdgeInsets.only(top: Gap.xxs),
            child: Text(bd(context, '$l'), style: const TextStyle(height: 1.4)),
          ),
        const SizedBox(height: Gap.xs),
        Text(
          bd(context, handover
              ? (handbackAt.isNotEmpty
                  ? '${t.baHandoverOn} · ${t.bv2HandbackAt(_clock(handbackAt))}'
                  : t.baHandoverOn)
              : t.s2HandoffAiWaiting),
          style: small,
        ),
        if (pending) ...[
          const SizedBox(height: Gap.xs),
          Text(t.s2HandoffDraftWaiting, style: small),
        ],
        const SizedBox(height: Gap.sm),
        Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
          if (!handover)
            FilledButton.icon(
              key: const ValueKey('s2-take-over'),
              onPressed: _modeBusy ? null : () => _mode('human'),
              icon: const Icon(Icons.pan_tool_alt_rounded),
              label: Text(t.s2TakeOver),
            ),
          if (handover)
            FilledButton.tonalIcon(
              key: const ValueKey('s2-give-back'),
              onPressed: _modeBusy ? null : () => _mode('ai'),
              icon: const Icon(Icons.smart_toy_rounded),
              label: Text(t.s2GiveBack),
            )
          else
            OutlinedButton.icon(
              key: const ValueKey('s2-give-back'),
              onPressed: _modeBusy ? null : () => _mode('ai'),
              icon: const Icon(Icons.smart_toy_rounded),
              label: Text(t.s2GiveBack),
            ),
          if (pending)
            TextButton(onPressed: _openApprovals, child: Text(t.s2ReviewDraft)),
        ]),
      ]),
    );
  }

  /// Order / payment cards ride at the top of the message list (they scroll
  /// away — never a stack of fixed cards squeezing the chat at large text).
  List<Widget> _orderCards(AppLocalizations t, Map th) {
    final orders = ((_d['orders'] as List?) ?? const []).cast<Map>();
    final draft = (th['order_draft'] as Map?) ?? const {};
    final drafts = orders.where((o) => o['draft'] == true).toList();
    return [
      for (final o in drafts)
        BizCard(
          title: bd(context, t.bv2DraftTitle('${o['id']}')),
          icon: Icons.add_shopping_cart_rounded,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final it in ((o['items'] as List?) ?? const []).cast<Map>())
              Text(bd(context, t.bv2DraftLine('${it['name'] ?? ''}', '${it['qty'] ?? 1}',
                  '${it['price'] ?? ''}'))),
            const SizedBox(height: Gap.xs),
            Text(t.bv2DraftBody, style: const TextStyle(height: 1.4)),
            const SizedBox(height: Gap.sm),
            Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
              FilledButton.tonal(
                  onPressed: () => _draft((o['id'] as num).toInt(), true),
                  child: Text(t.bv2DraftConfirm)),
              TextButton(
                  onPressed: () => _draft((o['id'] as num).toInt(), false),
                  child: Text(t.bv2DraftCancel)),
            ]),
          ]),
        ),
      for (final o in orders.where((o) => o['payment_status'] == 'pending_verification'))
        BizCard(
          title: bd(context, t.g1PaymentPendingTitle('${o['id']}')),
          icon: Icons.receipt_long_rounded,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.g1PaymentPendingBody, style: const TextStyle(height: 1.4)),
            const SizedBox(height: Gap.sm),
            Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
              FilledButton.tonal(
                  onPressed: () => _verify((o['id'] as num).toInt(), 'verified'),
                  child: Text(t.g1PaymentVerify)),
              TextButton(
                  onPressed: () => _verify((o['id'] as num).toInt(), 'rejected'),
                  child: Text(t.g1PaymentNotReceived)),
            ]),
          ]),
        ),
      for (final o in orders.where((o) =>
          o['courier_live'] == false && '${o['tracking'] ?? ''}'.startsWith('TEST-')))
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.sm),
          child: BizNote(
              text: bd(context, t.g1CourierTestNote('${o['id']}', '${o['tracking']}')),
              icon: Icons.science_rounded,
              tint: AssistoTokens.of(context).warning),
        ),
      // the order being collected — not repeated when a draft order card
      // for this chat is already shown above
      if (drafts.isEmpty && draft.isNotEmpty && draft['product'] != null)
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.sm),
          child: BizNote(
            text: bd(context, t.baOrderDraft('${draft['product']}', '${draft['qty'] ?? 1}',
                '${draft['phone'] ?? '—'}', '${draft['address'] ?? '—'}')),
            icon: Icons.shopping_bag_rounded,
          ),
        ),
    ];
  }

  String _quickLabel(AppLocalizations t, Map<String, dynamic> r) {
    switch ('${r['kind']}') {
      case 'delivery':
        return t.s2QrDelivery;
      case 'payment':
        return t.s2QrPayment;
      default:
        final name = '${r['name'] ?? ''}';
        return r['in_stock'] == false
            ? t.s2QrProductOut(name)
            : t.s2QrProduct(name, '${r['price'] ?? ''}');
    }
  }

  IconData _quickIcon(String kind) {
    switch (kind) {
      case 'delivery':
        return Icons.local_shipping_rounded;
      case 'payment':
        return Icons.payments_rounded;
      default:
        return Icons.sell_rounded;
    }
  }

  Widget _quickRow(AppLocalizations t) {
    return SingleChildScrollView(
      key: const ValueKey('s2-quick-replies'),
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.xs, Gap.sm, 0),
      child: Row(children: [
        Tooltip(
          message: t.s2QuickReplies,
          child: Padding(
            padding: const EdgeInsetsDirectional.only(end: Gap.xs),
            child: Icon(Icons.bolt_rounded,
                size: 20, color: Theme.of(context).colorScheme.primary,
                semanticLabel: t.s2QuickReplies),
          ),
        ),
        for (final r in _quick)
          Padding(
            padding: const EdgeInsetsDirectional.only(end: Gap.sm),
            child: ActionChip(
              avatar: Icon(_quickIcon('${r['kind']}'), size: 18),
              label: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 240),
                child: Text(bd(context, _quickLabel(t, r)),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              tooltip: t.s2QuickReplyHint,
              onPressed: _busy ? null : () => _useQuick(r),
            ),
          ),
      ]),
    );
  }

  Widget _body(AppLocalizations t, Map th) {
    if (_loading) return const SkeletonList();
    if (_error != null) {
      return StateMessage(
        icon: Icons.cloud_off_rounded,
        title: t.bizLoadFailed,
        message: baErrorText(t, _error!),
        action: FilledButton(onPressed: _retry, child: Text(t.bizRetry)),
      );
    }
    final msgs = ((_d['messages'] as List?) ?? const []).cast<Map>();
    final card = th['handoff_card'] is Map ? th['handoff_card'] as Map : null;
    final inWindow = th['in_window'] == true || th['channel'] == 'website';
    final top = card != null && ((card['lines'] as Map?)?.isNotEmpty ?? false)
        ? _handoffCard(t, th, card)
        : _modeHeader(t, th);
    final lead = _orderCards(t, th);
    return LayoutBuilder(builder: (context, box) => Column(children: [
      // the pinned header never takes more than ~45% of the chat area (200%
      // font, small phone): it scrolls inside itself instead of overflowing
      ConstrainedBox(
        constraints: BoxConstraints(maxHeight: box.maxHeight * 0.45),
        child: SingleChildScrollView(child: top),
      ),
      Expanded(
        child: ListView.builder(
          padding: const EdgeInsets.all(Gap.lg),
          itemCount: lead.length + msgs.length,
          itemBuilder: (_, i) => i < lead.length ? lead[i] : _bubble(t, msgs[i - lead.length]),
        ),
      ),
      if (!inWindow)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
          child: BizNote(
              text: th['channel'] == 'whatsapp_cloud' ? t.baWindowClosedWa : t.baWindowClosed,
              icon: Icons.timer_off_rounded, tint: AssistoTokens.of(context).warning),
        ),
      SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (_quick.isNotEmpty) _quickRow(t),
          Padding(
            padding: const EdgeInsets.all(Gap.sm),
            child: Row(children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('s2-composer'),
                  controller: _c,
                  focusNode: _focus,
                  minLines: 1,
                  maxLines: 4,
                  decoration: InputDecoration(
                      hintText: t.baComposerHint, border: const OutlineInputBorder()),
                ),
              ),
              const SizedBox(width: Gap.sm),
              IconButton.filled(
                tooltip: t.baSend,
                onPressed: _busy || _c.text.trim().isEmpty ? null : _send,
                icon: const Icon(Icons.send_rounded),
              ),
            ]),
          ),
        ]),
      ),
    ]));
  }

  Widget _bubble(AppLocalizations t, Map m) {
    final out = m['direction'] == 'out';
    final scheme = Theme.of(context).colorScheme;
    final status = '${m['status'] ?? ''}';
    final pending = status == 'pending_approval';
    final failed = status == 'failed' || status == 'blocked' || status == 'queued';
    String meta = '';
    final kind = '${m['kind'] ?? ''}';
    final image = '${m['image_url'] ?? ''}';
    if (out) {
      meta = m['is_ai'] == true
          ? (m['source'] == 'rule' ? t.g1ByRule : t.baByAi)
          : t.baByYou;
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
                ? AssistoTokens.of(context).warning.withValues(alpha: 0.14)
                : out
                    ? scheme.primaryContainer
                    : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(Radii.md),
            border: failed ? Border.all(color: Theme.of(context).colorScheme.error) : null,
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (!out && (kind == 'image' || kind == 'voice'))
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.xs),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(kind == 'image' ? Icons.image_rounded : Icons.mic_none_rounded,
                      size: 16, color: scheme.onSurfaceVariant),
                  const SizedBox(width: Gap.xs),
                  Flexible(
                    child: Text(kind == 'image' ? t.g1PhotoFromCustomer : t.g1VoiceFromCustomer,
                        style: Theme.of(context).textTheme.bodySmall),
                  ),
                ]),
              ),
            if (out && image.startsWith('https://'))
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.xs),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(Radii.sm),
                  child: Image.network(image, height: 140, fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_rounded)),
                ),
              ),
            if ('${m['text'] ?? ''}'.isNotEmpty || kind != 'image')
              Text(bd(context, m['text']),
                  style: TextStyle(
                      height: 1.4,
                      color: out ? scheme.onPrimaryContainer : scheme.onSurface)),
            if (meta.isNotEmpty) ...[
              const SizedBox(height: Gap.xs),
              Text(bd(context, meta),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: out ? scheme.onPrimaryContainer : scheme.onSurfaceVariant)),
            ],
          ]),
        ),
      ),
    );
  }
}
