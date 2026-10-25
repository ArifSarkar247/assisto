import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../theme.dart';
import '../../api.dart';
import '../../business_selling_api.dart';
import '../../widgets/skeleton.dart';
import '../../widgets/subs_common.dart' show fmtInt;
import '../../l10n/app_localizations.dart';
import 'selling_common.dart';

/// q1-seams: true only once a real xlsx/csv file picker is bundled.
const bool kProductImportPickerWired = false;

/// Products catalogue (§3). Photos, variants (size/colour), selling / cost /
/// MINIMUM price, stock per variant, categories, barcode, Excel import.
///
/// Cost, minimum and profit/margin are shown ONLY to owners — staff rows arrive
/// redacted from the server and the UI hides those fields (see [SellRole]).
class ProductsScreen extends StatefulWidget {
  final int? businessId;
  const ProductsScreen({super.key, this.businessId});
  @override
  State<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends State<ProductsScreen> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  Object? _error;
  String _q = '';
  String? _category;
  SellRole _role = const SellRole('');

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
      final list = await sellApi(context).productsList(
          businessId: widget.businessId, category: _category, query: _q);
      // Infer role from the first row's redaction (cost present => owner).
      final staffLike =
          list.isNotEmpty && isRedacted(list.first, 'cost_price');
      _role = SellRole(staffLike ? 'staff' : 'owner');
      _items = list;
    } catch (e) {
      _error = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  List<String> get _categories {
    final set = <String>{};
    for (final p in _items) {
      final c = (p['category'] ?? '').toString();
      if (c.isNotEmpty) set.add(c);
    }
    return set.toList()..sort();
  }

  Future<void> _openSheet([Map<String, dynamic>? product]) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => ProductEditSheet(
          businessId: widget.businessId, role: _role, product: product),
    );
    if (changed == true) _load();
  }

  Future<void> _openImport() async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => ProductImportSheet(businessId: widget.businessId),
    );
    if (changed == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.shopQaProducts),
        actions: [
          // q1-seams: hidden until a real spreadsheet picker ships — the sheet
          // used ImagePicker.pickMedia, which can never select an .xlsx/.csv
          // (proposal: file_picker in .phaseB/proposals/q1-seams.md).
          if (!_role.isStaff && kProductImportPickerWired)
            IconButton(
              tooltip: t.biz_import_title,
              icon: const Icon(Icons.upload_file_outlined),
              onPressed: _openImport,
            ),
        ],
      ),
      floatingActionButton: _role.isStaff
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _openSheet(),
              icon: const Icon(Icons.add),
              label: Text(t.shopQaAddProduct),
            ),
      body: Column(children: [
        SellHeader(
            icon: Icons.inventory_2_outlined,
            title: t.shopQaProducts,
            subtitle: null),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.sm),
          child: TextField(
            decoration: InputDecoration(
              hintText: '${t.biz_product_name} / ${t.biz_product_barcode}',
              prefixIcon: const Icon(Icons.search),
            ),
            onSubmitted: (v) {
              _q = v.trim();
              _load();
            },
          ),
        ),
        if (_categories.isNotEmpty)
          SizedBox(
            height: 42,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
              children: [
                _catChip(t.biz_product_category, null),
                for (final c in _categories) _catChip(c, c),
              ],
            ),
          ),
        if (_role.isStaff) const StaffRedactedNote(),
        Expanded(child: _body(t, scheme)),
      ]),
    );
  }

  Widget _catChip(String label, String? value) {
    final selected = _category == value;
    return Padding(
      padding: const EdgeInsets.only(right: Gap.sm),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) {
          setState(() => _category = value);
          _load();
        },
      ),
    );
  }

  Widget _body(AppLocalizations t, ColorScheme scheme) {
    if (_loading) return const SkeletonList();
    if (_error != null) {
      return StateMessage(
        icon: Icons.cloud_off,
        tint: scheme.error,
        title: t.loadFailed,
        message: _error is ApiException ? (_error as ApiException).message : null,
        action: FilledButton.tonalIcon(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            label: Text(t.retry)),
      );
    }
    if (_items.isEmpty) {
      return StateMessage(
        icon: Icons.inventory_2_outlined,
        title: t.shopQaNoProductsTitle,
        message: t.shopQaNoProductsBody,
        action: _role.isStaff
            ? null
            : FilledButton.icon(
                onPressed: () => _openSheet(),
                icon: const Icon(Icons.add),
                label: Text(t.shopQaAddProduct)),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.all(Gap.lg),
        itemCount: _items.length,
        separatorBuilder: (_, __) => const SizedBox(height: Gap.md),
        itemBuilder: (_, i) => _ProductTile(
          product: _items[i],
          role: _role,
          onTap: _role.isStaff ? null : () => _openSheet(_items[i]),
        ),
      ),
    );
  }
}

class _ProductTile extends StatelessWidget {
  final Map<String, dynamic> product;
  final SellRole role;
  final VoidCallback? onTap;
  const _ProductTile({required this.product, required this.role, this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final name = (product['name'] ?? '').toString();
    final photo = (product['photo'] ?? product['image'] ?? '').toString();
    final sell = poishaOf(product['price'] ?? product['sell_price']);
    final cost = poishaOf(product['cost_price']);
    final min = poishaOf(product['min_price']);
    final stock = (product['stock'] ?? 0) as num;
    final lowAt = (product['low_stock_at'] ?? 3) as num;
    final variants = (product['variants'] as List?) ?? const [];
    final showCost = role.canSeeCost && !isRedacted(product, 'cost_price');
    final profit = sell - cost;
    final margin = sell > 0 ? (profit / sell * 100) : 0;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Radii.md),
      child: SellCard(
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _thumb(scheme, photo),
          const SizedBox(width: Gap.md),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: Gap.xs),
              Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
                _tag('${t.biz_sell_price}: ${sell.takaIn(context)}',
                    scheme.primaryContainer, scheme.onPrimaryContainer),
                if (showCost && min > 0)
                  _tag('${t.biz_min_price}: ${min.takaIn(context)}',
                      scheme.tertiaryContainer, scheme.onTertiaryContainer),
                _stockTag(context, t, stock, lowAt),
                if (variants.isNotEmpty)
                  _tag(t.qa1VariantCount(variants.length, fmtInt(context, variants.length)),
                      scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
              ]),
              if (showCost) ...[
                const SizedBox(height: 6),
                Text(
                  '${t.biz_profit}: ${profit.takaIn(context)}  ·  ${t.biz_margin}: ${margin.toStringAsFixed(0)}%',
                  style: AType.labelMedium.copyWith(color: profit >= 0 ? AssistoTokens.of(context).success : Theme.of(context).colorScheme.error,
                      fontWeight: FontWeight.w600),
                ),
              ],
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _thumb(ColorScheme scheme, String photo) {
    return Container(
      width: 52,
      height: 52,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: photo.startsWith('http')
          ? Image.network(photo,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) =>
                  Icon(Icons.image_outlined, color: scheme.onSurfaceVariant))
          : Icon(Icons.inventory_2_outlined, color: scheme.onSurfaceVariant),
    );
  }

  Widget _tag(String s, Color bg, Color fg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 3),
        decoration:
            BoxDecoration(color: bg, borderRadius: BorderRadius.circular(Radii.pill)),
        child: Text(s,
            style:
                AType.labelMedium.copyWith(color: fg, fontWeight: FontWeight.w600)),
      );

  Widget _stockTag(BuildContext ctx, AppLocalizations t, num stock, num lowAt) {
    final scheme = Theme.of(ctx).colorScheme;
    if (stock <= 0) {
      return _tag(t.biz_out_of_stock,
          Theme.of(ctx).colorScheme.error.withValues(alpha: 0.15), Theme.of(ctx).colorScheme.error);
    }
    if (stock <= lowAt) {
      return _tag('${t.biz_low_stock} ($stock)',
          AssistoTokens.of(ctx).warning.withValues(alpha: 0.18), AssistoTokens.of(ctx).warning);
    }
    return _tag('${t.biz_stock}: $stock', scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant);
  }
}

// ============================================================ add / edit sheet

/// Add or edit a product with its variants, photo, prices and stock. Owner-only
/// fields (cost / minimum) are hidden entirely when [role] is staff.
class ProductEditSheet extends StatefulWidget {
  final int? businessId;
  final SellRole role;
  final Map<String, dynamic>? product;
  const ProductEditSheet(
      {super.key, this.businessId, required this.role, this.product});
  @override
  State<ProductEditSheet> createState() => _ProductEditSheetState();
}

class _ProductEditSheetState extends State<ProductEditSheet> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _category = TextEditingController();
  final _sku = TextEditingController();
  final _barcode = TextEditingController();
  final _desc = TextEditingController();
  final _sell = TextEditingController();
  final _cost = TextEditingController();
  final _min = TextEditingController();
  final _stock = TextEditingController();
  String? _photoPath;
  bool _saving = false;
  final List<_VariantDraft> _variants = [];

  bool get _editing => widget.product != null;
  bool get _showCost => widget.role.canSeeCost;

  @override
  void initState() {
    super.initState();
    final p = widget.product;
    if (p != null) {
      _name.text = (p['name'] ?? '').toString();
      _category.text = (p['category'] ?? '').toString();
      _sku.text = (p['sku'] ?? '').toString();
      _barcode.text = (p['barcode'] ?? '').toString();
      _desc.text = (p['description'] ?? '').toString();
      _sell.text = _takaText(p['price'] ?? p['sell_price']);
      _cost.text = _takaText(p['cost_price']);
      _min.text = _takaText(p['min_price']);
      _stock.text = (p['stock'] ?? '').toString();
      _photoPath = (p['photo'] ?? '').toString().isEmpty
          ? null
          : (p['photo']).toString();
      for (final v in (p['variants'] as List? ?? const [])) {
        _variants.add(_VariantDraft.fromMap(v as Map<String, dynamic>));
      }
    }
  }

  String _takaText(dynamic poisha) {
    final p = poishaOf(poisha);
    if (p == 0) return '';
    return p.takaValue.toStringAsFixed(2).replaceFirst(RegExp(r'\.00$'), '');
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _category,
      _sku,
      _barcode,
      _desc,
      _sell,
      _cost,
      _min,
      _stock
    ]) {
      c.dispose();
    }
    for (final v in _variants) {
      v.dispose();
    }
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    final x = await ImagePicker()
        .pickImage(source: ImageSource.gallery, imageQuality: 70);
    if (x != null) setState(() => _photoPath = x.path);
  }

  String? _validateMinVsSell(AppLocalizations t) {
    final sell = parseTaka(_sell.text);
    final min = parseTaka(_min.text);
    final cost = parseTaka(_cost.text);
    if (sell != null && min != null && min > sell) return t.biz_err_min_gt_sell;
    if (sell != null && cost != null && cost > sell) return t.biz_err_cost_gt_sell;
    return null;
  }

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    if (!_form.currentState!.validate()) return;
    final crossErr = _validateMinVsSell(t);
    if (crossErr != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(crossErr)));
      return;
    }
    setState(() => _saving = true);
    try {
      final sell = parseTaka(_sell.text) ?? 0;
      final body = <String, dynamic>{
        if (widget.businessId != null) 'business': widget.businessId,
        'name': _name.text.trim(),
        'category': _category.text.trim(),
        'sku': _sku.text.trim(),
        'barcode': _barcode.text.trim(),
        'description': _desc.text.trim(),
        'price': '$sell',
        'stock': int.tryParse(_stock.text.trim()) ?? 0,
        if (_showCost) 'cost_price': '${parseTaka(_cost.text) ?? 0}',
        if (_showCost) 'min_price': '${parseTaka(_min.text) ?? 0}',
        'variants': [
          for (final v in _variants) v.toBody(showCost: _showCost),
        ],
      };
      final api = sellApi(context);
      if (_editing) {
        await api.productUpdate(widget.product!['id'] as int, body);
      } else {
        await api.productCreate(body);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showApiError(context, e);
    }
    if (mounted) setState(() => _saving = false);
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
        initialChildSize: 0.9,
        maxChildSize: 0.95,
        builder: (_, scroll) => Form(
          key: _form,
          child: ListView(
            controller: scroll,
            padding: const EdgeInsets.all(Gap.lg),
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                      color: scheme.outlineVariant,
                      borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const SizedBox(height: Gap.lg),
              _photoPicker(t, scheme),
              const SizedBox(height: Gap.lg),
              TextFormField(
                controller: _name,
                decoration: InputDecoration(labelText: t.biz_product_name),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? t.biz_err_bad_name : null,
              ),
              const SizedBox(height: Gap.md),
              Row(children: [
                Expanded(
                  child: TextFormField(
                    controller: _category,
                    decoration:
                        InputDecoration(labelText: t.biz_product_category),
                  ),
                ),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: TextFormField(
                    controller: _sku,
                    decoration: InputDecoration(labelText: t.biz_product_sku),
                  ),
                ),
              ]),
              const SizedBox(height: Gap.md),
              TextFormField(
                controller: _barcode,
                keyboardType: TextInputType.text,
                decoration: InputDecoration(
                  labelText: t.biz_product_barcode,
                  prefixIcon: const Icon(Icons.qr_code_2),
                ),
              ),
              const SizedBox(height: Gap.md),
              MoneyField(
                controller: _sell,
                label: t.biz_sell_price,
                validator: (v) =>
                    parseTaka(v ?? '') == null ? t.biz_err_bad_price : null,
              ),
              if (_showCost) ...[
                const SizedBox(height: Gap.md),
                // stacked, not side by side: "Minimum price" + its helper
                // were cut to "Minimum pri…" / "Bargain (override …" at 360 px
                MoneyField(controller: _cost, label: t.biz_cost_price),
                const SizedBox(height: Gap.md),
                MoneyField(
                    controller: _min,
                    label: t.biz_min_price,
                    helper: t.biz_price_override),
              ],
              const SizedBox(height: Gap.md),
              TextFormField(
                controller: _stock,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: t.biz_stock),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return null;
                  final n = int.tryParse(v.trim());
                  return (n == null || n < 0) ? t.biz_err_bad_stock : null;
                },
              ),
              const SizedBox(height: Gap.md),
              TextFormField(
                controller: _desc,
                maxLines: 2,
                decoration:
                    InputDecoration(labelText: t.biz_product_description),
              ),
              const SizedBox(height: Gap.lg),
              _variantsSection(t, scheme),
              const SizedBox(height: Gap.xl),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(t.save), // was "Add to cart" on the product form
              ),
              const SizedBox(height: Gap.lg),
            ],
          ),
        ),
      ),
    );
  }

  Widget _photoPicker(AppLocalizations t, ColorScheme scheme) {
    final hasLocal = _photoPath != null && !_photoPath!.startsWith('http');
    final hasRemote = _photoPath != null && _photoPath!.startsWith('http');
    return GestureDetector(
      onTap: _pickPhoto,
      child: Container(
        height: 120,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: hasLocal
            ? Image.file(File(_photoPath!), fit: BoxFit.cover)
            : hasRemote
                ? Image.network(_photoPath!, fit: BoxFit.cover)
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.add_a_photo_outlined,
                          color: scheme.onSurfaceVariant),
                      const SizedBox(height: Gap.sm),
                      Text(t.biz_product_photo,
                          style: TextStyle(color: scheme.onSurfaceVariant)),
                    ],
                  ),
      ),
    );
  }

  Widget _variantsSection(AppLocalizations t, ColorScheme scheme) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap( // qa1: heading + action wrap at large font
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
        Text(t.biz_product_variant,
            style: const TextStyle(fontWeight: FontWeight.w700)),
        TextButton.icon(
          onPressed: () => setState(() => _variants.add(_VariantDraft())),
          icon: const Icon(Icons.add, size: 18),
          label: Text(t.shopQaAddVariant),
        ),
      ]),
      for (int i = 0; i < _variants.length; i++) ...[
        const SizedBox(height: Gap.sm),
        _variantRow(t, scheme, i),
      ],
    ]);
  }

  Widget _variantRow(AppLocalizations t, ColorScheme scheme, int i) {
    final v = _variants[i];
    return SellCard(
      padding: const EdgeInsets.all(Gap.md),
      child: Column(children: [
        Row(children: [
          Expanded(
            child: TextField(
              controller: v.size,
              decoration: InputDecoration(labelText: t.biz_product_size),
            ),
          ),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: TextField(
              controller: v.colour,
              decoration: InputDecoration(labelText: t.biz_product_colour),
            ),
          ),
          IconButton(
            tooltip: AppLocalizations.of(context).delete,
            icon: Icon(Icons.delete_outline, color: scheme.error),
            onPressed: () => setState(() {
              _variants.removeAt(i).dispose();
            }),
          ),
        ]),
        const SizedBox(height: Gap.sm),
        Row(children: [
          Expanded(
            child: MoneyField(controller: v.sell, label: t.biz_sell_price),
          ),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: TextField(
              controller: v.stock,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: t.biz_stock),
            ),
          ),
        ]),
        if (_showCost) ...[
          const SizedBox(height: Gap.sm),
          Row(children: [
            Expanded(
                child: MoneyField(controller: v.cost, label: t.biz_cost_price)),
            const SizedBox(width: Gap.sm),
            Expanded(
                child: MoneyField(controller: v.min, label: t.biz_min_price)),
          ]),
        ],
      ]),
    );
  }
}

class _VariantDraft {
  final size = TextEditingController();
  final colour = TextEditingController();
  final sell = TextEditingController();
  final cost = TextEditingController();
  final min = TextEditingController();
  final stock = TextEditingController();
  int? id;

  _VariantDraft();

  factory _VariantDraft.fromMap(Map<String, dynamic> m) {
    final d = _VariantDraft();
    d.id = m['id'] as int?;
    d.size.text = (m['size'] ?? '').toString();
    d.colour.text = (m['colour'] ?? '').toString();
    d.sell.text = _t(m['sell_price']);
    d.cost.text = _t(m['cost_price']);
    d.min.text = _t(m['min_price']);
    d.stock.text = (m['stock'] ?? '').toString();
    return d;
  }

  static String _t(dynamic poisha) {
    final p = poishaOf(poisha);
    if (p == 0) return '';
    return p.takaValue.toStringAsFixed(2).replaceFirst(RegExp(r'\.00$'), '');
  }

  Map<String, dynamic> toBody({required bool showCost}) => {
        if (id != null) 'id': id,
        'size': size.text.trim(),
        'colour': colour.text.trim(),
        'sell_price': '${parseTaka(sell.text) ?? 0}',
        'stock': int.tryParse(stock.text.trim()) ?? 0,
        if (showCost) 'cost_price': '${parseTaka(cost.text) ?? 0}',
        if (showCost) 'min_price': '${parseTaka(min.text) ?? 0}',
      };

  void dispose() {
    size.dispose();
    colour.dispose();
    sell.dispose();
    cost.dispose();
    min.dispose();
    stock.dispose();
  }
}

// ============================================================ Excel import

/// Pick an Excel/CSV file → preview parsed rows (bad_rows / conflicts
/// highlighted) → confirm to persist. Two-phase against products/import/.
class ProductImportSheet extends StatefulWidget {
  final int? businessId;
  const ProductImportSheet({super.key, this.businessId});
  @override
  State<ProductImportSheet> createState() => _ProductImportSheetState();
}

class _ProductImportSheetState extends State<ProductImportSheet> {
  String? _filePath;
  Map<String, dynamic>? _preview;
  bool _busy = false;

  Future<void> _pick() async {
    // TODO(excel-import): a real xlsx/csv file picker is still PENDING. We do
    // NOT bundle `file_picker` (no new pubspec deps), so this uses the
    // ImagePicker `pickMedia` placeholder to obtain a path — it will only
    // surface media files, not spreadsheets. Replace with a proper
    // xlsx/csv picker (e.g. file_picker or a platform channel) before shipping
    // Excel import. Until then the two-phase preview/confirm wiring below is
    // exercised against whatever path the placeholder returns.
    final x = await ImagePicker().pickMedia();
    if (x != null) {
      setState(() {
        _filePath = x.path;
        _preview = null;
      });
      await _loadPreview();
    }
  }

  Future<void> _loadPreview() async {
    if (_filePath == null) return;
    setState(() => _busy = true);
    try {
      _preview = await sellApi(context).productsImport(
          filePath: _filePath!, businessId: widget.businessId, confirm: false);
    } catch (e) {
      if (mounted) showApiError(context, e);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _confirm() async {
    if (_filePath == null) return;
    setState(() => _busy = true);
    try {
      await sellApi(context).productsImport(
          filePath: _filePath!, businessId: widget.businessId, confirm: true);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showApiError(context, e);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final rows =
        ((_preview?['products'] ?? _preview?['rows'] ?? []) as List);
    final bad = ((_preview?['bad_rows'] ?? []) as List);
    final conflicts = ((_preview?['conflicts'] ?? []) as List);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      builder: (_, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.all(Gap.lg),
        children: [
          Text(t.biz_import_title,
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Gap.md),
          FilledButton.tonalIcon(
            onPressed: _busy ? null : _pick,
            icon: const Icon(Icons.attach_file),
            label: Text(_filePath == null
                ? t.biz_import_title
                : _filePath!.split('/').last),
          ),
          if (_busy) ...[
            const SizedBox(height: Gap.lg),
            const Center(child: CircularProgressIndicator()),
          ],
          if (_preview != null && !_busy) ...[
            const SizedBox(height: Gap.lg),
            if (bad.isNotEmpty || conflicts.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(Gap.md),
                decoration: BoxDecoration(
                  color: AssistoTokens.of(context).warning.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(Radii.sm),
                ),
                child: Row(children: [
                  Icon(Icons.warning_amber, color: AssistoTokens.of(context).warning),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: Text(
                      '${t.biz_import_bad_rows} (${bad.length + conflicts.length})',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ]),
              ),
            const SizedBox(height: Gap.md),
            Text('${rows.length} · ${t.biz_product_name}',
                style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: Gap.sm),
            for (final r in rows.take(50))
              _previewRow(context, r as Map, scheme),
            for (final c in conflicts.take(20))
              _badRow(context, c as Map, scheme,
                  (c['reason'] ?? t.biz_err_dup_sku).toString()),
            for (final b in bad.take(20))
              _badRow(context, b as Map, scheme,
                  (b['reason'] ?? t.biz_import_bad_rows).toString()),
            const SizedBox(height: Gap.xl),
            FilledButton(
              onPressed: rows.isEmpty ? null : _confirm,
              child: Text(t.biz_cart_add),
            ),
          ],
          const SizedBox(height: Gap.lg),
        ],
      ),
    );
  }

  Widget _previewRow(BuildContext ctx, Map r, ColorScheme scheme) {
    final sell = poishaOf(r['price'] ?? r['sell_price']);
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(Icons.check_circle_outline, color: AssistoTokens.of(context).success, size: 20),
      title: Text((r['name'] ?? '').toString()),
      trailing: Text(sell.takaIn(context),
          style: const TextStyle(fontWeight: FontWeight.w600)),
    );
  }

  Widget _badRow(BuildContext ctx, Map r, ColorScheme scheme, String reason) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(Icons.error_outline, color: scheme.error, size: 20),
      title: Text((r['name'] ?? '').toString()),
      subtitle: Text(reason,
          style: AType.bodySmall.copyWith(color: scheme.error)),
    );
  }
}
