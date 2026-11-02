import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../messaging/connect_flow.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart';
import 'market_source.dart';
import 'market_widgets.dart';

/// amarket: one need, role-aware.
///  * buyer: every offer ranked by the SERVER (price 50 / delivery 20 /
///    rating 20 / distance 10), the plain-language reason for each, the
///    cheapest always shown and marked; accept -> COD deal + chat; cancel.
///  * group-buy joiner: the same ranking (read-only), change quantity, leave.
///  * anyone else on an open group-buy: join with a quantity.
///  * an approved seller: the need (buyer hidden) + ONLY their own sealed
///    offer: send / update / withdraw.
class MarketNeedScreen extends StatefulWidget {
  final MarketSource source;
  final int needId;
  const MarketNeedScreen({super.key, required this.source, required this.needId});

  @override
  State<MarketNeedScreen> createState() => _MarketNeedScreenState();
}

class _MarketNeedScreenState extends State<MarketNeedScreen> {
  Map<String, dynamic>? _n;
  Object? _err;
  bool _busy = false;
  final _price = TextEditingController();
  final _hours = TextEditingController(text: '24');
  final _notes = TextEditingController();
  final _joinQty = TextEditingController(text: '1');

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [_price, _hours, _notes, _joinQty]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _err = null);
    try {
      final n = await widget.source.need(widget.needId);
      final mine = (n['my_bid'] as Map?)?.cast<String, dynamic>();
      if (mine != null && _price.text.isEmpty) {
        _price.text = '${((mine['unit_price'] as num?) ?? 0) ~/ 100}';
        _hours.text = '${mine['delivery_hours'] ?? 24}';
        _notes.text = '${mine['notes'] ?? ''}';
      }
      if (n['joined_qty'] != null) _joinQty.text = '${n['joined_qty']}';
      if (mounted) setState(() => _n = n);
    } catch (e) {
      if (mounted) setState(() => _err = e);
    }
  }

  Future<void> _act(String action, [Map<String, dynamic> body = const {}, String? ok]) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.source.needAct(widget.needId, action, body);
      if (ok != null && mounted) mkSnack(context, ok);
      await _load();
    } catch (e) {
      if (mounted) mkSnack(context, mkMessage(context, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _accept(Map<String, dynamic> b) async {
    final t = AppLocalizations.of(context);
    final yes = await showAppSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Padding(
        key: const Key('amk-accept-sheet'),
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(t.amkAcceptTitle('${b['seller_name']}'), style: Theme.of(ctx).textTheme.titleMedium),
          const SizedBox(height: Gap.sm),
          Text(t.amkAcceptBody(mkTaka(ctx, b['total']))),
          const SizedBox(height: Gap.lg),
          FilledButton(
            key: const Key('amk-accept-yes'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.amkAcceptYes),
          ),
          TextButton(
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.amkKeep),
          ),
        ]),
      ),
    );
    if (yes != true || _busy || !mounted) return;
    setState(() => _busy = true);
    try {
      final r = await widget.source.needAct(widget.needId, 'accept', {'bid_id': b['id']});
      final deals = mkList(r['deals']);
      await _load();
      if (!mounted) return;
      mkSnack(context, t.amkDealDone);
      if (deals.isNotEmpty) {
        final c = await widget.source.dealChat(deals.first['id'] as int);
        final m = (c['member'] as Map?)?.cast<String, dynamic>();
        if (m != null && mounted) await ConnectFlow.openChat(context, m);
      }
    } catch (e) {
      if (mounted) mkSnack(context, mkMessage(context, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancelNeed() async {
    final t = AppLocalizations.of(context);
    final yes = await showAppSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(t.amkCancelNeedTitle, style: Theme.of(ctx).textTheme.titleMedium),
          const SizedBox(height: Gap.lg),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.amkCancelNeed),
          ),
          TextButton(
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.amkKeep),
          ),
        ]),
      ),
    );
    if (yes == true) await _act('cancel', const {}, t.amkNeedCancelled);
  }

  Widget _header(AppLocalizations t, Map<String, dynamic> n) {
    final cs = Theme.of(context).colorScheme;
    final deadline = DateTime.tryParse('${n['deadline']}')?.toLocal();
    final lines = <String>[
      '${n['category_label']} · ${n['area_label']}',
      t.amkQtyLine(mkNum(context, n['quantity']), '${n['unit_label']}'),
      if ((n['total_quantity'] ?? 0) != n['quantity'])
        t.amkTotalQty(mkNum(context, n['total_quantity']), mkNum(context, n['joiners'] ?? 0)),
      if (deadline != null)
        t.amkDeadlineAt(mkNum(context,
            '${deadline.day}/${deadline.month} ${deadline.hour.toString().padLeft(2, '0')}:${deadline.minute.toString().padLeft(2, '0')}')),
      if (n['budget_max'] != null || n['budget_min'] != null)
        t.amkBudgetLine(n['budget_min'] != null ? mkTaka(context, n['budget_min']) : '—',
            n['budget_max'] != null ? mkTaka(context, n['budget_max']) : '—'),
      if (n['km'] != null) t.amkKmAway(mkNum(context, n['km'])),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text('${n['title']}', style: Theme.of(context).textTheme.titleMedium)),
            const SizedBox(width: Gap.sm),
            MkBadge(mkStatusLabel(t, '${n['status']}'), color: cs.surfaceContainerHighest, onColor: cs.onSurface),
          ]),
          if ('${n['description'] ?? ''}'.isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            Text('${n['description']}'),
          ],
          const SizedBox(height: Gap.sm),
          for (final l in lines) Text(l),
          if (n['hidden'] == true) ...[
            const SizedBox(height: Gap.sm),
            Text(t.amkHiddenByReports, style: TextStyle(color: cs.error)),
          ],
        ]),
      ),
    );
  }

  Widget _ranking(AppLocalizations t, Map<String, dynamic> n) {
    final cs = Theme.of(context).colorScheme;
    final rk = (n['ranking'] as Map?)?.cast<String, dynamic>() ?? const {};
    final bids = mkList(rk['bids']);
    final canAccept = n['can_accept'] == true;
    if (bids.isEmpty) {
      return MkEmpty(
        key: const Key('amk-no-offers'),
        icon: Icons.hourglass_empty_rounded,
        title: t.amkNoOffersTitle,
        benefit: n['mine'] == true ? t.amkNoOffersBenefit : t.amkNoOffersJoiner,
        howTo: t.amkNoOffersHow,
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Card(
        color: cs.primaryContainer,
        child: Padding(
          key: const Key('amk-summary'),
          padding: const EdgeInsets.all(Gap.md),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.auto_awesome_rounded, color: cs.onPrimaryContainer),
              const SizedBox(width: Gap.sm),
              Expanded(
                  child: Text(t.amkWhyTitle,
                      style: TextStyle(fontWeight: FontWeight.w600, color: cs.onPrimaryContainer))),
            ]),
            const SizedBox(height: Gap.xs),
            Text('${rk['summary'] ?? ''}', style: TextStyle(color: cs.onPrimaryContainer)),
            const SizedBox(height: Gap.xs),
            Text(t.amkNoAiNeeded, style: TextStyle(color: cs.onPrimaryContainer, fontSize: 12)),
          ]),
        ),
      ),
      for (final b in bids)
        Card(
          key: Key('amk-bid-${b['id']}'),
          shape: b['recommended'] == true
              ? RoundedRectangleBorder(
                  side: BorderSide(color: cs.primary, width: 2), borderRadius: BorderRadius.circular(12))
              : null,
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  flex: 3,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${b['seller_name']}', style: Theme.of(context).textTheme.titleSmall),
                    Text('${b['seller_area'] ?? ''}', style: TextStyle(color: cs.onSurfaceVariant)),
                  ]),
                ),
                const SizedBox(width: Gap.sm),
                Flexible(
                  flex: 2,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(mkTaka(context, b['total']),
                        textAlign: TextAlign.end, style: Theme.of(context).textTheme.titleMedium),
                    Text(t.amkPerUnit(mkTaka(context, b['unit_price'])),
                        textAlign: TextAlign.end, style: TextStyle(color: cs.onSurfaceVariant)),
                  ]),
                ),
              ]),
              const SizedBox(height: Gap.xs),
              Wrap(spacing: Gap.xs, runSpacing: Gap.xs, children: [
                if (b['recommended'] == true) MkBadge(t.amkSuggested, color: cs.primary, onColor: cs.onPrimary),
                if (b['cheapest'] == true)
                  MkBadge(t.amkLowest, color: cs.tertiaryContainer, onColor: cs.onTertiaryContainer),
                if (b['fastest'] == true && bids.length > 1)
                  MkBadge(t.amkFastest, color: cs.secondaryContainer, onColor: cs.onSecondaryContainer),
                if (b['over_budget'] == true)
                  MkBadge(t.amkOverBudget, color: cs.errorContainer, onColor: cs.onErrorContainer),
                MkBadge(t.amkScore(mkNum(context, b['score'])), color: cs.surfaceContainerHighest, onColor: cs.onSurface),
              ]),
              const SizedBox(height: Gap.xs),
              for (final r in (b['reasons'] as List? ?? const [])) Text('• $r'),
              if ('${b['notes'] ?? ''}'.isNotEmpty) ...[
                const SizedBox(height: Gap.xs),
                Text(t.amkSellerNote('${b['notes']}'), style: const TextStyle(fontStyle: FontStyle.italic)),
              ],
              const SizedBox(height: Gap.sm),
              Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
                if (canAccept && b['status'] == 'active')
                  FilledButton(
                    key: Key('amk-accept-${b['id']}'),
                    style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                    onPressed: _busy ? null : () => _accept(b),
                    child: Text(t.amkTakeOffer),
                  ),
                if (b['status'] == 'accepted')
                  MkBadge(t.amkStAccepted, color: cs.primaryContainer, onColor: cs.onPrimaryContainer),
                TextButton(
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => mkReportOrBlock(context, widget.source, 'bid', b['id'] as int, onDone: _load),
                  child: Text(t.amkReportBlock),
                ),
              ]),
            ]),
          ),
        ),
    ]);
  }

  Widget _bidForm(AppLocalizations t, Map<String, dynamic> n) {
    final mine = (n['my_bid'] as Map?)?.cast<String, dynamic>();
    final canBid = n['can_bid'] == true;
    final cs = Theme.of(context).colorScheme;
    final digits = [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(8)];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(mine == null ? t.amkYourOfferTitle : t.amkYourOfferEdit, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: Gap.xs),
          Text(t.amkSealedNote, style: TextStyle(color: cs.onSurfaceVariant)),
          if (mine != null && mine['status'] != 'active') ...[
            const SizedBox(height: Gap.xs),
            Text(mkStatusLabel(t, '${mine['status']}')),
          ],
          const SizedBox(height: Gap.md),
          TextField(
            key: const Key('amk-b-price'),
            controller: _price,
            enabled: canBid,
            onChanged: (_) => setState(() {}),
            keyboardType: TextInputType.number,
            inputFormatters: digits,
            decoration: InputDecoration(
                labelText: t.amkUnitPrice('${n['unit_label']}'), prefixText: '৳ ', border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            key: const Key('amk-b-hours'),
            controller: _hours,
            enabled: canBid,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(3)],
            decoration: InputDecoration(labelText: t.amkDeliveryHours, border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            key: const Key('amk-b-notes'),
            controller: _notes,
            enabled: canBid,
            maxLength: 300,
            decoration: InputDecoration(labelText: t.amkNotes, hintText: t.amkNotesHint, border: const OutlineInputBorder()),
          ),
          if (_price.text.isNotEmpty && int.tryParse(_price.text) != null)
            Text(t.amkBidTotal(mkTaka(context, int.parse(_price.text) * 100 * ((n['total_quantity'] as num?) ?? 1)))),
          const SizedBox(height: Gap.sm),
          FilledButton(
            key: const Key('amk-b-send'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: !canBid || _busy
                ? null
                : () => _act('bid', {
                      'unit_price': int.tryParse(_price.text.trim()),
                      'delivery_hours': int.tryParse(_hours.text.trim()),
                      'notes': _notes.text.trim(),
                    }, t.amkOfferSent),
            child: Text(mine == null ? t.amkSendOffer : t.amkUpdateOffer),
          ),
          if (mine != null && mine['status'] == 'active')
            TextButton(
              style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: _busy ? null : () => _act('withdraw', const {}, t.amkOfferWithdrawn),
              child: Text(t.amkWithdraw),
            ),
          if (!canBid) Text(t.amkBiddingClosed, style: TextStyle(color: cs.onSurfaceVariant)),
        ]),
      ),
    );
  }

  Widget _joinBox(AppLocalizations t, Map<String, dynamic> n) {
    final joined = n['joined_qty'] != null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(joined ? t.amkJoinedTitle : t.amkJoinTitle, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: Gap.xs),
          Text(t.amkJoinNote),
          const SizedBox(height: Gap.md),
          TextField(
            key: const Key('amk-j-qty'),
            controller: _joinQty,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
            decoration: InputDecoration(
                labelText: t.amkMyQty('${n['unit_label']}'), border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.sm),
          FilledButton(
            key: const Key('amk-j-send'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: _busy || n['bidding_open'] != true
                ? null
                : () => _act('join', {'quantity': int.tryParse(_joinQty.text.trim())}, t.amkJoined),
            child: Text(joined ? t.amkUpdateQty : t.amkJoin),
          ),
          if (joined)
            TextButton(
              style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: _busy || n['status'] != 'open' ? null : () => _act('leave', const {}, t.amkLeft),
              child: Text(t.amkLeave),
            ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final n = _n;
    Widget body;
    if (n == null) {
      body = _err != null ? MkError(error: _err!, onRetry: _load) : const Center(child: CircularProgressIndicator());
    } else {
      final mine = n['mine'] == true;
      final joined = n['joined_qty'] != null;
      final sellerView = !mine && !joined && (n['can_bid'] == true || n['my_bid'] != null);
      body = RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: withNavBarInset(context, const EdgeInsets.all(Gap.md)),
          children: [
            _header(t, n),
            if (mine || joined) _ranking(t, n),
            if (joined || (!mine && !sellerView && n['group_open'] == true)) _joinBox(t, n),
            if (sellerView) _bidForm(t, n),
            if (mine && n['status'] == 'open')
              OutlinedButton(
                key: const Key('amk-cancel-need'),
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                onPressed: _busy ? null : _cancelNeed,
                child: Text(t.amkCancelNeed),
              ),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(t.amkNeedTitle),
        actions: [
          if (n != null && n['mine'] != true)
            IconButton(
              tooltip: t.amkReportBlock,
              icon: const Icon(Icons.flag_outlined),
              onPressed: () => mkReportOrBlock(context, widget.source, 'need', widget.needId, onDone: _load),
            ),
        ],
      ),
      body: body,
    );
  }
}
