import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import '../../theme.dart';
import '../../business_selling_api.dart';
import '../../widgets/skeleton.dart';
import '../../l10n/app_localizations.dart';
import 'selling_common.dart';
import 'sale_void_dialog.dart';
import 'package:assisto/widgets/app_sheet.dart';

/// Quick sell (§3): tap a product → cart → qty / price → payment → done.
///
/// The UI will NOT let a staff member or owner key a line price below that
/// product's minimum (the field is validated and the "set" button disabled),
/// AND it trusts the server 422 `below_min` as the hard gate — if the backend
/// rejects, the bilingual `biz_below_min` message is shown and the price is
/// left unchanged. Minimum price can therefore NEVER be breached.
class QuickSellScreen extends StatefulWidget {
  final int? businessId;
  const QuickSellScreen({super.key, this.businessId});
  @override
  State<QuickSellScreen> createState() => _QuickSellScreenState();
}

class _QuickSellScreenState extends State<QuickSellScreen> {
  List<Map<String, dynamic>> _products = [];
  Map<String, dynamic> _cart = {};
  bool _loading = true;
  Object? _error;
  String _q = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  List<Map<String, dynamic>> get _lines =>
      ((_cart['lines'] ?? []) as List).cast<Map<String, dynamic>>();

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = sellApi(context);
      _products = await api.productsList(businessId: widget.businessId);
      _cart = await api.cartGet(businessId: widget.businessId);
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _addToCart(Map<String, dynamic> product,
      {String? variantKey}) async {
    try {
      _cart = await sellApi(context).cartAdd(
        cart: _cart,
        productId: product['id'] as int,
        variantKey: variantKey,
        businessId: widget.businessId,
      );
      if (mounted) setState(() {});
    } on BelowMinException {
      if (mounted) showBelowMin(context);
    } catch (e) {
      if (mounted) showApiError(context, e);
    }
  }

  Future<void> _tapProduct(Map<String, dynamic> product) async {
    final variants = (product['variants'] as List?) ?? const [];
    // rt1 (reality audit): every product has at least its base variant, so a
    // one-variant product goes straight into the cart (no picker to tap).
    if (variants.length <= 1) {
      final only = variants.isEmpty ? null : variants.first;
      await _addToCart(product,
          variantKey: only is Map ? only['key']?.toString() : null);
      return;
    }
    final chosen = await showAppSheet<String>(
      context: context,
      builder: (_) => _VariantPicker(product: product),
    );
    if (chosen != null) await _addToCart(product, variantKey: chosen);
  }

  Future<void> _setQty(Map<String, dynamic> line, int qty) async {
    if (qty <= 0) {
      await _removeLine(line);
      return;
    }
    try {
      _cart = await sellApi(context).cartSetQty(_cart, line['id'] as int, qty);
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) showApiError(context, e);
    }
  }

  Future<void> _removeLine(Map<String, dynamic> line) async {
    try {
      _cart = await sellApi(context).cartRemove(_cart, line['id'] as int);
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) showApiError(context, e);
    }
  }

  Future<void> _editPrice(Map<String, dynamic> line) async {
    final min = poishaOf(line['min_price']);
    final current = poishaOf(line['unit_price']);
    final ctrl = TextEditingController(
        text: current.takaValue
            .toStringAsFixed(2)
            .replaceFirst(RegExp(r'\.00$'), ''));
    final result = await showDialog<num>(
      context: context,
      builder: (_) => _PriceDialog(
          controller: ctrl, min: min, canSeeMin: !isRedacted(line, 'min_price')),
    );
    if (result == null) return;
    try {
      _cart = await sellApi(context).cartSetPrice(_cart, line['id'] as int, result);
      if (mounted) setState(() {});
    } on BelowMinException {
      if (mounted) showBelowMin(context);
    } catch (e) {
      if (mounted) showApiError(context, e);
    }
  }

  Future<void> _checkout() async {
    if (_lines.isEmpty) return;
    final res = await showAppSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) =>
          CheckoutSheet(cart: _cart, businessId: widget.businessId),
    );
    if (res != null) {
      _cart = {};
      await _load();
      if (mounted) {
        final t = AppLocalizations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(t.biz_sale_done, style: const TextStyle(color: Colors.white)),
          backgroundColor: Brand.successFill,
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.biz_cart_add)),
      body: _loading
          ? const SkeletonList()
          : _error != null
              ? StateMessage(
                  icon: Icons.cloud_off_rounded,
                  tint: scheme.error,
                  title: t.loadFailed,
                  action: FilledButton.tonalIcon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(t.retry)))
              : Column(children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                        Gap.lg, Gap.md, Gap.lg, Gap.sm),
                    child: TextField(
                      decoration: InputDecoration(
                        hintText: t.biz_product_name,
                        prefixIcon: const Icon(Icons.search_rounded),
                      ),
                      onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
                    ),
                  ),
                  Expanded(child: _grid(t, scheme)),
                ]),
      bottomNavigationBar: _cartBar(t, scheme),
    );
  }

  Widget _grid(AppLocalizations t, ColorScheme scheme) {
    final filtered = _q.isEmpty
        ? _products
        : _products
            .where((p) =>
                (p['name'] ?? '').toString().toLowerCase().contains(_q) ||
                (p['barcode'] ?? '').toString().toLowerCase().contains(_q))
            .toList();
    if (filtered.isEmpty) {
      return StateMessage(
          icon: Icons.inventory_2_rounded, title: t.biz_cart_empty);
    }
    return GridView.builder(
      padding: const EdgeInsets.all(Gap.lg),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 180,
        childAspectRatio: 0.85,
        crossAxisSpacing: Gap.md,
        mainAxisSpacing: Gap.md,
      ),
      itemCount: filtered.length,
      itemBuilder: (_, i) => _productCard(t, scheme, filtered[i]),
    );
  }

  Widget _productCard(
      AppLocalizations t, ColorScheme scheme, Map<String, dynamic> p) {
    var sell = poishaOf(p['price'] ?? p['sell_price']);
    // rt1 (reality audit): a product whose price lives on its variants showed
    // "৳0" on the card while the variant sells at ৳80 — show the lowest
    // variant price instead of a false zero.
    final vs = (p['variants'] as List? ?? const []).whereType<Map>().toList();
    if (sell <= 0 && vs.isNotEmpty) {
      final prices = [
        for (final v in vs) poishaOf(v['sell_price'] ?? v['price'])
      ].where((x) => x > 0).toList()
        ..sort();
      if (prices.isNotEmpty) sell = prices.first;
    }
    final stock = (p['stock'] ?? 0) as num;
    final oos = stock <= 0 && (p['variants'] as List? ?? const []).isEmpty;
    return InkWell(
      onTap: oos ? null : () => _tapProduct(p),
      borderRadius: BorderRadius.circular(Radii.md),
      child: Opacity(
        opacity: oos ? 0.45 : 1,
        child: SellCard(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Container(
                    width: double.infinity,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(Radii.sm),
                    ),
                    child: (p['photo'] ?? '').toString().startsWith('http')
                        ? Image.network(p['photo'].toString(),
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Icon(
                                Icons.image_rounded,
                                color: scheme.onSurfaceVariant))
                        : Icon(Icons.inventory_2_rounded,
                            color: scheme.onSurfaceVariant),
                  ),
                ),
                const SizedBox(height: Gap.sm),
                Text((p['name'] ?? '').toString(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AType.titleSmall.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: Gap.xxs),
                Text(oos ? t.biz_out_of_stock : sell.takaIn(context),
                    style: TextStyle(fontFeatures: AFonts.tabular,
                        color: oos ? scheme.error : scheme.primary,
                        fontWeight: FontWeight.w800)),
              ]),
        ),
      ),
    );
  }

  Widget? _cartBar(AppLocalizations t, ColorScheme scheme) {
    final lines = _lines;
    if (lines.isEmpty) return null;
    final total = poishaOf(_cart['total'] ?? _cart['subtotal']);
    final count = lines.fold<int>(0, (a, l) => a + ((l['qty'] ?? 0) as num).toInt());
    return SafeArea(
      top: false,
      child: Material(
        color: scheme.surfaceContainerHigh,
        child: InkWell(
          onTap: () => _openCartSheet(t),
          child: Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Row(children: [
              Badge(
                label: Text('$count'),
                child: const Icon(Icons.shopping_cart_rounded),
              ),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Text('${t.biz_total}: ${total.takaIn(context)}',
                    style: AType.titleMedium.copyWith(fontFeatures: AFonts.tabular, fontWeight: FontWeight.w800)),
              ),
              FilledButton(
                  onPressed: _checkout, child: Text(t.biz_pay_method)),
            ]),
          ),
        ),
      ),
    );
  }

  void _openCartSheet(AppLocalizations t) {
    showAppSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => StatefulBuilder(
        builder: (sctx, setSheet) {
          final scheme = Theme.of(sctx).colorScheme;
          final lines = _lines;
          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.75,
            builder: (_, scroll) => ListView(
              controller: scroll,
              padding: const EdgeInsets.all(Gap.lg),
              children: [
                Text(t.biz_cart,
                    style: Theme.of(sctx).textTheme.titleLarge),
                const SizedBox(height: Gap.md),
                if (lines.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(Gap.xl),
                    child: Center(child: Text(t.biz_cart_empty)),
                  ),
                for (final line in lines)
                  _cartLineTile(t, scheme, line, () {
                    // Cart is client-held; the mutating call already updated
                    // `_cart` + parent state. Just rebuild the sheet.
                    setSheet(() {});
                  }),
                const SizedBox(height: Gap.lg),
                MoneyRow(t.biz_subtotal,
                    poishaOf(_cart['subtotal'] ?? _cart['total'])),
                if (poishaOf(_cart['discount']) > 0)
                  MoneyRow(t.biz_discount, poishaOf(_cart['discount']),
                      valueColor: Theme.of(context).colorScheme.error),
                const Divider(),
                MoneyRow(t.biz_total, poishaOf(_cart['total']), strong: true),
                const SizedBox(height: Gap.lg),
                FilledButton(
                  onPressed: lines.isEmpty
                      ? null
                      : () {
                          Navigator.pop(sctx);
                          _checkout();
                        },
                  child: Text(t.biz_pay_method),
                ),
                const SizedBox(height: Gap.lg),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _cartLineTile(AppLocalizations t, ColorScheme scheme,
      Map<String, dynamic> line, VoidCallback after) {
    final qty = ((line['qty'] ?? 1) as num).toInt();
    final unit = poishaOf(line['unit_price']);
    final lineTotal = unit * qty;
    final name = (line['product_name'] ?? line['name'] ?? '').toString();
    final variant = [
      (line['size'] ?? '').toString(),
      (line['colour'] ?? '').toString()
    ].where((s) => s.isNotEmpty).join(' / ');
    return Container(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
                  if (variant.isNotEmpty)
                    Text(variant,
                        style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
                ]),
          ),
          IconButton(
            tooltip: AppLocalizations.of(context).delete,
            icon: Icon(Icons.delete_outline_rounded, color: scheme.error),
            onPressed: () async {
              await _removeLine(line);
              after();
            },
          ),
        ]),
        const SizedBox(height: Gap.sm),
        Row(children: [
          _qtyStepper(qty, (n) async {
            await _setQty(line, n);
            after();
          }),
          const Spacer(),
          TextButton.icon(
            onPressed: () async {
              await _editPrice(line);
              after();
            },
            icon: const Icon(Icons.edit_rounded, size: 16),
            label: Text('${unit.takaIn(context)}', style: const TextStyle(fontFeatures: AFonts.tabular)),
          ),
          const SizedBox(width: Gap.sm),
          Text(lineTotal.takaIn(context),
              style: const TextStyle(fontFeatures: AFonts.tabular, fontWeight: FontWeight.w800)),
        ]),
      ]),
    );
  }

  Widget _qtyStepper(int qty, ValueChanged<int> onChange) {
    return Row(children: [
      IconButton.filledTonal(
        tooltip: AppLocalizations.of(context).f2Decrease,
        icon: const Icon(Icons.remove_rounded, size: 18),
        onPressed: () => onChange(qty - 1),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
        child: Text('$qty',
            style: AType.titleMedium.copyWith(fontFeatures: AFonts.tabular, fontWeight: FontWeight.w700)),
      ),
      IconButton.filledTonal(
        tooltip: AppLocalizations.of(context).f2Increase,
        icon: const Icon(Icons.add_rounded, size: 18),
        onPressed: () => onChange(qty + 1),
      ),
    ]);
  }
}

// -------------------------------------------------------------- variant picker

class _VariantPicker extends StatelessWidget {
  final Map<String, dynamic> product;
  const _VariantPicker({required this.product});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final variants =
        ((product['variants'] ?? []) as List).cast<Map<String, dynamic>>();
    return SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Text(t.biz_product_variant,
              style: Theme.of(context).textTheme.titleLarge),
        ),
        for (final v in variants)
          ListTile(
            title: Text([
              (v['size'] ?? '').toString(),
              (v['colour'] ?? '').toString()
            ].where((s) => s.isNotEmpty).join(' / ')),
            subtitle: Text('${t.biz_stock}: ${v['stock'] ?? 0}'),
            trailing: Text(
                poishaOf(v['sell_price'] ?? v['price']).takaIn(context),
                style: const TextStyle(fontWeight: FontWeight.w700)),
            enabled: ((v['stock'] ?? 0) as num) > 0,
            // rt1: variants have a string `key`, no `id` — the old
            // `v['id'] as int` threw on every tap and nothing was added.
            onTap: () => Navigator.pop(context, (v['key'] ?? '').toString()),
          ),
        const SizedBox(height: Gap.lg),
      ]),
    );
  }
}

// -------------------------------------------------------------- price dialog

class _PriceDialog extends StatefulWidget {
  final TextEditingController controller;
  final int min;
  final bool canSeeMin;
  const _PriceDialog(
      {required this.controller, required this.min, required this.canSeeMin});
  @override
  State<_PriceDialog> createState() => _PriceDialogState();
}

class _PriceDialogState extends State<_PriceDialog> {
  String? _err;

  bool _belowMin(num? taka) =>
      widget.min > 0 && taka != null && takaToPoisha(taka) < widget.min;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final taka = parseTaka(widget.controller.text);
    final below = _belowMin(taka);
    return AlertDialog(
      title: Text(t.biz_price_override),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        MoneyField(
          controller: widget.controller,
          label: t.biz_sell_price,
          helper: widget.canSeeMin && widget.min > 0
              ? '${t.biz_min_price}: ${widget.min.takaIn(context)}'
              : null,
          onChanged: (_) => setState(() {
            _err = _belowMin(parseTaka(widget.controller.text))
                ? t.biz_below_min
                : null;
          }),
        ),
        if (_err != null) ...[
          const SizedBox(height: Gap.sm),
          Text(_err!,
              style: AType.bodySmall.copyWith(color: Theme.of(context).colorScheme.error)),
        ],
      ]),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: Text(t.cancel)),
        FilledButton(
          // Client-side gate: disabled when below the minimum. The server 422
          // remains the hard gate if this is somehow bypassed.
          onPressed: (taka == null || below)
              ? null
              : () => Navigator.pop(context, taka),
          child: Text(t.biz_cart_add),
        ),
      ],
    );
  }
}

// ============================================================ checkout sheet

/// Payment method, paid amount, change/due, confirm → sale. On success offers
/// an OPTIONAL receipt share (text today; PDF when the backend serves one).
class CheckoutSheet extends StatefulWidget {
  final Map<String, dynamic> cart;
  final int? businessId;
  const CheckoutSheet({super.key, required this.cart, this.businessId});
  @override
  State<CheckoutSheet> createState() => _CheckoutSheetState();
}

class _CheckoutSheetState extends State<CheckoutSheet> {
  String _method = 'cash';
  final _paid = TextEditingController();
  final _discount = TextEditingController();
  int _discountClampNotice = 0; // 0 none, 1 clamped
  bool _busy = false;

  int get _total => poishaOf(widget.cart['total'] ?? widget.cart['subtotal']);
  int get _paidPoisha {
    final v = parseTaka(_paid.text);
    return v == null ? 0 : takaToPoisha(v);
  }

  int get _change => (_paidPoisha - _total).clamp(0, 1 << 62);
  int get _due => (_total - _paidPoisha).clamp(0, 1 << 62);

  @override
  void dispose() {
    _paid.dispose();
    _discount.dispose();
    super.dispose();
  }

  Future<void> _previewDiscount() async {
    final amt = parseTaka(_discount.text);
    if (amt == null) return;
    try {
      final res = await sellApi(context)
          .cartDiscountPreview(cart: widget.cart, amountTaka: amt);
      setState(() => _discountClampNotice =
          (res['discount_clamped'] == true) ? 1 : 0);
    } catch (e) {
      if (mounted) showApiError(context, e);
    }
  }

  Future<void> _confirm() async {
    final t = AppLocalizations.of(context);
    if (_method != 'due' && _paidPoisha < _total) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.biz_short_payment)));
      return;
    }
    setState(() => _busy = true);
    try {
      final disc = parseTaka(_discount.text);
      final sale = await sellApi(context).checkout(
        cart: widget.cart,
        businessId: widget.businessId,
        paymentMethod: _method,
        paidTaka: _method == 'due' ? null : parseTaka(_paid.text),
        discountTaka: disc,
      );
      if (!mounted) return;
      // the host (navigator) context outlives this sheet, for the void dialog
      final host = Navigator.of(context).context;
      Navigator.pop(context, sale);
      _offerReceipt(sale, host);
    } on BelowMinException {
      if (mounted) showBelowMin(context);
    } catch (e) {
      if (mounted) showApiError(context, e);
    }
    if (mounted) setState(() => _busy = false);
  }

  void _offerReceipt(Map<String, dynamic> sale, BuildContext host) {
    final t = AppLocalizations.of(context);
    // checkout answers `sale_id` (older code read `id`, so the action never showed)
    final id = sale['id'] ?? sale['sale_id'];
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(
      duration: const Duration(seconds: 8),
      content: Text(t.biz_sale_done),
      action: id == null
          ? null
          : SnackBarAction(
              label: t.shopSaleOptions,
              onPressed: () => _saleOptions(host, sale, (id as num).toInt())),
    ));
  }

  /// Share the receipt, or VOID the sale (reason required; server-gated).
  void _saleOptions(BuildContext host, Map<String, dynamic> sale, int id) {
    if (!host.mounted) return;
    final t = AppLocalizations.of(host);
    showAppSheet<void>(
      context: host,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.share_rounded),
            title: Text(t.biz_receipt_share),
            onTap: () {
              Navigator.pop(ctx);
              _shareReceiptText(host, sale);
            },
          ),
          ListTile(
            leading: Icon(Icons.block_rounded, color: Theme.of(ctx).colorScheme.error),
            title: Text(t.shopVoidTitle),
            onTap: () {
              Navigator.pop(ctx);
              showSaleVoidDialog(host, id);
            },
          ),
        ]),
      ),
    );
  }

  Future<void> _shareReceiptText(BuildContext host, Map<String, dynamic> sale) async {
    if (!host.mounted) return;
    final t = AppLocalizations.of(host);
    final buf = StringBuffer();
    buf.writeln(t.biz_receipt);
    for (final l in ((sale['lines'] ?? []) as List)) {
      final m = l as Map;
      final qty = (m['qty'] ?? 1);
      final unit = poishaOf(m['unit_price']);
      buf.writeln(
          '${m['product_name'] ?? ''} x$qty  ${(unit * (qty as num).toInt()).takaIn(context)}');
    }
    buf.writeln('${t.biz_total}: ${poishaOf(sale['total']).takaIn(context)}');
    if (poishaOf(sale['change']) > 0) {
      buf.writeln('${t.biz_change}: ${poishaOf(sale['change']).takaIn(context)}');
    }
    if (poishaOf(sale['due']) > 0) {
      buf.writeln('${t.biz_due}: ${poishaOf(sale['due']).takaIn(context)}');
    }
    await Share.share(buf.toString());
  }


  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final inset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: inset),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        maxChildSize: 0.95,
        builder: (_, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.all(Gap.lg),
          children: [
            Text(t.biz_pay_method,
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Gap.md),
            Wrap(
              spacing: Gap.sm,
              children: [
                for (final m in paymentMethods(t))
                  ChoiceChip(
                    avatar: Icon(m.icon, size: 18),
                    label: Text(m.label),
                    selected: _method == m.code,
                    onSelected: (_) => setState(() => _method = m.code),
                  ),
              ],
            ),
            const SizedBox(height: Gap.lg),
            MoneyField(
              controller: _discount,
              label: t.biz_discount,
              onChanged: (_) => _discountClampNotice = 0,
            ),
            TextButton(
                onPressed: _previewDiscount, child: Text(t.biz_discount)),
            if (_discountClampNotice == 1)
              Container(
                padding: const EdgeInsets.all(Gap.sm),
                decoration: BoxDecoration(
                  color: AssistoTokens.of(context).warning.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(Radii.sm),
                ),
                child: Row(children: [
                  Icon(Icons.info_outline_rounded,
                      color: AssistoTokens.of(context).warning, size: 18),
                  const SizedBox(width: Gap.sm),
                  Expanded(child: Text(t.biz_discount_clamped)),
                ]),
              ),
            const SizedBox(height: Gap.md),
            if (_method != 'due')
              MoneyField(
                controller: _paid,
                label: t.biz_paid,
                onChanged: (_) => setState(() {}),
              ),
            const SizedBox(height: Gap.lg),
            SellCard(
              child: Column(children: [
                MoneyRow(t.biz_subtotal,
                    poishaOf(widget.cart['subtotal'] ?? widget.cart['total'])),
                const Divider(),
                MoneyRow(t.biz_total, _total, strong: true),
                if (_method != 'due')
                  MoneyRow(t.biz_change, _change, valueColor: AssistoTokens.of(context).success),
                if (_method == 'due' || _due > 0)
                  MoneyRow(t.biz_due, _due, valueColor: Theme.of(context).colorScheme.error),
              ]),
            ),
            const SizedBox(height: Gap.xl),
            FilledButton(
              onPressed: _busy ? null : _confirm,
              style: FilledButton.styleFrom(backgroundColor: scheme.primary),
              child: _busy
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(t.biz_sale_done),
            ),
            const SizedBox(height: Gap.lg),
          ],
        ),
      ),
    );
  }
}
