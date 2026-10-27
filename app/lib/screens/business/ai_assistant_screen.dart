import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../business_ai_api.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/business_ui.dart';
import '../../widgets/ai_report.dart'; // ai-report
import '../../widgets/skeleton.dart';
import '../plans_screen.dart';

/// The paid AI Sales Assistant console.
///
/// - Inbox of chat threads from OFFICIAL channels only (WhatsApp Business Cloud
///   API / Messenger). NEVER personal WhatsApp.
/// - AI-drafted reply with a confidence read-out; owner approves / edits / sends.
/// - Human-handoff banner (angry / refund / big order / low confidence).
/// - "Owner takes over" per-thread toggle.
/// - The AI-disclosure line is always shown.
/// - Entirely behind a Premium gate; shows a clear upgrade screen when unpaid.
/// - Live needs Meta keys -> a "connect WhatsApp Business / Messenger" setup
///   state (mock) when no channel is connected.
class AiAssistantScreen extends StatefulWidget {
  const AiAssistantScreen({super.key});
  @override
  State<AiAssistantScreen> createState() => _AiAssistantScreenState();
}

class _AiAssistantScreenState extends State<AiAssistantScreen> {
  bool _loading = true;
  bool _locked = false; // upgrade required
  Map<String, dynamic>? _channels; // null until loaded
  List<Map<String, dynamic>> _threads = const [];
  String? _error;

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
    final api = context.read<AppState>().api;
    try {
      // channels is FREE; threads is PAID (first to signal the gate).
      _channels = await api.aiChannels();
      _threads = await api.aiThreads();
      _locked = false;
    } catch (e) {
      if (isUpgradeRequired(e)) {
        _locked = true;
      } else {
        _error = e.toString();
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  void _openPlans() {
    Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const PlansScreen()));
  }

  bool get _anyChannelConnected {
    final c = _channels;
    if (c == null) return false;
    final wa = (c['whatsapp_cloud'] as Map?)?['connected'] == true;
    final ms = (c['messenger'] as Map?)?['connected'] == true;
    return wa || ms;
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr.bizAiTitle), actions: [
        IconButton(
          tooltip: tr.bizRefresh,
          onPressed: _loading ? null : _load,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ]),
      body: _body(tr),
    );
  }

  Widget _body(AppLocalizations tr) {
    if (_loading) return const SkeletonList();
    if (_locked) {
      return BizPremiumGate(featureLine: tr.bizAiGateLine, onUpgrade: _openPlans);
    }
    if (_error != null) {
      return StateMessage(
        icon: Icons.cloud_off_rounded,
        title: tr.bizLoadFailed,
        message: _error,
        action: FilledButton(onPressed: _load, child: Text(tr.bizRetry)),
      );
    }
    if (!_anyChannelConnected) return _setupState(tr);
    return _inbox(tr);
  }

  // ---- "connect WhatsApp Business / Messenger" setup state (mock) ----
  Widget _setupState(AppLocalizations tr) {
    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      BizCard(
        title: tr.bizConnectChannelsTitle,
        icon: Icons.hub_rounded,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr.bizConnectChannelsBody, style: const TextStyle(height: 1.4)),
          const SizedBox(height: Gap.md),
          _channelTile(tr, tr.bizChannelWhatsapp, Icons.chat_rounded, 'whatsapp_cloud'),
          const SizedBox(height: Gap.sm),
          _channelTile(tr, tr.bizChannelMessenger, Icons.forum_rounded, 'messenger'),
        ]),
      ),
      const SizedBox(height: Gap.md),
      // Hard rule, always visible: official APIs only, never personal WhatsApp.
      BizNote(text: tr.bizNoPersonalWhatsapp, icon: Icons.verified_user_rounded),
      const SizedBox(height: Gap.md),
      BizMockBanner(text: tr.bizChannelsNeedKey),
    ]);
  }

  Widget _channelTile(AppLocalizations tr, String name, IconData icon, String key) {
    final connected = (_channels?[key] as Map?)?['connected'] == true;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(children: [
        Icon(icon, color: scheme.primary),
        const SizedBox(width: Gap.md),
        Expanded(child: Text(name, style: const TextStyle(fontWeight: FontWeight.w600))),
        if (connected)
          BizStatusChip(label: tr.bizConnected, color: AssistoTokens.of(context).success)
        else
          OutlinedButton(
            // Mock: connecting needs real Meta keys; show the honest state.
            onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(tr.bizChannelsNeedKey))),
            child: Text(tr.bizConnect),
          ),
      ]),
    );
  }

  // ---- inbox of threads ----
  Widget _inbox(AppLocalizations tr) {
    if (_threads.isEmpty) {
      return StateMessage(
        icon: Icons.forum_rounded,
        title: tr.bizInboxEmptyTitle,
        message: tr.bizInboxEmptyBody,
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.all(Gap.lg),
        itemCount: _threads.length + 1,
        separatorBuilder: (_, __) => const SizedBox(height: Gap.sm),
        itemBuilder: (_, i) {
          if (i == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: Gap.sm),
              child: BizNote(
                  text: tr.bizNoPersonalWhatsapp,
                  icon: Icons.verified_user_rounded),
            );
          }
          return _threadTile(tr, _threads[i - 1]);
        },
      ),
    );
  }

  Widget _threadTile(AppLocalizations tr, Map<String, dynamic> t) {
    final scheme = Theme.of(context).colorScheme;
    final needsHuman = t['needs_human'] == true;
    final takeover = t['owner_takeover'] == true;
    final name = (t['customer_name'] ?? t['customer_phone'] ?? '').toString();
    final last = (t['last_text'] ?? '').toString();
    final channel = (t['channel'] ?? '').toString();
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.xs),
        leading: CircleAvatar(
          backgroundColor: scheme.secondaryContainer,
          child: Icon(
            channel == 'messenger' ? Icons.forum_rounded : Icons.chat_rounded,
            color: scheme.onSecondaryContainer,
            size: 20,
          ),
        ),
        title: Row(children: [
          Expanded(
            child: Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
          if (needsHuman)
            BizStatusChip(label: tr.bizNeedsYou, color: Theme.of(context).colorScheme.error)
          else if (takeover)
            BizStatusChip(label: tr.bizOwnerOn, color: AssistoTokens.of(context).warning),
        ]),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: Gap.xs),
          child: Text(last.isEmpty ? tr.bizNoMessagesYet : last,
              maxLines: 2, overflow: TextOverflow.ellipsis),
        ),
        onTap: () async {
          final changed = await Navigator.of(context).push<bool>(
            MaterialPageRoute(
              builder: (_) => AiThreadScreen(threadId: (t['id'] as num).toInt()),
            ),
          );
          if (changed == true) _load();
        },
      ),
    );
  }
}

/// A single chat thread: history + AI draft with confidence + approve/edit/send,
/// handoff banner, owner-takeover toggle, and the disclosure line.
class AiThreadScreen extends StatefulWidget {
  final int threadId;
  const AiThreadScreen({super.key, required this.threadId});
  @override
  State<AiThreadScreen> createState() => _AiThreadScreenState();
}

class _AiThreadScreenState extends State<AiThreadScreen> {
  bool _loading = true;
  bool _busy = false;
  bool _dirty = false;
  String? _error;
  Map<String, dynamic> _thread = const {};
  List<Map<String, dynamic>> _messages = const [];
  Map<String, dynamic>? _disclosure;

  final _editCtl = TextEditingController();
  Map<String, dynamic>? _draft; // current AI draft {text, confidence, needs_human, handoff_reason}

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _editCtl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final api = context.read<AppState>().api;
    try {
      final r = await api.aiThread(widget.threadId);
      _thread = (r['thread'] as Map?)?.cast<String, dynamic>() ?? {};
      _messages = ((r['messages'] ?? []) as List).cast<Map<String, dynamic>>();
      _disclosure = await api.aiDisclosure();
      await _draftReply();
    } catch (e) {
      _error = e.toString();
    }
    if (mounted) setState(() => _loading = false);
  }

  bool get _ownerTakeover => _thread['owner_takeover'] == true;

  Future<void> _draftReply() async {
    if (_ownerTakeover) {
      _draft = null;
      _editCtl.text = '';
      return;
    }
    final api = context.read<AppState>().api;
    // Draft from the latest inbound message.
    final lastIn = _messages.reversed.firstWhere(
      (m) => m['direction'] == 'in',
      orElse: () => const {},
    );
    final text = (lastIn['text'] ?? '').toString();
    if (text.isEmpty) {
      _draft = null;
      return;
    }
    final d = await api.aiDraftReply(threadId: widget.threadId, text: text);
    _draft = d;
    _editCtl.text = (d['text'] ?? '').toString();
  }

  Future<void> _toggleTakeover(bool on) async {
    setState(() => _busy = true);
    final api = context.read<AppState>().api;
    try {
      final r = await api.aiThreadTakeover(widget.threadId, on);
      _thread = {..._thread, 'owner_takeover': r['owner_takeover'] ?? on};
      _dirty = true;
      await _draftReply();
    } catch (e) {
      _snack(e.toString());
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _send() async {
    final text = _editCtl.text.trim();
    if (text.isEmpty) return;
    setState(() => _busy = true);
    final api = context.read<AppState>().api;
    final tr = AppLocalizations.of(context);
    try {
      // fromAi true only if sending the unedited AI draft while not taken over.
      final fromAi = !_ownerTakeover &&
          _draft != null &&
          text == (_draft!['text'] ?? '').toString();
      final r = await api.aiThreadSend(widget.threadId, text, fromAi: fromAi);
      _dirty = true;
      if (r['needs_key'] == true) {
        _snack(tr.bizSendNeedsKey);
      }
      await _load();
    } catch (e) {
      _snack(e.toString());
    }
    if (mounted) setState(() => _busy = false);
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_dirty);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text((_thread['customer_name'] ??
                  _thread['customer_phone'] ??
                  tr.bizAiTitle)
              .toString()),
        ),
        body: _loading
            ? const SkeletonList()
            : _error != null
                ? StateMessage(
                    icon: Icons.cloud_off_rounded,
                    title: tr.bizLoadFailed,
                    message: _error,
                    action: FilledButton(onPressed: _load, child: Text(tr.bizRetry)),
                  )
                : _content(tr),
      ),
    );
  }

  Widget _content(AppLocalizations tr) {
    final scheme = Theme.of(context).colorScheme;
    return Column(children: [
      Expanded(
        child: ListView(
          padding: const EdgeInsets.all(Gap.lg),
          children: [
            // Always-on AI disclosure line.
            BizNote(
              text: (_disclosure?['full'] ?? _disclosure?['short'] ?? '').toString(),
              icon: Icons.smart_toy_rounded,
            ),
            const SizedBox(height: Gap.md),
            for (final m in _messages) _bubble(tr, m),
          ],
        ),
      ),
      const Divider(height: 1),
      _composer(tr, scheme),
    ]);
  }

  Widget _bubble(AppLocalizations tr, Map<String, dynamic> m) {
    final scheme = Theme.of(context).colorScheme;
    final isIn = m['direction'] == 'in';
    final isAi = m['is_ai'] == true;
    return Align(
      alignment: isIn ? Alignment.centerLeft : Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(bottom: Gap.sm),
        padding: const EdgeInsets.all(Gap.md),
        constraints: const BoxConstraints(maxWidth: 320),
        decoration: BoxDecoration(
          color: isIn
              ? scheme.surfaceContainerHighest
              : (isAi ? scheme.secondaryContainer : scheme.primaryContainer),
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (!isIn && isAi)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.xs),
              child: Text(tr.bizSentByAi,
                  style: AType.labelSmall.copyWith(fontWeight: FontWeight.w700,
                      color: scheme.onSecondaryContainer)),
            ),
          Text((m['text'] ?? '').toString()),
        ]),
      ),
    );
  }

  Widget _composer(AppLocalizations tr, ColorScheme scheme) {
    final needsHuman = _draft?['needs_human'] == true;
    final handoffReason = (_draft?['handoff_reason'] ?? '').toString();
    final conf = (_draft?['confidence'] as num?)?.toDouble();
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Owner takeover toggle.
          Row(children: [
            Expanded(child: Text(tr.bizOwnerTakeover, style: const TextStyle(fontWeight: FontWeight.w600))),
            Switch(
              value: _ownerTakeover,
              onChanged: _busy ? null : _toggleTakeover,
            ),
          ]),
          // Handoff banner.
          if (needsHuman) ...[
            BizNote(
              text: _handoffText(tr, handoffReason),
              icon: Icons.priority_high_rounded,
              tint: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: Gap.sm),
          ],
          // Confidence read-out for the AI draft.
          if (!_ownerTakeover && conf != null) ...[
            Row(children: [
              Icon(Icons.insights_rounded, size: 16, color: scheme.onSurfaceVariant),
              const SizedBox(width: Gap.xs),
              Expanded(
                child: Text(tr.bizConfidence('${(conf * 100).round()}'),
                    style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
              ),
              // ai-report: flag the AI-drafted reply (text only)
              if ((_draft?['text'] ?? '').toString().trim().isNotEmpty)
                AiReportButton(
                    target: AiReportTarget(
                        surface: 'business',
                        text: (_draft!['text'] ?? '').toString(),
                        sessionId: '${widget.threadId}')),
            ]),
            const SizedBox(height: Gap.sm),
          ],
          TextField(
            controller: _editCtl,
            minLines: 1,
            maxLines: 4,
            decoration: InputDecoration(
              hintText: _ownerTakeover ? tr.bizTypeYourReply : tr.bizEditAiDraft,
            ),
          ),
          const SizedBox(height: Gap.sm),
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _busy ? null : _send,
                icon: const Icon(Icons.send_rounded),
                label: Text(_ownerTakeover
                    ? tr.bizSend
                    : tr.bizApproveSend),
              ),
            ),
          ]),
        ]),
      ),
    );
  }

  String _handoffText(AppLocalizations tr, String reason) {
    switch (reason) {
      case 'angry':
        return tr.handoffAngry;
      case 'refund':
        return tr.handoffRefund;
      case 'big_order':
        return tr.handoffBigOrder;
      case 'low_confidence':
      default:
        return tr.handoffLowConfidence;
    }
  }
}
