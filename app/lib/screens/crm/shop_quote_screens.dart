import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../messaging/date_separators.dart' show localDigits;
import '../../plans_v2/upgrade_sheet.dart';
import '../../services/error_kind.dart';
import '../../services/error_report.dart';
import '../../theme.dart';
import '../../widgets/skeleton.dart';
import '../business/business_common.dart' show takaToPoisha;
import 'crm100_api.dart';
import 'crm_common.dart';
import 'crm_send_sheet.dart';
import 'customer_history_screen.dart' show quoteStateLabel, payLabel;

/// crm100 — price quotes from the shop's own catalog.
/// The customer gets a link (no app, no login) to accept or decline; accept
/// makes the order (stock + COD / payment status) and the seller gets a push.
class ShopQuoteListScreen extends StatefulWidget {
  final int? business;
  const ShopQuoteListScreen({super.key, this.business});

  @override
  State<ShopQuoteListScreen> createState() => _ShopQuoteListScreenState();
}

class _ShopQuoteListScreenState extends State<ShopQuoteListScreen> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  Object? _fail;
  bool _hasBusiness = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _d(Object v) => localDigits('$v', Localizations.localeOf(context).languageCode);

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _fail = null;
    });
    try {
      final r = await Crm100Api.of(context)
          .quotes(business: widget.business)
          .timeout(const Duration(seconds: 20));
      _rows = ((r['results'] ?? []) as List).cast<Map<String, dynamic>>();
      _hasBusiness = r['has_business'] != false;
    } catch (e) {
      _fail = e;
      reportNonFatal('crm100.quotes', e);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _new() async {
    final made = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => ShopQuoteBuilderScreen(business: widget.business)));
    if (made == true) _load();
  }

  Future<void> _extend(Map<String, dynamic> q) async {
    final t = AppLocalizations.of(context);
    final days = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Text(t.c100ExtendTitle, style: AType.titleMedium),
          ),
          for (final n in const [1, 3, 7, 15])
            ListTile(
                title: Text(t.c100DaysN(_d(n))), onTap: () => Navigator.pop(ctx, n)),
        ]),
      ),
    );
    if (days == null || !mounted) return;
    await _act(() => Crm100Api.of(context)
        .extendQuote((q['id'] as num).toInt(), days, business: widget.business));
  }

  Future<void> _revoke(Map<String, dynamic> q) async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.c100RevokeTitle),
        content: Text(t.c100RevokeBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.c100Revoke)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _act(() => Crm100Api.of(context)
        .revokeQuote((q['id'] as num).toInt(), business: widget.business));
  }

  Future<void> _act(Future<Map<String, dynamic>> Function() f) async {
    try {
      await f();
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_serverText(AppLocalizations.of(context), e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.c100QuotesTitle)),
      floatingActionButton: _hasBusiness
          ? FloatingActionButton.extended(
              onPressed: _new, icon: const Icon(Icons.add_rounded), label: Text(t.c100NewQuote))
          : null,
      body: _body(t),
    );
  }

  Widget _body(AppLocalizations t) {
    if (_loading && _rows.isEmpty) return const SkeletonList();
    if (_fail != null) {
      final net = failKindOf(_fail!) == FailKind.network;
      return StateMessage(
        icon: net ? Icons.wifi_off_rounded : Icons.cloud_off_rounded,
        title: net ? t.c100OfflineTitle : t.loadFailed,
        message: net ? t.c100OfflineList : honestFailText(t, _fail),
        action: FilledButton(onPressed: _load, child: Text(t.retry)),
      );
    }
    if (!_hasBusiness) {
      return StateMessage(
          icon: Icons.storefront_rounded, title: t.c100NeedShopTitle, message: t.c100NeedShopBody);
    }
    if (_rows.isEmpty) {
      return StateMessage(
          icon: Icons.request_quote_rounded,
          title: t.c100NoQuotesTitle,
          message: t.c100NoQuotesBody,
          action: FilledButton.icon(
              onPressed: _new, icon: const Icon(Icons.add_rounded), label: Text(t.c100NewQuote)));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, 96),
        itemCount: _rows.length,
        itemBuilder: (_, i) => _tile(t, _rows[i]),
      ),
    );
  }

  Widget _tile(AppLocalizations t, Map<String, dynamic> q) {
    final scheme = Theme.of(context).colorScheme;
    final st = '${q['state'] ?? ''}';
    final open = st == 'issued' || st == 'viewed';
    final who = '${q['customer_name'] ?? ''}'.isNotEmpty
        ? '${q['customer_name']}'
        : ('${q['customer_phone'] ?? ''}'.isNotEmpty ? _d(q['customer_phone']) : t.c100Customer);
    final items = ((q['items'] ?? const []) as List).length;
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.md),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text(who,
                    style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis)),
            Text(bdt(context, ((q['total_poisha'] as num?) ?? 0) / 100),
                style: AType.titleMedium.copyWith(fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.xs, runSpacing: Gap.xs, children: [
            Chip(
              visualDensity: VisualDensity.compact,
              backgroundColor: st == 'accepted'
                  ? scheme.primaryContainer
                  : (st == 'declined' || st == 'expired' || st == 'revoked')
                      ? scheme.errorContainer
                      : null,
              label: Text(quoteStateLabel(t, st)),
            ),
            Chip(visualDensity: VisualDensity.compact, label: Text(t.c100ItemsN(_d(items)))),
            Chip(
                visualDensity: VisualDensity.compact,
                label: Text(payLabel(t, '${q['payment'] ?? ''}'))),
          ]),
          if (open)
            Text(t.c100ValidUntil(crmDate(context, q['valid_until'])),
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
          if (st == 'accepted' && q['order'] != null)
            Text(t.c100OrderMade(_d(q['order'])), style: AType.bodySmall),
          if (st == 'declined' && '${q['decline_reason'] ?? ''}'.isNotEmpty)
            Text(t.c100DeclineReason('${q['decline_reason']}'), style: AType.bodySmall),
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.sm, children: [
            if (open)
              TextButton.icon(
                  onPressed: () => shareQuote(context, q, business: widget.business),
                  icon: const Icon(Icons.share_rounded),
                  label: Text(t.c100Share)),
            if (open || st == 'expired')
              TextButton(onPressed: () => _extend(q), child: Text(t.c100Extend)),
            if (open || st == 'expired')
              TextButton(onPressed: () => _revoke(q), child: Text(t.c100Revoke)),
          ]),
        ]),
      ),
    );
  }
}

String _serverText(AppLocalizations t, Object e) {
  if (e is ApiException && (e.body?['detail'] ?? '').toString().isNotEmpty) {
    return '${e.body!['detail']}';
  }
  return honestFailText(t, e);
}

/// Share a quote: through the CRM send sheet when we know the customer's
/// number (WhatsApp / phone SMS / Assisto SMS, logged on their history),
/// else the phone's share sheet. Copy link is always there.
Future<void> shareQuote(BuildContext context, Map<String, dynamic> q, {int? business}) async {
  final t = AppLocalizations.of(context);
  final url = '${q['url'] ?? ''}';
  final name = '${q['customer_name'] ?? ''}';
  final text = t.c100QuoteShareText(
      name.isEmpty ? t.c100Customer : name, bdt(context, ((q['total_poisha'] as num?) ?? 0) / 100), url);
  final phone = '${q['customer_phone'] ?? ''}';
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
          child: SelectableText(url, style: AType.bodySmall),
        ),
        if (phone.isNotEmpty)
          ListTile(
            leading: const Icon(Icons.send_rounded),
            title: Text(t.c100ShareToCustomer),
            onTap: () {
              Navigator.pop(ctx);
              CrmSendSheet.show(context,
                  target: CustomerTarget(phone: phone),
                  name: name,
                  business: business,
                  initialText: text,
                  purpose: 'quote');
            },
          ),
        ListTile(
          leading: const Icon(Icons.ios_share_rounded),
          title: Text(t.c100ShareOther),
          onTap: () async {
            Navigator.pop(ctx);
            try {
              await Share.share(text);
            } catch (e) {
              reportNonFatal('crm100.share', e);
            }
          },
        ),
        ListTile(
          leading: const Icon(Icons.copy_rounded),
          title: Text(t.c100CopyLink),
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: url));
            if (ctx.mounted) Navigator.pop(ctx);
            if (context.mounted) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text(t.c100LinkCopied)));
            }
          },
        ),
      ]),
    ),
  );
}

// =================================================================== builder
class _Line {
  final Map<String, dynamic> product;
  final Map<String, dynamic> variant;
  int qty = 1;
  final price = TextEditingController();
  _Line(this.product, this.variant);
  int get sell => (variant['sell_poisha'] as num?)?.toInt() ?? 0;
  int? get min => (variant['min_poisha'] as num?)?.toInt();
  int get stock => (variant['stock'] as num?)?.toInt() ?? 0;
  int get unit => takaToPoisha(price.text) ?? sell;
  String get label {
    final extra = [variant['size'], variant['colour']]
        .where((x) => '${x ?? ''}'.isNotEmpty)
        .join(' ');
    return extra.isEmpty ? '${product['name']}' : '${product['name']} $extra';
  }
}

class ShopQuoteBuilderScreen extends StatefulWidget {
  final int? business;
  final String customerName;
  final String customerPhone;
  final int? lead;
  const ShopQuoteBuilderScreen(
      {super.key, this.business, this.customerName = '', this.customerPhone = '', this.lead});

  @override
  State<ShopQuoteBuilderScreen> createState() => _ShopQuoteBuilderScreenState();
}

class _ShopQuoteBuilderScreenState extends State<ShopQuoteBuilderScreen> {
  late final _name = TextEditingController(text: widget.customerName);
  late final _phone = TextEditingController(text: widget.customerPhone);
  final _discount = TextEditingController();
  final _delivery = TextEditingController();
  final _note = TextEditingController();
  final _lines = <_Line>[];
  int _days = 3;
  String _payment = 'cod';
  bool _busy = false;
  String _error = '';
  List<Map<String, dynamic>>? _catalog;
  Object? _catFail;
  bool _owner = true;

  @override
  void initState() {
    super.initState();
    _loadCatalog();
  }

  @override
  void dispose() {
    for (final c in [_name, _phone, _discount, _delivery, _note]) {
      c.dispose();
    }
    for (final l in _lines) {
      l.price.dispose();
    }
    super.dispose();
  }

  String _d(Object v) => localDigits('$v', Localizations.localeOf(context).languageCode);
  String _money(int p) => bdt(context, p / 100);

  Future<void> _loadCatalog() async {
    setState(() => _catFail = null);
    try {
      final r = await Crm100Api.of(context)
          .catalog(business: widget.business)
          .timeout(const Duration(seconds: 20));
      _catalog = ((r['results'] ?? []) as List).cast<Map<String, dynamic>>();
      _owner = (r['role'] ?? 'owner') == 'owner';
    } catch (e) {
      _catFail = e;
      reportNonFatal('crm100.catalog', e);
    }
    if (mounted) setState(() {});
  }

  int get _subtotal => _lines.fold(0, (a, l) => a + l.unit * l.qty);
  int get _floor => _lines.fold(0, (a, l) => a + (l.min ?? 0) * l.qty);
  int get _disc => takaToPoisha(_discount.text) ?? 0;
  int get _deliv => takaToPoisha(_delivery.text) ?? 0;
  int get _total => _subtotal - _disc + _deliv;

  Future<void> _pick() async {
    final t = AppLocalizations.of(context);
    final cat = _catalog ?? const [];
    final picked = await showModalBottomSheet<(Map<String, dynamic>, Map<String, dynamic>)>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (ctx) => _ProductPicker(catalog: cat, d: _d),
    );
    if (picked == null) return;
    setState(() {
      _lines.add(_Line(picked.$1, picked.$2));
      _error = '';
    });
    if (!mounted) return;
    if (_lines.last.stock < 1) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.c100StockOut)));
    }
  }

  Future<void> _create() async {
    final t = AppLocalizations.of(context);
    if (_lines.isEmpty) {
      setState(() => _error = t.c100PickProduct);
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final q = await Crm100Api.of(context).createQuote({
        if (widget.business != null) 'business': widget.business,
        if (widget.lead != null) 'lead': widget.lead,
        'customer_name': _name.text.trim(),
        'customer_phone': _phone.text.trim(),
        'lang': Localizations.localeOf(context).languageCode,
        'items': [
          for (final l in _lines)
            {
              'product_id': l.product['id'],
              'variant': l.variant['key'] ?? '',
              'qty': l.qty,
              if (l.price.text.trim().isNotEmpty) 'unit_price': (l.unit / 100).toString(),
            }
        ],
        'discount': (_disc / 100).toString(),
        'delivery': (_deliv / 100).toString(),
        'valid_days': _days,
        'payment': _payment,
        'note': _note.text.trim(),
      });
      if (!mounted) return;
      setState(() => _busy = false); // made: no spinner behind the share sheet
      await shareQuote(context, q, business: widget.business);
      if (mounted) Navigator.pop(context, true);
      return;
    } catch (e) {
      if (!mounted) return;
      if (await UpgradeSheet.handle(context, e)) {
        if (mounted) setState(() => _busy = false);
        return;
      }
      setState(() => _error = _serverText(t, e));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final maxDisc = _subtotal - _floor;
    return Scaffold(
      appBar: AppBar(title: Text(t.c100NewQuote)),
      body: ListView(padding: const EdgeInsets.all(Gap.lg), children: [
        Text(t.c100BuilderIntro,
            style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.md),
        TextField(
            controller: _name,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
                labelText: t.c100CustomerName, border: const OutlineInputBorder())),
        const SizedBox(height: Gap.sm),
        TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(
                labelText: t.c100CustomerPhone, border: const OutlineInputBorder())),
        const SizedBox(height: Gap.lg),
        Text(t.c100Products, style: AType.titleMedium),
        const SizedBox(height: Gap.sm),
        if (_catFail != null)
          Row(children: [
            Expanded(
                child: Text(
                    failKindOf(_catFail!) == FailKind.network
                        ? t.c100Offline
                        : honestFailText(t, _catFail),
                    style: TextStyle(color: scheme.error))),
            TextButton(onPressed: _loadCatalog, child: Text(t.retry)),
          ])
        else if (_catalog != null && _catalog!.isEmpty)
          Text(t.c100NoCatalog, style: AType.bodyMedium),
        for (final l in _lines) _lineCard(t, l),
        OutlinedButton.icon(
          onPressed: _catalog == null || _catalog!.isEmpty ? null : _pick,
          icon: const Icon(Icons.add_shopping_cart_rounded),
          label: Text(t.c100AddProduct),
        ),
        const SizedBox(height: Gap.lg),
        Row(children: [
          Expanded(
            child: TextField(
                controller: _discount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                    labelText: t.c100Discount,
                    helperText: _owner && _lines.isNotEmpty && _floor > 0
                        ? t.c100MaxDiscount(_money(maxDisc < 0 ? 0 : maxDisc))
                        : null,
                    helperMaxLines: 2,
                    border: const OutlineInputBorder())),
          ),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: TextField(
                controller: _delivery,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                    labelText: t.c100Delivery, border: const OutlineInputBorder())),
          ),
        ]),
        const SizedBox(height: Gap.lg),
        Text(t.c100Validity, style: AType.titleMedium),
        Wrap(spacing: Gap.xs, children: [
          for (final n in const [1, 3, 7, 15, 30])
            ChoiceChip(
                label: Text(t.c100DaysN(_d(n))),
                selected: _days == n,
                onSelected: (_) => setState(() => _days = n)),
        ]),
        const SizedBox(height: Gap.md),
        Text(t.c100Payment, style: AType.titleMedium),
        Wrap(spacing: Gap.xs, children: [
          for (final p in const ['cod', 'bkash', 'nagad', 'paid'])
            ChoiceChip(
                label: Text(payLabel(t, p)),
                selected: _payment == p,
                onSelected: (_) => setState(() => _payment = p)),
        ]),
        const SizedBox(height: Gap.md),
        TextField(
            controller: _note,
            maxLength: 300,
            maxLines: 2,
            decoration: InputDecoration(
                labelText: t.c100NoteLabel, border: const OutlineInputBorder())),
        const SizedBox(height: Gap.sm),
        _totals(t),
        if (_error.isNotEmpty) ...[
          const SizedBox(height: Gap.sm),
          Semantics(
              liveRegion: true,
              child: Text(_error, style: TextStyle(color: scheme.error))),
        ],
        const SizedBox(height: Gap.md),
        FilledButton.icon(
          onPressed: _busy ? null : _create,
          icon: _busy
              ? const SizedBox(
                  width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.link_rounded),
          label: Text(t.c100MakeLink),
        ),
        const SizedBox(height: Gap.xs),
        Text(t.c100LinkPromise,
            style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.xxl),
      ]),
    );
  }

  Widget _lineCard(AppLocalizations t, _Line l) {
    final scheme = Theme.of(context).colorScheme;
    final below = l.min != null && l.price.text.trim().isNotEmpty && l.unit < l.min!;
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text(l.label,
                    style: AType.titleSmall.copyWith(fontWeight: FontWeight.w700))),
            IconButton(
                tooltip: t.c100RemoveLine,
                onPressed: () => setState(() {
                      _lines.remove(l);
                      l.price.dispose();
                    }),
                icon: const Icon(Icons.delete_outline_rounded)),
          ]),
          Text(t.c100StockLeft(_d(l.stock)),
              style: AType.bodySmall
                  .copyWith(color: l.stock < l.qty ? scheme.error : scheme.onSurfaceVariant)),
          Row(children: [
            IconButton(
                tooltip: t.c100QtyLess,
                onPressed: l.qty > 1 ? () => setState(() => l.qty--) : null,
                icon: const Icon(Icons.remove_circle_outline_rounded)),
            Text(_d(l.qty), style: AType.titleMedium),
            IconButton(
                tooltip: t.c100QtyMore,
                onPressed: l.qty < 999 ? () => setState(() => l.qty++) : null,
                icon: const Icon(Icons.add_circle_outline_rounded)),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: TextField(
                controller: l.price,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  isDense: true,
                  labelText: t.c100UnitPrice,
                  hintText: _money(l.sell),
                  helperText: _owner && l.min != null && l.min! > 0
                      ? t.c100Lowest(_money(l.min!))
                      : null,
                  errorText: below ? t.c100BelowMin : null,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
          ]),
          Align(
            alignment: Alignment.centerRight,
            child: Text(_money(l.unit * l.qty),
                style: AType.titleSmall.copyWith(fontWeight: FontWeight.w800)),
          ),
        ]),
      ),
    );
  }

  Widget _totals(AppLocalizations t) {
    Widget row(String a, String b, {bool big = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Expanded(child: Text(a, style: big ? AType.titleMedium : AType.bodyMedium)),
            Text(b,
                style: (big ? AType.titleLarge : AType.bodyMedium)
                    .copyWith(fontWeight: big ? FontWeight.w800 : null)),
          ]),
        );
    return Column(children: [
      row(t.c100Subtotal, _money(_subtotal)),
      if (_disc > 0) row(t.c100Discount, '− ${_money(_disc)}'),
      if (_deliv > 0) row(t.c100Delivery, _money(_deliv)),
      const Divider(),
      row(t.c100Total, _money(_total), big: true),
    ]);
  }
}

class _ProductPicker extends StatefulWidget {
  final List<Map<String, dynamic>> catalog;
  final String Function(Object) d;
  const _ProductPicker({required this.catalog, required this.d});

  @override
  State<_ProductPicker> createState() => _ProductPickerState();
}

class _ProductPickerState extends State<_ProductPicker> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final rows = <(Map<String, dynamic>, Map<String, dynamic>)>[];
    for (final p in widget.catalog) {
      if (_q.isNotEmpty && !'${p['name']}'.toLowerCase().contains(_q.toLowerCase())) continue;
      for (final v in ((p['variants'] ?? const []) as List).cast<Map<String, dynamic>>()) {
        rows.add((p, v));
      }
    }
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.75,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
          child: TextField(
            autofocus: false,
            onChanged: (v) => setState(() => _q = v.trim()),
            decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search_rounded),
                hintText: t.c100SearchProduct,
                border: const OutlineInputBorder()),
          ),
        ),
        Expanded(
          child: rows.isEmpty
              ? StateMessage(icon: Icons.search_off_rounded, title: t.c100NoMatch)
              : ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (_, i) {
                    final (p, v) = rows[i];
                    final extra = [v['size'], v['colour']]
                        .where((x) => '${x ?? ''}'.isNotEmpty)
                        .join(' ');
                    final stock = (v['stock'] as num?)?.toInt() ?? 0;
                    return ListTile(
                      title: Text(extra.isEmpty ? '${p['name']}' : '${p['name']} · $extra'),
                      subtitle: Text(t.c100StockLeft(widget.d(stock))),
                      trailing: Text(bdt(context, ((v['sell_poisha'] as num?) ?? 0) / 100),
                          style: AType.titleSmall.copyWith(fontWeight: FontWeight.w700)),
                      onTap: () => Navigator.pop(context, (p, v)),
                    );
                  }),
        ),
      ]),
    );
  }
}
