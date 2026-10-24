import 'package:flutter/material.dart';
import '../../theme.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/crm_aftersale_api.dart';
import '../../widgets/crm_aftersale_widgets.dart';
import 'crm_common.dart';

/// Axon ERP implementation HAND-OFF record (CRM_SPEC §7) — DESIGN / LINK ONLY.
///
/// This screen NEVER touches Asalify/ERP. With no ERP link connected the server
/// returns `erp_state=needs_erp_link` and the hand-off is saved locally, NOT
/// sent — surfaced here honestly (same needs-key pattern used across the CRM).
class CrmErpHandoffScreen extends StatefulWidget {
  final int org;
  final Map<String, dynamic> deal;
  const CrmErpHandoffScreen({super.key, required this.org, required this.deal});
  @override
  State<CrmErpHandoffScreen> createState() => _CrmErpHandoffScreenState();
}

class _CrmErpHandoffScreenState extends State<CrmErpHandoffScreen> {
  Map<String, dynamic> _rec = {};
  bool _loading = true;
  CrmError? _error;

  int get _dealId => (widget.deal['id'] as num).toInt();

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
      _rec = await CrmAfterSaleApi.of(context).erpHandoff(_dealId);
    } catch (e) {
      _error = CrmError.from(e);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _transition(String action) async {
    try {
      await CrmAfterSaleApi.of(context).erpHandoffTransition(_dealId, action);
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('${CrmError.from(e).textFor(context)}')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.crmErpHandoff)),
      body: _loading
          ? const CrmStateView.loading()
          : _error != null
              ? CrmStateView.error(
                  error: _error!, title: t.loadFailed, onRetry: _load)
              : _body(t),
    );
  }

  Widget _body(AppLocalizations t) {
    final state = (_rec['state'] ?? 'not_started').toString();
    final erpLinked = (_rec['erp_state'] ?? 'needs_erp_link') == 'linked';
    final modules = (_rec['modules'] as List?) ?? [];
    final actions = _nextActions(state);
    return ListView(padding: const EdgeInsets.all(Gap.md), children: [
      if (!erpLinked)
        NeedsKeyBanner(t.crmErpNotLinked, icon: Icons.link_off_outlined),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                  child: Text((_rec['company'] ?? '').toString(),
                      style: AType.titleMedium.copyWith(fontWeight: FontWeight.w800))),
              CrmStatusPill(_stateLabel(t, state), tone: _stateTone(state)),
            ]),
            const SizedBox(height: Gap.sm),
            CrmSectionHeader(t.crmErpModules, icon: Icons.widgets_outlined),
            Wrap(spacing: Gap.xs, children: [
              for (final m in modules)
                Chip(label: Text(m.toString())),
            ]),
            const SizedBox(height: Gap.sm),
            if ((_rec['order_total_poisha'] as num? ?? 0) > 0)
              CrmMoneyRow(t.crmOrderTotal,
                  bdtFromPoisha(_rec['order_total_poisha'] as num?),
                  bold: true),
          ]),
        ),
      ),
      if (actions.isNotEmpty) ...[
        const SizedBox(height: Gap.sm),
        Wrap(spacing: Gap.xs, children: [
          for (final a in actions)
            FilledButton.tonal(
                onPressed: () => _transition(a),
                child: Text(_actionLabel(t, a))),
        ]),
      ],
      const SizedBox(height: Gap.md),
      Text(t.crmErpDesignOnlyNote,
          style: AType.bodySmall.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
    ]);
  }

  List<String> _nextActions(String state) {
    switch (state) {
      case 'not_started':
        return ['prepare'];
      case 'preparing':
        return ['submit'];
      case 'submitted':
        return ['accept', 'reject'];
      case 'accepted':
        return ['complete'];
      case 'rejected':
        return ['prepare'];
      default:
        return [];
    }
  }

  String _actionLabel(AppLocalizations t, String a) {
    switch (a) {
      case 'prepare':
        return t.crmErpPrepare;
      case 'submit':
        return t.crmErpSubmit;
      case 'accept':
        return t.crmErpAccept;
      case 'reject':
        return t.crmErpReject;
      case 'complete':
        return t.crmErpComplete;
      default:
        return a;
    }
  }

  String _stateLabel(AppLocalizations t, String s) {
    switch (s) {
      case 'preparing':
        return t.crmErpPreparing;
      case 'submitted':
        return t.crmErpSubmitted;
      case 'accepted':
        return t.crmErpAccepted;
      case 'rejected':
        return t.crmErpRejected;
      case 'completed':
        return t.crmErpCompleted;
      default:
        return t.crmErpNotStarted;
    }
  }

  CrmStatusTone _stateTone(String s) {
    switch (s) {
      case 'completed':
      case 'accepted':
        return CrmStatusTone.success;
      case 'rejected':
        return CrmStatusTone.danger;
      case 'submitted':
      case 'preparing':
        return CrmStatusTone.info;
      default:
        return CrmStatusTone.neutral;
    }
  }
}
