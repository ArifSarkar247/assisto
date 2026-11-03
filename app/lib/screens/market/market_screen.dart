import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../messaging/connect_flow.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart';
import '../business_screen.dart';
import 'market_need_form.dart';
import 'market_need_screen.dart';
import 'market_source.dart';
import 'market_widgets.dart';

/// ASSISTO MARKET v1 (flag `assisto_market`, default OFF; route 'market').
/// A buyer posts a NEED; only owner-approved Business sellers send SEALED
/// offers; the server ranks them with transparent weights and explains the
/// choice in plain language (never hiding the cheapest); the buyer accepts ->
/// cash-on-delivery deal + My Circle chat. Group-buy: join someone's need.
/// No payments and no fees in the app. Dhaka areas only.
class MarketScreen extends StatefulWidget {
  final MarketSource? source;
  final int initialTab;
  const MarketScreen({super.key, this.source, this.initialTab = 0});

  @override
  State<MarketScreen> createState() => _MarketScreenState();
}

class _MarketScreenState extends State<MarketScreen> {
  late final MarketSource _src = widget.source ?? ApiMarketSource(context.read<AppState>().api);

  Map<String, dynamic>? _ov;
  Object? _err;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      _ov = await _src.overview();
    } catch (e) {
      _err = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  List<Map<String, dynamic>> _opts(String k) => mkList(_ov?[k]);

  Future<void> _newNeed({bool group = false}) async {
    final ov = _ov;
    if (ov == null) return;
    final id = await Navigator.of(context).push<int>(MaterialPageRoute(
        builder: (_) => MarketNeedForm(source: _src, catalogue: ov, groupDefault: group)));
    await _load();
    if (id != null && mounted) await _open(id);
  }

  Future<void> _open(int id) async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => MarketNeedScreen(source: _src, needId: id)));
    if (mounted) _load();
  }

  void _guide() {
    final t = AppLocalizations.of(context);
    showAppSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SingleChildScrollView(
        key: const Key('amk-guide'),
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xl),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.amkGuideTitle, style: Theme.of(ctx).textTheme.titleMedium),
          const SizedBox(height: Gap.md),
          for (final line in [t.amkGuide1, t.amkGuide2, t.amkGuide3, t.amkGuide4, t.amkGuide5])
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.sm),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Padding(
                    padding: EdgeInsets.only(top: 2, right: Gap.sm),
                    child: Icon(Icons.check_circle_outline_rounded, size: 18)),
                Expanded(child: Text(line)),
              ]),
            ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return DefaultTabController(
      length: 4,
      initialIndex: widget.initialTab.clamp(0, 3),
      child: Scaffold(
        appBar: AppBar(
          title: Text(t.amkTitle),
          actions: [
            IconButton(
              key: const Key('amk-guide-btn'),
              tooltip: t.amkGuideTitle,
              icon: const Icon(Icons.help_outline_rounded),
              onPressed: _guide,
            ),
          ],
          bottom: TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [
            Tab(text: t.amkTabNeeds),
            Tab(text: t.amkTabGroup),
            Tab(text: t.amkTabSell),
            Tab(text: t.amkTabDeals),
          ]),
        ),
        body: _loading && _ov == null
            ? const Center(child: CircularProgressIndicator())
            : _err != null && _ov == null
                ? MkError(error: _err!, onRetry: _load)
                : TabBarView(children: [
                    _NeedsTab(ov: _ov!, onNew: _newNeed, onOpen: _open, onRefresh: _load),
                    _GroupTab(src: _src, areas: _opts('areas'), onOpen: _open,
                        onNewGroup: () => _newNeed(group: true)),
                    _SellTab(src: _src, ov: _ov!, onOpen: _open),
                    _DealsTab(src: _src),
                  ]),
      ),
    );
  }
}

// ------------------------------------------------------------------ needs
class _NeedsTab extends StatelessWidget {
  final Map<String, dynamic> ov;
  final Future<void> Function({bool group}) onNew;
  final Future<void> Function(int id) onOpen;
  final Future<void> Function() onRefresh;
  const _NeedsTab({required this.ov, required this.onNew, required this.onOpen, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final needs = mkList(ov['needs']);
    if (needs.isEmpty) {
      return ListView(children: [
        MkEmpty(
          key: const Key('amk-needs-empty'),
          icon: Icons.campaign_rounded,
          title: t.amkNeedsEmptyTitle,
          benefit: t.amkNeedsEmptyBenefit2,
          button: t.amkPostNeed,
          onPressed: () => onNew(),
          howTo: t.amkNeedsEmptyHow,
        ),
      ]);
    }
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xxxl)),
        children: [
          FilledButton.icon(
            key: const Key('amk-post'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () => onNew(),
            icon: const Icon(Icons.add_rounded),
            label: Text(t.amkPostNeed),
          ),
          const SizedBox(height: Gap.sm),
          Text(t.amkCodNote, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
          const SizedBox(height: Gap.sm),
          for (final n in needs) MkNeedTile(need: n, onTap: () => onOpen(n['id'] as int)),
        ],
      ),
    );
  }
}

class MkNeedTile extends StatelessWidget {
  final Map<String, dynamic> need;
  final VoidCallback onTap;
  final Widget? trailing;
  const MkNeedTile({super.key, required this.need, required this.onTap, this.trailing});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final n = need;
    final qty = '${mkNum(context, n['total_quantity'] ?? n['quantity'])} ${n['unit_label'] ?? ''}';
    final sub = [qty, '${n['area_label'] ?? ''}', '${n['category_label'] ?? ''}'].join(' · ');
    final extra = <String>[
      mkStatusLabel(t, '${n['status']}'),
      if (n['bid_count'] != null) t.amkOffersN(mkNum(context, n['bid_count'])),
      if ((n['joiners'] ?? 0) as int > 0) t.amkJoinersN(mkNum(context, n['joiners'])),
      if (n['km'] != null) t.amkKmAway(mkNum(context, n['km'])),
    ].join(' · ');
    return Card(
      child: ListTile(
        minVerticalPadding: Gap.md,
        onTap: onTap,
        title: Text('${n['title']}', maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text('$sub\n$extra'),
        isThreeLine: true,
        trailing: trailing ?? const Icon(Icons.chevron_right_rounded),
      ),
    );
  }
}

// ------------------------------------------------------------------ group-buy
class _GroupTab extends StatefulWidget {
  final MarketSource src;
  final List<Map<String, dynamic>> areas;
  final Future<void> Function(int id) onOpen;
  final VoidCallback onNewGroup;
  const _GroupTab({required this.src, required this.areas, required this.onOpen, required this.onNewGroup});

  @override
  State<_GroupTab> createState() => _GroupTabState();
}

class _GroupTabState extends State<_GroupTab> with AutomaticKeepAliveClientMixin {
  String _area = '';
  List<Map<String, dynamic>>? _rows;
  Object? _err;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _err = null);
    try {
      final r = await widget.src.group(_area);
      if (mounted) setState(() => _rows = r);
    } catch (e) {
      if (mounted) setState(() => _err = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final t = AppLocalizations.of(context);
    if (_err != null && _rows == null) return MkError(error: _err!, onRetry: _load);
    if (_rows == null) return const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.md)),
        children: [
          Text(t.amkGroupIntro),
          const SizedBox(height: Gap.sm),
          DropdownButtonFormField<String>(
            key: const Key('amk-group-area'),
            isExpanded: true,
            initialValue: _area.isEmpty ? null : _area,
            decoration: InputDecoration(labelText: t.amkMyArea, border: const OutlineInputBorder()),
            items: [
              for (final a in widget.areas)
                DropdownMenuItem(value: '${a['key']}', child: Text('${a['label']}')),
            ],
            onChanged: (v) {
              _area = v ?? '';
              _load();
            },
          ),
          const SizedBox(height: Gap.sm),
          if (_rows!.isEmpty)
            MkEmpty(
              key: const Key('amk-group-empty'),
              icon: Icons.groups_rounded,
              title: t.amkGroupEmptyTitle,
              benefit: t.amkGroupEmptyBenefit,
              button: t.amkStartGroup,
              onPressed: widget.onNewGroup,
              howTo: t.amkGroupEmptyHow,
            )
          else
            for (final n in _rows!)
              MkNeedTile(
                need: n,
                onTap: () async {
                  await widget.onOpen(n['id'] as int);
                  _load();
                },
                trailing: n['joined_qty'] != null
                    ? Icon(Icons.check_circle_rounded, color: Theme.of(context).colorScheme.primary)
                    : null,
              ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ seller
class _SellTab extends StatefulWidget {
  final MarketSource src;
  final Map<String, dynamic> ov;
  final Future<void> Function(int id) onOpen;
  const _SellTab({required this.src, required this.ov, required this.onOpen});

  @override
  State<_SellTab> createState() => _SellTabState();
}

class _SellTabState extends State<_SellTab> with AutomaticKeepAliveClientMixin {
  Map<String, dynamic>? _d;
  Object? _err;
  bool _busy = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _err = null);
    try {
      final d = await widget.src.sell();
      if (mounted) setState(() => _d = d);
    } catch (e) {
      if (mounted) setState(() => _err = e);
    }
  }

  Future<void> _apply() async {
    final seller = (_d?['seller'] as Map?)?.cast<String, dynamic>();
    final res = await showAppSheet<(String, List<String>)>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ApplySheet(
        areas: mkList(widget.ov['areas']),
        categories: mkList(widget.ov['categories']),
        area: '${seller?['area'] ?? ''}',
        selected: [for (final c in (seller?['categories'] as List? ?? const [])) '$c'],
      ),
    );
    if (res == null || _busy) return;
    setState(() => _busy = true);
    try {
      await widget.src.applySeller(res.$1, res.$2);
      if (mounted) mkSnack(context, AppLocalizations.of(context).amkApplied);
      await _load();
    } catch (e) {
      if (mounted) mkSnack(context, mkMessage(context, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final t = AppLocalizations.of(context);
    if (_err != null && _d == null) return MkError(error: _err!, onRetry: _load);
    final d = _d;
    if (d == null) return const Center(child: CircularProgressIndicator());
    final seller = (d['seller'] as Map?)?.cast<String, dynamic>();
    final status = '${seller?['status'] ?? ''}';
    if (d['has_business'] != true && seller == null) {
      return ListView(children: [
        MkEmpty(
          key: const Key('amk-sell-nobiz'),
          icon: Icons.storefront_rounded,
          title: t.amkSellNoBizTitle,
          benefit: t.amkSellBenefit,
          button: t.amkOpenBusiness,
          onPressed: () async {
            await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const BusinessScreen()));
            _load();
          },
          howTo: t.amkSellNoBizHow,
        ),
      ]);
    }
    if (seller == null) {
      return ListView(children: [
        MkEmpty(
          key: const Key('amk-sell-apply'),
          icon: Icons.verified_rounded,
          title: t.amkSellApplyTitle,
          benefit: t.amkSellBenefit,
          button: t.amkApply,
          onPressed: _busy ? null : _apply,
          howTo: t.amkSellApplyHow,
        ),
      ]);
    }
    final needs = mkList(d['needs']);
    final cs = Theme.of(context).colorScheme;
    final banner = switch (status) {
      'approved' => null,
      'pending' => t.amkSellPending,
      'suspended' => t.amkSellSuspended,
      _ => t.amkSellRejected,
    };
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.md)),
        children: [
          Card(
            color: status == 'approved' ? cs.primaryContainer : cs.secondaryContainer,
            child: ListTile(
              key: const Key('amk-seller-card'),
              leading: Icon(status == 'approved' ? Icons.verified_rounded : Icons.hourglass_top_rounded),
              title: Text('${seller['shop_name'] ?? ''}'.isEmpty ? t.amkSellerYou : '${seller['shop_name']}'),
              subtitle: Text([
                banner ?? t.amkSellApproved,
                '${seller['area_label'] ?? ''}',
                if (seller['rating_avg'] != null)
                  t.amkRating(mkNum(context, seller['rating_avg']), mkNum(context, seller['rating_count'])),
              ].join(' · ')),
              trailing: IconButton(
                tooltip: t.amkEditSeller,
                icon: const Icon(Icons.edit_rounded),
                onPressed: _busy ? null : _apply,
              ),
            ),
          ),
          const SizedBox(height: Gap.sm),
          if (status == 'approved' && needs.isEmpty)
            MkEmpty(
              key: const Key('amk-sell-empty'),
              icon: Icons.inbox_rounded,
              title: t.amkSellEmptyTitle,
              benefit: t.amkSellEmptyBenefit,
              button: t.amkEditSeller,
              onPressed: _apply,
            ),
          if (status == 'approved')
            for (final n in needs)
              MkNeedTile(
                need: n,
                onTap: () async {
                  await widget.onOpen(n['id'] as int);
                  _load();
                },
                trailing: n['my_bid'] != null
                    ? MkBadge(t.amkYourOffer, color: cs.tertiaryContainer, onColor: cs.onTertiaryContainer)
                    : null,
              ),
        ],
      ),
    );
  }
}

class _ApplySheet extends StatefulWidget {
  final List<Map<String, dynamic>> areas;
  final List<Map<String, dynamic>> categories;
  final String area;
  final List<String> selected;
  const _ApplySheet({required this.areas, required this.categories, required this.area, required this.selected});

  @override
  State<_ApplySheet> createState() => _ApplySheetState();
}

class _ApplySheetState extends State<_ApplySheet> {
  late String _area = widget.area;
  late final Set<String> _cats = {...widget.selected};

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final ok = _area.isNotEmpty && _cats.isNotEmpty;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.amkApplyTitle, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: Gap.sm),
        Text(t.amkApplyNote),
        const SizedBox(height: Gap.md),
        DropdownButtonFormField<String>(
          key: const Key('amk-apply-area'),
          isExpanded: true,
          initialValue: _area.isEmpty ? null : _area,
          decoration: InputDecoration(labelText: t.amkShopArea, border: const OutlineInputBorder()),
          items: [
            for (final a in widget.areas) DropdownMenuItem(value: '${a['key']}', child: Text('${a['label']}')),
          ],
          onChanged: (v) => setState(() => _area = v ?? ''),
        ),
        const SizedBox(height: Gap.md),
        Text(t.amkWhatYouSell),
        const SizedBox(height: Gap.xs),
        Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
          for (final c in widget.categories)
            FilterChip(
              label: Text('${c['label']}'),
              selected: _cats.contains('${c['key']}'),
              onSelected: (on) => setState(() => on ? _cats.add('${c['key']}') : _cats.remove('${c['key']}')),
            ),
        ]),
        const SizedBox(height: Gap.lg),
        FilledButton(
          key: const Key('amk-apply-send'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: ok ? () => Navigator.pop(context, (_area, _cats.toList())) : null,
          child: Text(t.amkApply),
        ),
      ]),
    );
  }
}

// ------------------------------------------------------------------ deals
class _DealsTab extends StatefulWidget {
  final MarketSource src;
  const _DealsTab({required this.src});

  @override
  State<_DealsTab> createState() => _DealsTabState();
}

class _DealsTabState extends State<_DealsTab> with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>>? _rows;
  Object? _err;
  bool _busy = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _err = null);
    try {
      final r = await widget.src.deals();
      if (mounted) setState(() => _rows = r);
    } catch (e) {
      if (mounted) setState(() => _err = e);
    }
  }

  Future<void> _run(Future<void> Function() f, {String? ok}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await f();
      if (ok != null && mounted) mkSnack(context, ok);
      await _load();
    } catch (e) {
      if (mounted) mkSnack(context, mkMessage(context, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _chat(Map<String, dynamic> d) => _run(() async {
        final r = await widget.src.dealChat(d['id'] as int);
        final m = (r['member'] as Map?)?.cast<String, dynamic>();
        if (m != null && mounted) await ConnectFlow.openChat(context, m);
      });

  Future<bool> _confirm(String title, String body, String yes) async {
    final t = AppLocalizations.of(context);
    final r = await showAppSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(title, style: Theme.of(ctx).textTheme.titleMedium),
          const SizedBox(height: Gap.sm),
          Text(body),
          const SizedBox(height: Gap.lg),
          FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(yes)),
          TextButton(
              style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.amkKeep)),
        ]),
      ),
    );
    return r == true;
  }

  Future<void> _rate(Map<String, dynamic> d) async {
    final t = AppLocalizations.of(context);
    final stars = await showAppSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(t.amkRateTitle, style: Theme.of(ctx).textTheme.titleMedium),
          const SizedBox(height: Gap.md),
          Wrap(alignment: WrapAlignment.center, children: [
            for (var i = 1; i <= 5; i++)
              IconButton(
                key: Key('amk-star-$i'),
                iconSize: 36,
                tooltip: t.amkStarsN(mkNum(ctx, i)),
                onPressed: () => Navigator.pop(ctx, i),
                icon: const Icon(Icons.star_rounded),
              ),
          ]),
        ]),
      ),
    );
    if (stars == null) return;
    await _run(() => widget.src.dealAct(d['id'] as int, 'rate', rating: stars), ok: t.amkThanksRating);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final t = AppLocalizations.of(context);
    if (_err != null && _rows == null) return MkError(error: _err!, onRetry: _load);
    final rows = _rows;
    if (rows == null) return const Center(child: CircularProgressIndicator());
    if (rows.isEmpty) {
      return ListView(children: [
        MkEmpty(
          key: const Key('amk-deals-empty'),
          icon: Icons.handshake_rounded,
          title: t.amkDealsEmptyTitle,
          benefit: t.amkDealsEmptyBenefit,
          howTo: t.amkDealsEmptyHow,
          button: t.amkPostNeed,
          onPressed: () => DefaultTabController.of(context).animateTo(0),
        ),
      ]);
    }
    final cs = Theme.of(context).colorScheme;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.md)),
        children: [
          for (final d in rows)
            Card(
              key: Key('amk-deal-${d['id']}'),
              child: Padding(
                padding: const EdgeInsets.all(Gap.md),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${d['title']}', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: Gap.xs),
                  Text([
                    d['role'] == 'buyer' ? t.amkSeller('${d['other_name']}') : t.amkBuyer('${d['other_name']}'),
                    '${mkNum(context, d['quantity'])} ${d['unit_label'] ?? ''}',
                    mkTaka(context, d['total']),
                  ].join(' · ')),
                  const SizedBox(height: Gap.xs),
                  Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
                    MkBadge(t.amkCod, color: cs.secondaryContainer, onColor: cs.onSecondaryContainer),
                    MkBadge(mkStatusLabel(t, '${d['status']}'), color: cs.surfaceContainerHighest, onColor: cs.onSurface),
                    if (d['rating'] != null)
                      MkBadge(t.amkStarsN(mkNum(context, d['rating'])), color: cs.tertiaryContainer, onColor: cs.onTertiaryContainer),
                  ]),
                  const SizedBox(height: Gap.sm),
                  Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
                    FilledButton.tonalIcon(
                      key: Key('amk-chat-${d['id']}'),
                      style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                      onPressed: _busy ? null : () => _chat(d),
                      icon: const Icon(Icons.chat_bubble_outline_rounded),
                      label: Text(t.amkChat),
                    ),
                    if (d['status'] == 'confirmed')
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                        onPressed: _busy
                            ? null
                            : () => _run(() => widget.src.dealAct(d['id'] as int, 'delivered'), ok: t.amkMarkedDelivered),
                        child: Text(d['role'] == 'buyer' ? t.amkGotIt : t.amkDelivered),
                      ),
                    if (d['can_rate'] == true)
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                        onPressed: _busy ? null : () => _rate(d),
                        child: Text(t.amkRate),
                      ),
                    if (d['status'] == 'confirmed')
                      TextButton(
                        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                        onPressed: _busy
                            ? null
                            : () async {
                                if (await _confirm(t.amkCancelDealTitle, t.amkCancelDealBody, t.amkCancelDeal)) {
                                  await _run(() => widget.src.dealAct(d['id'] as int, 'cancel'));
                                }
                              },
                        child: Text(t.amkCancelDeal),
                      ),
                    if (d['role'] == 'buyer')
                      TextButton(
                        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                        onPressed: _busy
                            ? null
                            : () => mkReportOrBlock(context, widget.src, 'seller', d['seller_id'] as int,
                                blockKind: 'deal', blockId: d['id'] as int, onDone: _load),
                        child: Text(t.amkReportBlock),
                      ),
                  ]),
                ]),
              ),
            ),
        ],
      ),
    );
  }
}
