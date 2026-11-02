import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../bizagent_api.dart';
import '../../../l10n/app_localizations.dart';
import '../../../state.dart';
import '../../../theme.dart';
import '../../../widgets/app_sheet.dart' show withNavBarInset;
import '../../../widgets/skeleton.dart';
import 'seller_agent_screen.dart' show baErrorText, bd;
import 'seller_inbox_screen.dart' show SellerChatScreen;
import 'seller_setup_screen.dart';

/// salesbar — the shop's activity log for the AI sales assistant: who took a
/// chat over or gave it back, approvals, setting changes, STOP / START,
/// limits hit, comments held for Meta's permission. Never message text or
/// tokens (the server stores none). Rows that belong to a chat open it.
class SellerActivityScreen extends StatefulWidget {
  const SellerActivityScreen({super.key});
  @override
  State<SellerActivityScreen> createState() => _SellerActivityScreenState();
}

/// Plain-language label for one audit action ('' = unknown, row hidden).
String sbActionLabel(AppLocalizations t, String a) {
  switch (a) {
    case 'takeover':
      return t.sbActTakeover;
    case 'handback':
      return t.sbActHandback;
    case 'handback_idle':
      return t.sbActHandbackIdle;
    case 'owner_reply':
      return t.sbActOwnerReply;
    case 'approve':
      return t.sbActApprove;
    case 'reject':
      return t.sbActReject;
    case 'settings':
      return t.sbActSettings;
    case 'template':
      return t.sbActTemplate;
    case 'channel_connect':
      return t.sbActChannelConnect;
    case 'channel_disconnect':
      return t.sbActChannelDisconnect;
    case 'channel_on':
      return t.sbActChannelOn;
    case 'channel_off':
      return t.sbActChannelOff;
    case 'opt_out':
      return t.sbActOptOut;
    case 'opt_in':
      return t.sbActOptIn;
    case 'comment_held':
      return t.sbActCommentHeld;
    case 'cap_daily_ai':
      return t.sbActCapDaily;
    case 'cap_thread':
      return t.sbActCapThread;
    case 'burst':
      return t.sbActBurst;
    case 'draft_order':
      return t.sbActDraftOrder;
    case 'draft_confirm':
      return t.sbActDraftConfirm;
    case 'draft_cancel':
      return t.sbActDraftCancel;
    default:
      return '';
  }
}

IconData _icon(String a) {
  if (a.startsWith('channel')) return Icons.hub_rounded;
  if (a.startsWith('cap') || a == 'burst') return Icons.speed_rounded;
  if (a.startsWith('draft')) return Icons.receipt_long_rounded;
  if (a == 'opt_out' || a == 'opt_in') return Icons.notifications_off_rounded;
  if (a == 'settings') return Icons.tune_rounded;
  if (a == 'comment_held') return Icons.comment_rounded;
  if (a == 'approve' || a == 'reject') return Icons.fact_check_rounded;
  return Icons.support_agent_rounded;
}

class _SellerActivityScreenState extends State<SellerActivityScreen> {
  bool _loading = true;
  Object? _error;
  List<Map> _rows = const [];

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
      final r = await context.read<AppState>().api.bizAgentAudit();
      if (!mounted) return;
      setState(() {
        _rows = ((r['audit'] as List?) ?? const []).cast<Map>();
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

  String _when(String iso) {
    final d = DateTime.tryParse(iso)?.toLocal();
    if (d == null) return '';
    String two(int n) => n.toString().padLeft(2, '0');
    return bd(context, '${d.day}/${d.month}/${d.year} ${two(d.hour)}:${two(d.minute)}');
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.sbActivityTitle)),
      body: RefreshIndicator(onRefresh: _load, child: _body(t)),
    );
  }

  Widget _body(AppLocalizations t) {
    if (_loading) return const SkeletonList();
    if (_error != null) {
      return ListView(children: [
        StateMessage(
          icon: Icons.cloud_off_rounded,
          title: t.bizLoadFailed,
          message: baErrorText(t, _error!),
          action: FilledButton(onPressed: _load, child: Text(t.bizRetry)),
        ),
      ]);
    }
    final rows = _rows.where((r) => sbActionLabel(t, '${r['action']}').isNotEmpty).toList();
    if (rows.isEmpty) {
      return ListView(padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)), children: [
        StateMessage(
          icon: Icons.history_rounded,
          title: t.sbActivityEmptyTitle,
          message: '${t.sbActivityEmptyBenefit}\n\n${t.sbActivityEmptyHow}',
          action: FilledButton.icon(
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const SellerSetupScreen())),
            icon: const Icon(Icons.tune_rounded),
            label: Text(t.baSetupTitle),
          ),
        ),
      ]);
    }
    return ListView.separated(
      padding: withNavBarInset(context, const EdgeInsets.symmetric(vertical: Gap.sm)),
      itemCount: rows.length + 1,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.sm),
            child: Text(t.sbActivityNote, style: Theme.of(context).textTheme.bodySmall),
          );
        }
        final r = rows[i - 1];
        final a = '${r['action']}';
        final tid = (r['thread_id'] as num?)?.toInt();
        final who = r['actor'] == true ? t.sbActByYou : t.sbActByAssistant;
        return ListTile(
          minVerticalPadding: Gap.sm,
          leading: Icon(_icon(a)),
          title: Text(sbActionLabel(t, a)),
          subtitle: Text('$who · ${_when('${r['created_at']}')}'),
          trailing: tid == null ? null : const Icon(Icons.chevron_right_rounded),
          onTap: tid == null
              ? null
              : () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => SellerChatScreen(threadId: tid))),
        );
      },
    );
  }
}
