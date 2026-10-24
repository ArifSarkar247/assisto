import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../api.dart';
import '../../../bizagent_api.dart';
import '../../../l10n/app_localizations.dart';
import '../../../messaging/date_separators.dart' show localDigits;
import '../../../services/error_kind.dart' show honestFailText;
import '../../../state.dart';
import '../../../theme.dart';
import '../../../widgets/business_ui.dart';
import '../../../widgets/skeleton.dart';
import 'agent_g1_screens.dart';
import 'approvals_screen.dart';
import 'seller_inbox_screen.dart';
import 'seller_setup_screen.dart';

/// P1 — Assisto Business AI Agent: the seller's home for the agent.
///
/// Plan / trial / replies left, AI on-off, channel status, the approval queue,
/// the inbox, and today's sales summary + low-stock list. Every number comes
/// from the server; nothing here is decorative — a channel that is not
/// connected says so and links to setup.
class SellerAgentScreen extends StatefulWidget {
  const SellerAgentScreen({super.key});
  @override
  State<SellerAgentScreen> createState() => _SellerAgentScreenState();
}

/// Strict bn: every number on the p1 screens is shown in Bangla digits
/// (reuses messaging/date_separators.localDigits; a no-op for English).
String bd(BuildContext c, Object? s) =>
    localDigits('${s ?? ''}', Localizations.localeOf(c).languageCode);

/// Back to ASCII digits before a number is sent to the server.
String asciiDigits(String s) => s.replaceAllMapped(
    RegExp('[\u09E6-\u09EF]'), (m) => String.fromCharCode(m[0]!.codeUnitAt(0) - 0x09E6 + 0x30));

/// A server 4xx carries an honest bn/en `detail` — show it; anything else
/// gets the shared honest failure line.
String baErrorText(AppLocalizations t, Object e) {
  if (e is ApiException && (e.status ?? 0) >= 400 && (e.status ?? 0) < 500 &&
      e.message.isNotEmpty) {
    return e.message;
  }
  return honestFailText(t, e);
}

String baChannelLabel(AppLocalizations t, String kind) {
  switch (kind) {
    case 'messenger':
      return t.baChMessenger;
    case 'instagram':
      return t.baChInstagram;
    case 'whatsapp_cloud':
      return t.baChWhatsapp;
    case 'website':
      return t.g1WidgetTitle; // g1: website chat widget
    default:
      return kind;
  }
}

IconData baChannelIcon(String kind) {
  switch (kind) {
    case 'instagram':
      return Icons.camera_alt_outlined;
    case 'whatsapp_cloud':
      return Icons.chat_outlined;
    case 'website':
      return Icons.language_outlined;
    default:
      return Icons.forum_outlined;
  }
}

class _SellerAgentScreenState extends State<SellerAgentScreen> {
  bool _loading = true;
  Object? _error;
  Map<String, dynamic> _setup = const {};
  Map<String, dynamic> _reports = const {};
  bool _busy = false;

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
      final s = await api.bizAgentSetup();
      Map<String, dynamic> r = const {};
      try {
        r = await api.bizAgentReports();
      } catch (_) {
        r = const {};
      }
      if (!mounted) return;
      setState(() {
        _setup = s;
        _reports = r;
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

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(bd(context, m))));

  Future<void> _toggleAi(bool on) async {
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      await context.read<AppState>().api.bizAgentSaveSettings({'ai_enabled': on});
      _snack(on ? t.baAiOnDone : t.baAiOffDone);
    } catch (e) {
      _snack(baErrorText(t, e));
    }
    if (mounted) setState(() => _busy = false);
    await _load();
  }

  Future<void> _trial() async {
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      await context.read<AppState>().api.bizAgentStartTrial();
      _snack(t.baTrialStarted);
    } catch (e) {
      _snack(baErrorText(t, e));
    }
    if (mounted) setState(() => _busy = false);
    await _load();
  }

  Future<void> _buy(String plan) async {
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final r = await context.read<AppState>().api.bizAgentCheckout(plan);
      final url = (r['redirect_url'] ?? '').toString();
      if (url.isNotEmpty) {
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      } else {
        _snack(t.baCheckoutNoLink);
      }
    } catch (e) {
      _snack(baErrorText(t, e));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _open(Widget w) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.baTitle), actions: [
        IconButton(
          tooltip: t.baSetupTitle,
          icon: const Icon(Icons.tune_outlined),
          onPressed: _loading ? null : () => _open(const SellerSetupScreen()),
        ),
      ]),
      body: _body(t),
    );
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
    final settings = (_setup['settings'] as Map?) ?? const {};
    final channels = ((_setup['channels'] as List?) ?? const []).cast<Map>();
    final connected = channels.where((c) => c['status'] == 'connected').toList();
    final pending = (_setup['pending_approvals'] as num?)?.toInt() ?? 0;
    final meta = (_setup['meta_ready'] as Map?) ?? const {};
    final aiOn = settings['ai_enabled'] == true;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(Gap.lg), children: [
        _planCard(t),
        const SizedBox(height: Gap.md),
        BizCard(
          title: t.baAgentCardTitle,
          icon: Icons.smart_toy_outlined,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: aiOn,
              title: Text(t.baAiSwitch),
              subtitle: Text(aiOn ? t.baAiOnSub : t.baAiOffSub),
              onChanged: _busy ? null : _toggleAi,
            ),
            const SizedBox(height: Gap.sm),
            if (connected.isEmpty)
              BizNote(text: t.baNoChannelNote, icon: Icons.link_off, tint: Brand.warning)
            else
              Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
                for (final c in channels)
                  BizStatusChip(
                    label: bd(context, '${baChannelLabel(t, '${c['kind']}')} · ${c['display_name'] ?? ''}'),
                    color: c['status'] == 'connected' && c['enabled'] == true
                        ? Brand.success
                        : (c['status'] == 'error' ? Brand.danger : Brand.warning),
                  ),
              ]),
            if (meta['secret'] != true) ...[
              const SizedBox(height: Gap.sm),
              BizNote(text: t.baMetaPendingNote, icon: Icons.hourglass_top_outlined),
            ],
            const SizedBox(height: Gap.sm),
            BizNote(text: t.baHonestNote, icon: Icons.verified_user_outlined),
          ]),
        ),
        const SizedBox(height: Gap.md),
        Card(
          child: Column(children: [
            ListTile(
              leading: const Icon(Icons.fact_check_outlined),
              title: Text(t.baApprovalsTitle),
              subtitle: Text(bd(context, pending > 0 ? t.baApprovalsPending(pending) : t.baApprovalsNone)),
              trailing: pending > 0
                  ? Badge(label: Text(bd(context, pending)), child: const Icon(Icons.chevron_right))
                  : const Icon(Icons.chevron_right),
              onTap: () => _open(const ApprovalsScreen()),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.inbox_outlined),
              title: Text(t.baInboxTitle),
              subtitle: Text(t.baInboxSub),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _open(const SellerInboxScreen()),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.schedule_outlined),
              title: Text(t.g1BehaviourTitle),
              subtitle: Text(t.g1BehaviourSub),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _open(const AgentBehaviourScreen()),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.bolt_outlined),
              title: Text(t.g1AnswersTitle),
              subtitle: Text(t.g1AnswersSub),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _open(const AgentAnswersScreen()),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.insights_outlined),
              title: Text(t.g1ReportTitle),
              subtitle: Text(t.g1ReportSub),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _open(const AgentReportScreen()),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.tune_outlined),
              title: Text(t.baSetupTitle),
              subtitle: Text(t.baSetupSub),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _open(const SellerSetupScreen()),
            ),
          ]),
        ),
        const SizedBox(height: Gap.md),
        _todayCard(t),
      ]),
    );
  }

  Widget _planCard(AppLocalizations t) {
    final p = (_setup['plan'] as Map?) ?? const {};
    final active = p['active'] == true;
    final plan = '${p['plan'] ?? 'none'}';
    final left = (p['left'] as num?)?.toInt() ?? 0;
    final quota = (p['quota'] as num?)?.toInt() ?? 0;
    final creditReplies = (p['credit_replies'] as num?)?.toInt() ?? 0;
    final plans = ((p['plans'] as List?) ?? const []).cast<Map>();
    final trialOk = p['trial_available'] == true;
    final canBuy = p['purchasable'] == true;
    final name = plan == 'trial'
        ? t.baPlanTrial
        : plan == 'starter'
            ? t.baPlanStarter
            : plan == 'pro'
                ? t.baPlanPro
                : t.baPlanNone;
    return BizCard(
      title: t.baPlanTitle,
      icon: Icons.workspace_premium_outlined,
      trailing: BizStatusChip(label: name, color: active ? Brand.success : Brand.warning),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (active) ...[
          Text(bd(context, t.baRepliesLeft(left, quota)),
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Gap.sm),
          LinearProgressIndicator(
              value: quota > 0 ? (quota - left) / quota : 0, minHeight: 6,
              borderRadius: BorderRadius.circular(Radii.pill)),
          const SizedBox(height: Gap.sm),
        ] else
          Text(t.baNoPlanLine, style: const TextStyle(height: 1.4)),
        Text(bd(context, t.baCreditReplies(creditReplies)),
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: Gap.md),
        if (trialOk)
          FilledButton.icon(
            onPressed: _busy ? null : _trial,
            icon: const Icon(Icons.rocket_launch_outlined),
            label: Text(bd(context, t.baStartTrial((p['trial_days'] as num?)?.toInt() ?? 7,
                (p['trial_replies'] as num?)?.toInt() ?? 100))),
          ),
        const SizedBox(height: Gap.sm),
        if (!canBuy && !active)
          BizNote(text: t.baBuyNotReady, icon: Icons.payments_outlined),
        for (final pl in canBuy ? plans : const <Map>[])
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.sm),
            child: OutlinedButton(
              onPressed: _busy ? null : () => _buy('${pl['id']}'),
              child: Text(bd(context, t.baBuyPlan(
                  pl['id'] == 'pro' ? t.baPlanPro : t.baPlanStarter,
                  '${pl['price']}',
                  (pl['replies'] as num?)?.toInt() ?? 0))),
            ),
          ),
      ]),
    );
  }

  Widget _todayCard(AppLocalizations t) {
    final d = (_reports['today'] as Map?) ?? const {};
    final low = ((d['low_stock'] as List?) ?? const []).cast<Map>();
    return BizCard(
      title: t.baTodayTitle,
      icon: Icons.insights_outlined,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: Gap.lg, runSpacing: Gap.sm, children: [
          _stat(t.baStatOrders, '${d['orders'] ?? 0}'),
          _stat(t.baStatRevenue, '৳${d['revenue'] ?? 0}'),
          _stat(t.baStatMessages, '${d['messages'] ?? 0}'),
          _stat(t.baStatAiReplies, '${d['ai_replies'] ?? 0}'),
        ]),
        if (low.isNotEmpty) ...[
          const SizedBox(height: Gap.md),
          Text(t.baLowStockTitle, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.xs),
          for (final x in low.take(5))
            Text(bd(context, t.baLowStockLine('${x['name']}', (x['stock'] as num?)?.toInt() ?? 0))),
        ],
      ]),
    );
  }

  Widget _stat(String label, String value) => ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 120),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(bd(context, value),
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700)),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ]),
      );
}
