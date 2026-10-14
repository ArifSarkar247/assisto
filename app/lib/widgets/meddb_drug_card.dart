import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import 'meddb_store.dart';
import 'meddb_report_sheet.dart';

/// ADVANCED Medicine-DB drug card. Shows the FULL drug record —
/// brand / generic / strength / form / manufacturer / indicative price /
/// uses / how-to-take / side-effects / precautions — plus:
///   - same-generic alternatives with a PRICE-COMPARE (cheaper/dearer/same)
///     and the MANDATORY switch-warning on each,
///   - an honest, source-noted interactions note,
///   - save / favourite, share as a result card, and "report wrong info".
///
/// Pure presentational except for the on-device favourite toggle (MedDbStore).
/// Every record and every alternative carries the switch-warning. We never
/// invent data: we only render what the backend (DGDA-only / licensed, or the
/// clearly-badged curated sample) returns.
class MedDbDrugCard extends StatefulWidget {
  final Map<String, dynamic> record;

  /// true when rendered from the offline cache (no live source this session).
  final bool offline;

  /// Called after the favourite state flips, so parent lists can refresh.
  final VoidCallback? onFavouriteChanged;

  const MedDbDrugCard({
    super.key,
    required this.record,
    this.offline = false,
    this.onFavouriteChanged,
  });

  @override
  State<MedDbDrugCard> createState() => _MedDbDrugCardState();
}

class _MedDbDrugCardState extends State<MedDbDrugCard> {
  bool _fav = false;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _initFav();
  }

  Future<void> _initFav() async {
    final f = await MedDbStore.isFavourite(MedDbStore.keyOf(widget.record));
    if (mounted) setState(() {
      _fav = f;
      _ready = true;
    });
  }

  Future<void> _toggleFav() async {
    final now = await MedDbStore.toggleFavourite(widget.record);
    if (!mounted) return;
    setState(() => _fav = now);
    widget.onFavouriteChanged?.call();
    final t = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(now ? t.medicineDbSaved : t.medicineDbRemovedSaved),
        duration: const Duration(seconds: 1)));
  }

  String _shareText(AppLocalizations t) {
    final r = widget.record;
    final b = StringBuffer();
    b.writeln('${r['brand'] ?? ''}  ${r['strength'] ?? ''}'.trim());
    if ((r['generic'] ?? '').toString().isNotEmpty) {
      b.writeln('${t.medicineDbGeneric}: ${r['generic']}');
    }
    if ((r['manufacturer'] ?? '').toString().isNotEmpty) {
      b.writeln('${r['manufacturer']}');
    }
    if ((r['price_display'] ?? '').toString().isNotEmpty) {
      b.writeln('${r['price_display']}');
    }
    if ((r['uses'] ?? '').toString().isNotEmpty) {
      b.writeln('${t.medicineDbUses}: ${r['uses']}');
    }
    final w = (r['switch_warning'] ?? '').toString();
    if (w.isNotEmpty) b.writeln('\n$w');
    return b.toString().trim();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final r = widget.record;

    final brand = (r['brand'] ?? '').toString();
    final generic = (r['generic'] ?? '').toString();
    final strength = (r['strength'] ?? '').toString();
    final form = (r['form'] ?? '').toString();
    final manufacturer = (r['manufacturer'] ?? '').toString();
    final price = (r['price_display'] ?? '').toString();
    final num? priceVal = r['price'] is num ? r['price'] as num : null;
    final uses = (r['uses'] ?? '').toString();
    final howTo = (r['how_to_take'] ?? '').toString();
    final sideEffects = (r['side_effects'] ?? '').toString();
    final precautions = (r['precautions'] ?? '').toString();
    final switchWarning = (r['switch_warning'] ?? '').toString();
    final interactions = (r['interactions'] as Map?)?.cast<String, dynamic>();
    final alternatives =
        ((r['alternatives'] ?? const []) as List).cast<Map<String, dynamic>>();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // ---- header: brand + strength, price, star ----
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Text('$brand  $strength'.trim(),
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            if (price.isNotEmpty)
              Text(price,
                  style: TextStyle(fontSize: 12, color: scheme.secondary)),
            if (_ready)
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: _fav ? t.medicineDbRemoveSave : t.medicineDbSave,
                icon: Icon(_fav ? Icons.star : Icons.star_border,
                    color: _fav ? Brand.warning : scheme.onSurfaceVariant),
                onPressed: _toggleFav,
              ),
          ]),
          if (widget.offline) ...[
            const SizedBox(height: Gap.xs),
            Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.cloud_off, size: 13, color: scheme.onSurfaceVariant),
              const SizedBox(width: Gap.xs),
              Text(t.medicineDbOfflineCached,
                  style:
                      TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
            ]),
          ],
          const SizedBox(height: Gap.xs),

          // ---- generic / form / manufacturer chips ----
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            if (generic.isNotEmpty)
              _Chip(icon: Icons.science_outlined, text: generic),
            if (form.isNotEmpty)
              _Chip(icon: Icons.medication_outlined, text: form),
            if (manufacturer.isNotEmpty)
              _Chip(icon: Icons.factory_outlined, text: manufacturer),
          ]),

          // ---- labelled facts ----
          if (uses.isNotEmpty) ...[
            const SizedBox(height: Gap.md),
            _Labeled(label: t.medicineDbUses, value: uses),
          ],
          if (howTo.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            _Labeled(label: t.medicineDbHowToTake, value: howTo),
          ],
          if (sideEffects.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            _Labeled(label: t.medicineDbSideEffects, value: sideEffects),
          ],
          if (precautions.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            _Labeled(label: t.medicineDbPrecautions, value: precautions),
          ],

          // ---- interactions note (honest + source-noted) ----
          if (interactions != null &&
              (interactions['text'] ?? '').toString().isNotEmpty) ...[
            const SizedBox(height: Gap.md),
            Container(
              padding: const EdgeInsets.all(Gap.sm),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(Icons.info_outline,
                          size: 15, color: scheme.onSurfaceVariant),
                      const SizedBox(width: Gap.xs),
                      Text(t.medicineDbInteractions,
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: scheme.onSurfaceVariant)),
                    ]),
                    const SizedBox(height: 2),
                    Text(interactions['text'].toString(),
                        style:
                            const TextStyle(fontSize: 12.5, height: 1.4)),
                    if ((interactions['source_note'] ?? '')
                        .toString()
                        .isNotEmpty) ...[
                      const SizedBox(height: Gap.xs),
                      Text(interactions['source_note'].toString(),
                          style: TextStyle(
                              fontSize: 11,
                              fontStyle: FontStyle.italic,
                              color: scheme.onSurfaceVariant)),
                    ],
                  ]),
            ),
          ],

          // ---- switch-warning (ALWAYS, on every record) ----
          if (switchWarning.isNotEmpty) ...[
            const SizedBox(height: Gap.md),
            Container(
              padding: const EdgeInsets.all(Gap.sm),
              decoration: BoxDecoration(
                color: scheme.errorContainer,
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Row(children: [
                Icon(Icons.warning_amber_rounded,
                    size: 16, color: scheme.onErrorContainer),
                const SizedBox(width: Gap.xs),
                Expanded(
                    child: Text(switchWarning,
                        style: TextStyle(
                            fontSize: 11.5, color: scheme.onErrorContainer))),
              ]),
            ),
          ],

          // ---- alternatives (same generic) with price compare ----
          if (alternatives.isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            Theme(
              data: Theme.of(context)
                  .copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                title: Text(
                    t.medicineDbAlternativesTitle(alternatives.length),
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
                children: [
                  for (final a in alternatives)
                    _AltRow(alt: a, basePrice: priceVal),
                  Padding(
                    padding:
                        const EdgeInsets.only(top: Gap.xs, bottom: Gap.sm),
                    child: Row(children: [
                      Icon(Icons.warning_amber_rounded,
                          size: 14, color: scheme.error),
                      const SizedBox(width: Gap.xs),
                      Expanded(
                        child: Text(t.medicineDbAlternativesNote,
                            style: TextStyle(fontSize: 11, color: scheme.error)),
                      ),
                    ]),
                  ),
                ],
              ),
            ),
          ],

          // ---- actions: share + report ----
          const Divider(height: Gap.lg),
          Row(children: [
            TextButton.icon(
              onPressed: () => Share.share(_shareText(t)),
              icon: const Icon(Icons.ios_share, size: 18),
              label: Text(t.medicineDbShare),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: () => showMedDbReportSheet(context, brand),
              icon: const Icon(Icons.flag_outlined, size: 18),
              label: Text(t.medicineDbReportTitle),
            ),
          ]),
        ]),
      ),
    );
  }
}

/// One alternative row with price-compare vs the base drug.
class _AltRow extends StatelessWidget {
  final Map<String, dynamic> alt;
  final num? basePrice;
  const _AltRow({required this.alt, this.basePrice});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final altPrice = alt['price'] is num ? alt['price'] as num : null;

    Widget? badge;
    if (basePrice != null && altPrice != null) {
      if (altPrice < basePrice!) {
        badge = _PriceBadge(
            text: t.medicineDbCheaper,
            fg: const Color(0xFF0B6B3A),
            bg: Brand.success.withValues(alpha: 0.16));
      } else if (altPrice > basePrice!) {
        badge = _PriceBadge(
            text: t.medicineDbDearer,
            fg: const Color(0xFF8A2A36),
            bg: Brand.danger.withValues(alpha: 0.16));
      } else {
        badge = _PriceBadge(
            text: t.medicineDbSamePrice,
            fg: scheme.onSurfaceVariant,
            bg: scheme.surfaceContainerHighest);
      }
    }

    final sub = <String>[
      if ((alt['manufacturer'] ?? '').toString().isNotEmpty)
        alt['manufacturer'].toString(),
      if ((alt['price_display'] ?? '').toString().isNotEmpty)
        alt['price_display'].toString(),
    ].join('  ·  ');

    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.swap_horiz, size: 18),
      title: Row(children: [
        Flexible(
            child: Text('${alt['brand'] ?? ''}  ${alt['strength'] ?? ''}'.trim())),
        if (badge != null) ...[const SizedBox(width: Gap.sm), badge],
      ]),
      subtitle: sub.isEmpty ? null : Text(sub, style: const TextStyle(fontSize: 12)),
    );
  }
}

class _PriceBadge extends StatelessWidget {
  final String text;
  final Color fg, bg;
  const _PriceBadge({required this.text, required this.fg, required this.bg});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 1),
        decoration:
            BoxDecoration(color: bg, borderRadius: BorderRadius.circular(Radii.pill)),
        child: Text(text,
            style: TextStyle(
                fontSize: 10.5, fontWeight: FontWeight.w700, color: fg)),
      );
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Chip({required this.icon, required this.text});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 13, color: scheme.onSurfaceVariant),
        const SizedBox(width: Gap.xs),
        Text(text, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
      ]),
    );
  }
}

class _Labeled extends StatelessWidget {
  final String label, value;
  const _Labeled({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label,
          style: TextStyle(
              fontSize: 12, fontWeight: FontWeight.w700, color: scheme.primary)),
      const SizedBox(height: 2),
      Text(value, style: const TextStyle(height: 1.4)),
    ]);
  }
}
