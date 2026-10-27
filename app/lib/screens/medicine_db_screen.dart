import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../ads/ad_banner_slot.dart' show AdBannerSlot;
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../widgets/health_api.dart';
import '../widgets/skeleton.dart';
import '../widgets/meddb_store.dart';
import '../widgets/meddb_drug_card.dart';

/// Medicine DATABASE (drug lookup) — ADVANCED (SPEC v2.1 §21). Distinct from the
/// medicine-reminder screen. Three rails via tabs:
///   - Search: brand OR generic -> full drug cards (name/generic/strength/form/
///     manufacturer/indicative price/uses/how-to-take/side-effects/precautions),
///     same-generic alternatives with PRICE-COMPARE + the mandatory switch-
///     warning, an honest source-noted interactions note, save/share/report.
///   - Saved: the user's favourited drugs (offline).
///   - Recent: recently-viewed drugs (offline).
/// Viewed drugs are cached on-device, so Saved/Recent and re-opening a drug work
/// with NO network. Section-21 states (empty/loading/error/offline) all drawn.
///
/// LICENSING (STRICT): data is DGDA-only / a licensed provider, OR a clearly
/// BADGED curated sample — we NEVER copy DIMS / MedEx. Every record and every
/// alternative carries the switch-warning; the source line is always shown; we
/// never invent prices or facts. "Report wrong info" routes to cross-checking.
class MedicineDbScreen extends StatefulWidget {
  const MedicineDbScreen({super.key});
  @override
  State<MedicineDbScreen> createState() => _MedicineDbScreenState();
}

class _MedicineDbScreenState extends State<MedicineDbScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _search = TextEditingController();

  List<Map<String, dynamic>> _results = [];
  Map<String, dynamic> _meta = {};
  bool _searched = false;
  bool _loading = false;
  bool _error = false;
  bool _offline = false;

  List<Map<String, dynamic>> _saved = [];
  List<Map<String, dynamic>> _recent = [];

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _refreshLocal();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _refreshLocal() async {
    final s = await MedDbStore.favourites();
    final r = await MedDbStore.recents();
    if (!mounted) return;
    setState(() {
      _saved = s;
      _recent = r;
    });
  }

  Future<void> _run() async {
    final q = _search.text.trim();
    if (q.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = false;
      _offline = false;
      _searched = true;
    });
    try {
      final r = await context.read<AppState>().api.medicineDbSearch(q);
      if (!mounted) return;
      final results =
          ((r['results'] ?? []) as List).cast<Map<String, dynamic>>();
      // offline-first: remember every drug the user surfaces so Saved/Recent
      // and re-opens work with no network.
      for (final rec in results) {
        await MedDbStore.addRecent(rec);
      }
      if (!mounted) return;
      setState(() {
        _results = results;
        _meta = (r['meta'] ?? {}) as Map<String, dynamic>;
      });
      await _refreshLocal();
    } catch (_) {
      if (!mounted) return;
      // fall back to on-device cache so the user isn't dead-ended offline.
      final hits = await _localSearch(q);
      if (!mounted) return;
      setState(() {
        _results = hits;
        _offline = true;
        _error = hits.isEmpty;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<List<Map<String, dynamic>>> _localSearch(String q) async {
    final ql = q.toLowerCase();
    final seen = <String>{};
    final out = <Map<String, dynamic>>[];
    for (final rec in [..._recent, ..._saved]) {
      final key = MedDbStore.keyOf(rec);
      if (seen.contains(key)) continue;
      final hay =
          '${rec['brand'] ?? ''} ${rec['generic'] ?? ''}'.toLowerCase();
      if (hay.contains(ql)) {
        seen.add(key);
        out.add(rec);
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      // banners-everywhere (owner 26 Oct): one bottom banner, Free only
      bottomNavigationBar: const AdBannerSlot(screen: 'medicine_db'),
      appBar: AppBar(
        title: Text(t.medicineDbTitle),
        bottom: TabBar(controller: _tabs, tabs: [
          Tab(text: t.medicineDbTabSearch),
          Tab(text: t.medicineDbTabSaved),
          Tab(text: t.medicineDbTabRecent),
        ]),
      ),
      body: TabBarView(controller: _tabs, children: [
        _buildSearch(t),
        _buildSavedOrRecent(t, _saved,
            emptyIcon: Icons.star_border_rounded,
            emptyTitle: t.medicineDbSavedEmptyTitle,
            emptyBody: t.medicineDbSavedEmptyBody),
        _buildSavedOrRecent(t, _recent,
            emptyIcon: Icons.history_rounded,
            emptyTitle: t.medicineDbRecentEmptyTitle,
            emptyBody: t.medicineDbRecentEmptyBody,
            onClear: _recent.isEmpty
                ? null
                : () async {
                    await MedDbStore.clearRecents();
                    await _refreshLocal();
                  }),
      ]),
    );
  }

  // ---- SEARCH tab ----
  Widget _buildSearch(AppLocalizations t) {
    final scheme = Theme.of(context).colorScheme;
    final isSample = _meta['is_sample'] == true;
    final sourceLabel = (_meta['source_label'] ?? '').toString();
    final sampleNotice = (_meta['sample_notice'] ?? '').toString();
    final switchWarning = (_meta['switch_warning'] ?? '').toString();

    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      TextField(
        controller: _search,
        decoration: InputDecoration(
          hintText: t.medicineDbSearchHint,
          prefixIcon: const Icon(Icons.search_rounded),
          suffixIcon: IconButton(
            tooltip: MaterialLocalizations.of(context).searchFieldLabel,
            icon: const Icon(Icons.arrow_forward_rounded),
            onPressed: _run,
          ),
        ),
        onSubmitted: (_) => _run(),
        textInputAction: TextInputAction.search,
      ),
      const SizedBox(height: Gap.md),

      if (_searched && _offline) _offlineBanner(t, scheme),

      // honest source line (always, once results exist)
      if (_searched && !_offline && sourceLabel.isNotEmpty)
        _noticeRow(Icons.verified_rounded, sourceLabel,
            AssistoTokens.of(context).info, scheme),

      // sample-data badge
      if (_searched && !_offline && isSample && sampleNotice.isNotEmpty)
        _noticeRow(Icons.science_rounded, sampleNotice,
            Brand.warnInk(context), scheme,
            bg: Brand.warning.withValues(alpha: 0.15)),

      // mandatory switch-warning (always, once results exist)
      if (_searched && switchWarning.isNotEmpty)
        _warningRow(switchWarning, scheme),

      if (_loading)
        Column(
            children: List.generate(
                3,
                (_) => const Padding(
                      padding: EdgeInsets.only(bottom: Gap.md),
                      child: _CardSkeleton(),
                    )))
      else if (_error)
        StateMessage(
          icon: Icons.cloud_off_rounded,
          tint: scheme.error,
          title: t.medicineDbLoadError,
          message: _offline ? t.medicineDbOfflineNoCache : null,
          action: OutlinedButton.icon(
            onPressed: _run,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(t.retry),
          ),
        )
      else if (!_searched)
        StateMessage(
          icon: Icons.medication_rounded,
          title: t.medicineDbIntroTitle,
          message: t.medicineDbIntroBody,
        )
      else if (_results.isEmpty)
        StateMessage(
          icon: Icons.inventory_2_rounded,
          tint: scheme.onSurfaceVariant,
          title: t.medicineDbNeedsDataTitle,
          message: t.medicineDbNeedsDataBody,
        )
      else
        for (final rec in _results) ...[
          MedDbDrugCard(
              key: ValueKey('r_${MedDbStore.keyOf(rec)}'),
              record: rec,
              offline: _offline,
              onFavouriteChanged: _refreshLocal),
          const SizedBox(height: Gap.md),
        ],
    ]);
  }

  // ---- SAVED / RECENT tabs (offline, on-device) ----
  Widget _buildSavedOrRecent(
    AppLocalizations t,
    List<Map<String, dynamic>> items, {
    required IconData emptyIcon,
    required String emptyTitle,
    required String emptyBody,
    Future<void> Function()? onClear,
  }) {
    if (items.isEmpty) {
      return StateMessage(
        icon: emptyIcon,
        tint: Theme.of(context).colorScheme.onSurfaceVariant,
        title: emptyTitle,
        message: emptyBody,
      );
    }
    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      if (onClear != null)
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: onClear,
            icon: const Icon(Icons.delete_outline_rounded, size: 18),
            label: Text(t.medicineDbClearRecent),
          ),
        ),
      for (final rec in items) ...[
        MedDbDrugCard(
            key: ValueKey('l_${MedDbStore.keyOf(rec)}'),
            record: rec,
            offline: true,
            onFavouriteChanged: _refreshLocal),
        const SizedBox(height: Gap.md),
      ],
    ]);
  }

  // ---- small shared bits ----
  Widget _offlineBanner(AppLocalizations t, ColorScheme scheme) => Container(
        padding: const EdgeInsets.all(Gap.md),
        margin: const EdgeInsets.only(bottom: Gap.md),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        child: Row(children: [
          Icon(Icons.cloud_off_rounded, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: Gap.sm),
          Expanded(
              child: Text(t.medicineDbOfflineBanner,
                  style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant))),
        ]),
      );

  Widget _noticeRow(IconData icon, String text, Color fg, ColorScheme scheme,
          {Color? bg}) =>
      Container(
        padding: const EdgeInsets.all(Gap.md),
        margin: const EdgeInsets.only(bottom: Gap.md),
        decoration: BoxDecoration(
          color: bg ?? scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        child: Row(children: [
          Icon(icon, size: 18, color: fg),
          const SizedBox(width: Gap.sm),
          Expanded(
              child:
                  Text(text, style: AType.bodySmall.copyWith(color: fg))),
        ]),
      );

  Widget _warningRow(String text, ColorScheme scheme) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.md),
        child: Row(children: [
          Icon(Icons.warning_amber_rounded, size: 16, color: scheme.error),
          const SizedBox(width: Gap.xs),
          Expanded(
              child: Text(text,
                  style: AType.bodySmall.copyWith(color: scheme.error, fontWeight: FontWeight.w600))),
        ]),
      );
}

/// Loading placeholder shaped like a drug card (safe inside a ListView).
class _CardSkeleton extends StatelessWidget {
  const _CardSkeleton();
  @override
  Widget build(BuildContext context) => const Card(
        child: Padding(
          padding: EdgeInsets.all(Gap.lg),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Skeleton(width: 180, height: 16),
            SizedBox(height: Gap.md),
            Skeleton(width: 240, height: 12),
            SizedBox(height: Gap.sm),
            Skeleton(width: 200, height: 12),
            SizedBox(height: Gap.md),
            Skeleton(width: double.infinity, height: 36, radius: 10),
          ]),
        ),
      );
}
