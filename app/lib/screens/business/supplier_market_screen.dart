import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/skeleton.dart';
import '../../services/error_kind.dart' show honestFailText; // qa2

/// SUPPLIER & WHOLESALE MARKET — ADVANCED (#144, SPEC v2.1 §21).
///
/// A supplier directory/MANAGER for one business. The user records THEIR OWN
/// suppliers — name, category, products, location, contact, price notes, a 0–5
/// rating — and the screen searches/filters by category + location + rating,
/// compares a shortlist side-by-side, and keeps a reorder/contact list.
///
/// ONLY the user's own suppliers are ever shown. We NEVER scrape a LinkedIn-style
/// external directory, never invent a vendor, never fabricate a price/review. A
/// real partner/wholesale-market directory is a DOCUMENTED, key-gated SEAM only,
/// surfaced as an honest "connect a partner-directory source" card (no such key
/// in the Integrations registry yet).
///
/// `_SMath` mirrors backend/core/logic/supplier_market.py (filter/compare/
/// reorder). ZERO Bangla literals — every string is an AppLocalizations getter;
/// the ৳ glyph is a currency sign (gate-exempt).
///
/// Persistence (generic api helpers, NO api.dart edit):
///   listItems('supplier/vendors') → [{id, name, category, products, location,
///     contact, price_note, rating, note, reorder}]
/// create/update/deleteItem on the same path; each row round-trips through one
/// flexible per-user JSON collection. `products` is sent as the raw "a, b"
/// string the user typed; `category` is a stable slug; `rating` a 0–5 int.
class SupplierMarketScreen extends StatefulWidget {
  const SupplierMarketScreen({super.key});
  @override
  State<SupplierMarketScreen> createState() => _SupplierMarketScreenState();
}

const String _path = 'supplier/vendors';
const List<String> _categories = [
  'raw_material',
  'wholesale',
  'packaging',
  'electronics',
  'clothing',
  'food',
  'logistics',
  'services',
  'other',
];

String _catLabel(AppLocalizations tr, String c) {
  switch (c) {
    case 'raw_material':
      return tr.supCatRawMaterial;
    case 'wholesale':
      return tr.supCatWholesale;
    case 'packaging':
      return tr.supCatPackaging;
    case 'electronics':
      return tr.supCatElectronics;
    case 'clothing':
      return tr.supCatClothing;
    case 'food':
      return tr.supCatFood;
    case 'logistics':
      return tr.supCatLogistics;
    case 'services':
      return tr.supCatServices;
    default:
      return tr.supCatOther;
  }
}

class _SupplierMarketScreenState extends State<SupplierMarketScreen> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true, _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

  String _query = '';
  String _category = '';
  String _location = '';
  int _minRating = 0;
  bool _reorderOnly = false;

  final Set<Object> _compareIds = {};
  bool _compareMode = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    final api = context.read<AppState>().api;
    try {
      _rows = await api.listItems(_path);
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _add() async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final res = await _supplierSheet(context, null);
    if (res == null) return;
    try {
      await api.createItem(_path, res);
      await _load();
      if (mounted) _toast(tr.saved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _edit(Map<String, dynamic> row) async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final res = await _supplierSheet(context, row);
    if (res == null) return;
    try {
      await api.updateItem(_path, row['id'] as int, res);
      await _load();
      if (mounted) _toast(tr.saved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _delete(Map<String, dynamic> row) async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final ok = await _confirm(context, tr.supDeleteTitle, tr.supDeleteBody);
    if (ok != true) return;
    try {
      await api.deleteItem(_path, row['id'] as int);
      _compareIds.remove(row['id']);
      await _load();
      if (mounted) _toast(tr.saved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _toggleReorder(Map<String, dynamic> row, bool on) async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    try {
      await api.updateItem(_path, row['id'] as int, {'reorder': on});
      await _load();
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;

    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.supTitle)),
        body: const SkeletonList(),
      );
    }
    if (_error) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.supTitle)),
        body: StateMessage(
          icon: Icons.cloud_off,
          tint: scheme.error,
          title: tr.loadFailed,
          message: honestFailText(tr, _failCause, otherwise: tr.supLoadError),
          action: FilledButton.tonalIcon(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            label: Text(tr.retry),
          ),
        ),
      );
    }

    final result = _SMath.search(
      _rows,
      query: _query,
      category: _category,
      location: _location,
      minRating: _minRating,
      reorderOnly: _reorderOnly,
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(tr.supTitle),
        actions: [
          if (_rows.isNotEmpty)
            IconButton(
              tooltip: _compareMode ? tr.supCompareDone : tr.supCompare,
              icon: Icon(_compareMode
                  ? Icons.check_circle_outline
                  : Icons.compare_arrows),
              onPressed: () => setState(() {
                _compareMode = !_compareMode;
                if (!_compareMode) _compareIds.clear();
              }),
            ),
        ],
      ),
      floatingActionButton: _compareMode
          ? FloatingActionButton.extended(
              onPressed: _compareIds.length >= 2
                  ? () => _openCompare(result)
                  : null,
              icon: const Icon(Icons.compare_arrows),
              label: Text(tr.supCompareN(_compareIds.length)),
              backgroundColor: _compareIds.length >= 2 ? null : scheme.surfaceContainerHighest,
            )
          : _rows.isEmpty
              ? null // qa1: the empty state's CTA is the same action
              : FloatingActionButton.extended(
                  onPressed: _add,
                  icon: const Icon(Icons.add),
                  label: Text(tr.supAddSupplier),
                ),
      body: _rows.isEmpty
          ? StateMessage(
              icon: Icons.inventory_2_outlined,
              title: tr.supWelcomeTitle,
              message: tr.supWelcomeBody,
              action: FilledButton.icon(
                onPressed: _add,
                icon: const Icon(Icons.add),
                label: Text(tr.supAddSupplier),
              ),
            )
          : Column(
              children: [
                _filterBar(context, tr, result),
                Expanded(
                  child: result.suppliers.isEmpty
                      ? StateMessage(
                          icon: Icons.search_off,
                          title: tr.supNoMatchTitle,
                          message: tr.supNoMatchBody,
                          action: TextButton(
                            onPressed: _clearFilters,
                            child: Text(tr.supClearFilters),
                          ),
                        )
                      : ListView(
                          padding: const EdgeInsets.fromLTRB(
                              Gap.lg, Gap.sm, Gap.lg, 96),
                          children: [
                            _manualNote(context, tr),
                            const SizedBox(height: Gap.sm),
                            if (_compareMode)
                              Padding(
                                padding: const EdgeInsets.only(bottom: Gap.sm),
                                child: Text(tr.supComparePick,
                                    style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
                              ),
                            ...result.suppliers.map((s) => _supplierCard(
                                context, tr, s)),
                            const SizedBox(height: Gap.md),
                            _partnerSeamCard(context, tr),
                          ],
                        ),
                ),
              ],
            ),
    );
  }

  void _clearFilters() => setState(() {
        _query = '';
        _category = '';
        _location = '';
        _minRating = 0;
        _reorderOnly = false;
      });

  Future<void> _openCompare(_SResult result) async {
    final ids = _compareIds.toList();
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _CompareScreen(rows: _rows, ids: ids),
    ));
  }

  Widget _filterBar(
      BuildContext context, AppLocalizations tr, _SResult result) {
    final scheme = Theme.of(context).colorScheme;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, 0),
        child: TextField(
          onChanged: (v) => setState(() => _query = v),
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.search),
            hintText: tr.supSearchHint,
            border:
                OutlineInputBorder(borderRadius: BorderRadius.circular(Radii.md)),
          ),
        ),
      ),
      SizedBox(
        height: Gap.xxxl,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
          children: [
            Padding(
              padding: const EdgeInsets.only(top: Gap.sm, right: Gap.sm),
              child: FilterChip(
                label: Text(tr.supReorderOnly),
                avatar: const Icon(Icons.shopping_cart_outlined, size: 16),
                selected: _reorderOnly,
                onSelected: (v) => setState(() => _reorderOnly = v),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: Gap.sm, right: Gap.sm),
              child: FilterChip(
                label: Text(tr.supRatedMin4),
                avatar: const Icon(Icons.star_outline, size: 16),
                selected: _minRating >= 4,
                onSelected: (v) => setState(() => _minRating = v ? 4 : 0),
              ),
            ),
            for (final c in _categories)
              if ((result.byCategory[c] ?? 0) > 0 || _category == c)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.sm, right: Gap.sm),
                  child: ChoiceChip(
                    label: Text(
                        '${_catLabel(tr, c)} (${result.byCategory[c] ?? 0})'),
                    selected: _category == c,
                    onSelected: (v) =>
                        setState(() => _category = v ? c : ''),
                  ),
                ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xs),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: Text(
            tr.supMatchCount(result.matchCount, result.totalCount),
            style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      ),
    ]);
  }

  Widget _manualNote(BuildContext context, AppLocalizations tr) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(children: [
          Icon(Icons.info_outline, size: 18, color: scheme.primary),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(tr.supManualNote,
                style: AType.bodySmall.copyWith(height: 1.4, color: scheme.onSurfaceVariant)),
          ),
        ]),
      ),
    );
  }

  Widget _supplierCard(
      BuildContext context, AppLocalizations tr, _SSupplier s) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _compareIds.contains(s.id);
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: _compareMode && s.id != null
            ? () => setState(() {
                  if (selected) {
                    _compareIds.remove(s.id);
                  } else {
                    _compareIds.add(s.id as Object);
                  }
                })
            : () => _edit(s.raw),
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  if (_compareMode)
                    Padding(
                      padding: const EdgeInsets.only(right: Gap.sm),
                      child: Icon(
                          selected
                              ? Icons.check_box
                              : Icons.check_box_outline_blank,
                          color: selected
                              ? scheme.primary
                              : scheme.onSurfaceVariant),
                    ),
                  Expanded(
                    child: Text(s.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AType.titleMedium.copyWith(fontWeight: FontWeight.w800)),
                  ),
                  if (s.rating > 0) _ratingChip(context, s.rating),
                ]),
                const SizedBox(height: Gap.xs),
                Wrap(spacing: Gap.sm, runSpacing: Gap.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  _tag(context, Icons.category_outlined,
                      _catLabel(tr, s.category)),
                  if (s.location.isNotEmpty)
                    _tag(context, Icons.place_outlined, s.location),
                ]),
                if (s.productsDisplay.isNotEmpty) ...[
                  const SizedBox(height: Gap.sm),
                  Text(s.productsDisplay,
                      style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant)),
                ],
                if (s.priceNote.isNotEmpty) ...[
                  const SizedBox(height: Gap.xs),
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(Icons.sell_outlined,
                        size: 15, color: scheme.onSurfaceVariant),
                    const SizedBox(width: Gap.xs),
                    Expanded(
                      child: Text(s.priceNote,
                          style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
                    ),
                  ]),
                ],
                if (!_compareMode) ...[
                  const Divider(height: Gap.lg),
                  Row(children: [
                    if (s.contact.isNotEmpty)
                      Expanded(
                        child: Row(children: [
                          Icon(Icons.call_outlined,
                              size: 15, color: scheme.primary),
                          const SizedBox(width: Gap.xs),
                          Expanded(
                            child: Text(s.contact,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AType.bodySmall.copyWith(color: scheme.primary)),
                          ),
                        ]),
                      )
                    else
                      const Spacer(),
                    Tooltip(
                      message: tr.supReorderToggle,
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.shopping_cart_outlined,
                            size: 16, color: scheme.onSurfaceVariant),
                        Switch(
                          value: s.reorder,
                          onChanged: s.id == null
                              ? null
                              : (v) => _toggleReorder(s.raw, v),
                        ),
                      ]),
                    ),
                    IconButton(
                      tooltip: AppLocalizations.of(context).edit,
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      onPressed: () => _edit(s.raw),
                    ),
                    IconButton(
                      tooltip: AppLocalizations.of(context).delete,
                      visualDensity: VisualDensity.compact,
                      icon: Icon(Icons.delete_outline,
                          size: 18, color: scheme.error),
                      onPressed: () => _delete(s.raw),
                    ),
                  ]),
                ],
              ]),
        ),
      ),
    );
  }

  Widget _ratingChip(BuildContext context, int rating) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 3),
      decoration: BoxDecoration(
        color: AssistoTokens.of(context).warning.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.star, size: 13, color: AssistoTokens.of(context).warning),
        const SizedBox(width: 3),
        Text('$rating',
            style: AType.labelMedium.copyWith(fontWeight: FontWeight.w700,
                color: AssistoTokens.of(context).warning)),
      ]),
    );
  }

  Widget _tag(BuildContext context, IconData icon, String text) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 13, color: scheme.onSurfaceVariant),
        const SizedBox(width: Gap.xs),
        Text(text,
            style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
      ]),
    );
  }

  Widget _partnerSeamCard(BuildContext context, AppLocalizations tr) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.hub_outlined, size: 20, color: scheme.primary),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(tr.supPartnerSeamTitle,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
          ]),
          const SizedBox(height: 6),
          Text(tr.supPartnerSeamBody,
              style: AType.bodySmall.copyWith(height: 1.4, color: scheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}

// ---- compare screen ---------------------------------------------------------

class _CompareScreen extends StatelessWidget {
  final List<Map<String, dynamic>> rows;
  final List<Object> ids;
  const _CompareScreen({required this.rows, required this.ids});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final cmp = _SMath.compare(rows, ids);
    return Scaffold(
      appBar: AppBar(title: Text(tr.supCompare)),
      body: ListView(
        padding: const EdgeInsets.all(Gap.lg),
        children: [
          Text(tr.supCompareIntro,
              style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.md),
          for (final s in cmp.suppliers)
            Card(
              color: cmp.bestRatingId != null && cmp.bestRatingId == s.id
                  ? scheme.primaryContainer
                  : null,
              child: Padding(
                padding: const EdgeInsets.all(Gap.md),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(
                          child: Text(s.name,
                              style: AType.titleMedium.copyWith(fontWeight: FontWeight.w800)),
                        ),
                        if (cmp.bestRatingId != null &&
                            cmp.bestRatingId == s.id)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: Gap.sm, vertical: 3),
                            decoration: BoxDecoration(
                              color: scheme.primary,
                              borderRadius: BorderRadius.circular(Radii.pill),
                            ),
                            child: Text(tr.supBestRated,
                                style: AType.labelSmall.copyWith(color: Colors.white,
                                    fontWeight: FontWeight.w700)),
                          ),
                      ]),
                      const SizedBox(height: Gap.sm),
                      _cmpRow(context, tr.supFieldRating,
                          s.rating > 0 ? '${s.rating} / 5' : tr.supUnrated),
                      _cmpRow(context, tr.supFieldCategory,
                          _catLabel(tr, s.category)),
                      _cmpRow(
                          context,
                          tr.supFieldLocation,
                          s.location.isEmpty ? '—' : s.location),
                      _cmpRow(context, tr.supFieldProducts,
                          s.productsDisplay.isEmpty ? '—' : s.productsDisplay),
                      _cmpRow(context, tr.supFieldPriceNote,
                          s.priceNote.isEmpty ? '—' : s.priceNote),
                      _cmpRow(context, tr.supFieldContact,
                          s.contact.isEmpty ? '—' : s.contact),
                      if (s.reorder)
                        Padding(
                          padding: const EdgeInsets.only(top: Gap.sm),
                          child: Row(children: [
                            Icon(Icons.shopping_cart_outlined,
                                size: 15, color: scheme.primary),
                            const SizedBox(width: Gap.xs),
                            Text(tr.supOnReorderList,
                                style: AType.bodySmall.copyWith(color: scheme.primary)),
                          ]),
                        ),
                    ]),
              ),
            ),
        ],
      ),
    );
  }

  Widget _cmpRow(BuildContext context, String label, String value) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 96,
          child: Text(label,
              style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
        ),
        Expanded(
          child: Text(value,
              style: AType.titleSmall.copyWith(fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }
}

// ---- add/edit sheet ---------------------------------------------------------

Future<Map<String, dynamic>?> _supplierSheet(
    BuildContext context, Map<String, dynamic>? existing) {
  final tr = AppLocalizations.of(context);
  final nameCtl =
      TextEditingController(text: (existing?['name'] ?? '').toString());
  final productsCtl = TextEditingController(
      text: _SMath.productsToInput(existing?['products']));
  final locationCtl =
      TextEditingController(text: (existing?['location'] ?? '').toString());
  final contactCtl =
      TextEditingController(text: (existing?['contact'] ?? '').toString());
  final priceCtl =
      TextEditingController(text: (existing?['price_note'] ?? '').toString());
  final noteCtl =
      TextEditingController(text: (existing?['note'] ?? '').toString());
  var category = (existing?['category'] ?? 'wholesale').toString();
  if (!_categories.contains(category)) category = 'other';
  var rating = _SMath.clampRating(existing?['rating']);
  var reorder = existing?['reorder'] == true;

  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) {
      return StatefulBuilder(builder: (ctx, setSheet) {
        final scheme = Theme.of(ctx).colorScheme;
        return Padding(
          padding: EdgeInsets.only(
              left: Gap.lg,
              right: Gap.lg,
              top: Gap.lg,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + Gap.lg),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(existing == null ? tr.supAddSupplier : tr.supEditSupplier,
                  style: Theme.of(ctx)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: Gap.md),
              TextField(
                controller: nameCtl,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                    labelText: tr.supFieldName,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              DropdownButtonFormField<String>(
                initialValue: category,
                isExpanded: true,
                decoration: InputDecoration(
                    labelText: tr.supFieldCategory,
                    border: const OutlineInputBorder()),
                items: _categories
                    .map((c) => DropdownMenuItem(
                        value: c, child: Text(_catLabel(tr, c))))
                    .toList(),
                onChanged: (v) => setSheet(() => category = v ?? 'other'),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: productsCtl,
                minLines: 1,
                maxLines: 3,
                decoration: InputDecoration(
                    labelText: tr.supFieldProducts,
                    helperText: tr.supFieldProductsHelp,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: locationCtl,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                    labelText: tr.supFieldLocation,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: contactCtl,
                decoration: InputDecoration(
                    labelText: tr.supFieldContact,
                    helperText: tr.supFieldContactHelp,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: priceCtl,
                minLines: 1,
                maxLines: 2,
                decoration: InputDecoration(
                    labelText: tr.supFieldPriceNote,
                    prefixText: '৳ ',
                    helperText: tr.supFieldPriceNoteHelp,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: noteCtl,
                minLines: 1,
                maxLines: 2,
                decoration: InputDecoration(
                    labelText: tr.supFieldNote,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(tr.supFieldRating,
                    style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant)),
              ),
              Row(children: [
                for (var i = 1; i <= 5; i++)
                  IconButton(
                    tooltip: AppLocalizations.of(context).f2RateStars(i),
                    icon: Icon(
                        i <= rating ? Icons.star : Icons.star_border,
                        color: AssistoTokens.of(context).warning),
                    onPressed: () => setSheet(() {
                      rating = (rating == i) ? i - 1 : i; // tap same star clears
                    }),
                  ),
                const Spacer(),
                Text(rating == 0 ? tr.supUnrated : '$rating / 5',
                    style: TextStyle(color: scheme.onSurfaceVariant)),
              ]),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: reorder,
                title: Text(tr.supReorderToggle),
                subtitle: Text(tr.supReorderToggleSub,
                    style: AType.bodySmall),
                onChanged: (v) => setSheet(() => reorder = v),
              ),
              const SizedBox(height: Gap.md),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    final name = nameCtl.text.trim();
                    if (name.isEmpty) {
                      Navigator.pop(ctx);
                      return;
                    }
                    Navigator.pop(ctx, <String, dynamic>{
                      'name': name,
                      'category': category,
                      'products': productsCtl.text.trim(),
                      'location': locationCtl.text.trim(),
                      'contact': contactCtl.text.trim(),
                      'price_note': priceCtl.text.trim(),
                      'note': noteCtl.text.trim(),
                      'rating': rating,
                      'reorder': reorder,
                    });
                  },
                  child: Text(tr.save),
                ),
              ),
            ]),
          ),
        );
      });
    },
  );
}

Future<bool?> _confirm(BuildContext context, String title, String body) {
  final tr = AppLocalizations.of(context);
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false), child: Text(tr.cancel)),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true), child: Text(tr.delete)),
      ],
    ),
  );
}

// =============================================================================
// _SMath — VERBATIM mirror of backend/core/logic/supplier_market.py.
// Filter / compare / reorder over the user's OWN suppliers. Same inputs →
// same output. No scraping, no fabrication.
// =============================================================================

const List<String> _smCategories = _categories;
const int _maxRating = 5;

class _SSupplier {
  final Object? id;
  final String name;
  final String category;
  final List<String> products;
  final String productsDisplay;
  final String location;
  final String contact;
  final String priceNote;
  final int rating;
  final String note;
  final bool reorder;
  final Map<String, dynamic> raw;
  _SSupplier({
    required this.id,
    required this.name,
    required this.category,
    required this.products,
    required this.productsDisplay,
    required this.location,
    required this.contact,
    required this.priceNote,
    required this.rating,
    required this.note,
    required this.reorder,
    required this.raw,
  });
}

class _SResult {
  final List<_SSupplier> suppliers;
  final int matchCount;
  final int totalCount;
  final int reorderCount;
  final Map<String, int> byCategory;
  _SResult(this.suppliers, this.matchCount, this.totalCount, this.reorderCount,
      this.byCategory);
}

class _SCompare {
  final List<_SSupplier> suppliers;
  final Object? bestRatingId;
  final List<Object?> reorderIds;
  final bool enough;
  _SCompare(this.suppliers, this.bestRatingId, this.reorderIds, this.enough);
}

class _SMath {
  static String _clean(dynamic v) =>
      (v ?? '').toString().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).join(' ').trim();

  static String _lc(dynamic v) => _clean(v).toLowerCase();

  static String _category(dynamic v) {
    var c = _lc(v);
    if (c.isEmpty) c = 'other';
    c = c.replaceAll(' ', '_').replaceAll('-', '_');
    return _smCategories.contains(c) ? c : 'other';
  }

  static int clampRating(dynamic v) {
    if (v == null) return 0;
    final d = v is num ? v.toDouble() : double.tryParse(v.toString());
    if (d == null) return 0;
    final r = d.round();
    return r < 0 ? 0 : (r > _maxRating ? _maxRating : r);
  }

  static List<String> _products(dynamic v) {
    final raw = <String>[];
    if (v is List) {
      for (final e in v) {
        raw.add(e.toString());
      }
    } else if (v != null && v.toString().isNotEmpty) {
      raw.addAll(v.toString().split(RegExp(r'[,\n]+')));
    }
    final out = <String>[];
    final seen = <String>{};
    for (final p0 in raw) {
      final p = _clean(p0);
      if (p.isEmpty) continue;
      final k = p.toLowerCase();
      if (seen.contains(k)) continue;
      seen.add(k);
      out.add(p);
    }
    return out;
  }

  /// Turn a stored products value back into the "a, b" input the sheet edits.
  static String productsToInput(dynamic v) => _products(v).join(', ');

  static _SSupplier _normalize(Map<String, dynamic> row) {
    final products = _products(row['products']);
    return _SSupplier(
      id: row['id'],
      name: _clean(row['name']),
      category: _category(row['category']),
      products: products,
      productsDisplay: products.join(', '),
      location: _clean(row['location']),
      contact: _clean(row['contact']),
      priceNote: _clean(row['price_note']),
      rating: clampRating(row['rating']),
      note: _clean(row['note']),
      reorder: row['reorder'] == true,
      raw: row,
    );
  }

  static bool _matchesQuery(_SSupplier s, String q) {
    if (q.isEmpty) return true;
    final hay = [
      s.name,
      s.productsDisplay,
      s.location,
      s.priceNote,
      s.note,
    ].join(' ').toLowerCase();
    return hay.contains(q);
  }

  static _SResult search(
    List<Map<String, dynamic>> rows, {
    String query = '',
    String category = '',
    String location = '',
    int minRating = 0,
    bool reorderOnly = false,
  }) {
    final q = _lc(query);
    final cat = _clean(category).isEmpty ? '' : _category(category);
    final loc = _lc(location);
    final minr = clampRating(minRating);

    final normalized = <_SSupplier>[];
    for (final r in rows) {
      if (_clean(r['name']).isEmpty) continue;
      normalized.add(_normalize(r));
    }

    final byCat = <String, int>{};
    for (final s in normalized) {
      byCat[s.category] = (byCat[s.category] ?? 0) + 1;
    }

    final matched = <_SSupplier>[];
    for (final s in normalized) {
      if (cat.isNotEmpty && s.category != cat) continue;
      if (loc.isNotEmpty && !s.location.toLowerCase().contains(loc)) continue;
      if (s.rating < minr) continue;
      if (reorderOnly && !s.reorder) continue;
      if (!_matchesQuery(s, q)) continue;
      matched.add(s);
    }

    matched.sort((a, b) {
      final r = b.rating.compareTo(a.rating);
      if (r != 0) return r;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    final reorderCount = normalized.where((s) => s.reorder).length;
    return _SResult(matched, matched.length, normalized.length, reorderCount,
        byCat);
  }

  static _SCompare compare(List<Map<String, dynamic>> rows, List<Object> ids) {
    final index = <Object, _SSupplier>{};
    for (final r in rows) {
      final rid = r['id'];
      if (rid != null &&
          !index.containsKey(rid) &&
          _clean(r['name']).isNotEmpty) {
        index[rid as Object] = _normalize(r);
      }
    }
    final picked = <_SSupplier>[];
    for (final i in ids) {
      final s = index[i];
      if (s != null) picked.add(s);
    }
    Object? bestId;
    var best = -1;
    final reorderIds = <Object?>[];
    for (final s in picked) {
      if (s.rating > best) {
        best = s.rating;
        bestId = s.id;
      }
      if (s.reorder) reorderIds.add(s.id);
    }
    if (best <= 0) bestId = null;
    return _SCompare(picked, bestId, reorderIds, picked.length >= 2);
  }
}
