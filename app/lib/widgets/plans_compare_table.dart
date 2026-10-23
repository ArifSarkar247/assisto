import 'package:flutter/material.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';

/// Per-feature "what you get" comparison matrix for the Plans screen
/// (Section 21: clear plan comparison). It is derived ENTIRELY from the
/// backend plan catalogue (`plansPublic()` rows) plus the fixed plan-gate
/// truths from spec Section 25 — so it can never drift from what the server
/// actually sells, and it carries NO prices (those stay owner-set in plans.py
/// and are shown only on the plan cards).
///
/// Each cell is one of:
///   - a check (included)
///   - a dash  (not included)
///   - a short localised note (e.g. "90 / mo" from the live pool, "Up to 5")
///
/// Gate truths encoded here (verified against plans.py + Section 25):
///   - text + voice calls are FREE on EVERY plan
///   - video calls are PREMIUM (caller-pays) — free plan excluded
///   - Safe Journey + SOS (and scam / medicine) are FREE on EVERY plan
class PlansCompareTable extends StatelessWidget {
  /// The public plan rows as returned by `api.plansPublic()`.
  final List<Map<String, dynamic>> plans;

  /// The user's current effective plan id, to highlight that column.
  final String current;
  const PlansCompareTable({super.key, required this.plans, required this.current});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;

    // Columns: keep the catalogue order but drop the yearly duplicate of
    // Premium so the table stays scannable (annual vs monthly is explained
    // separately). Founder is already excluded by the backend.
    final cols = plans.where((p) => (p['id'] ?? '') != 'annual').toList();
    if (cols.isEmpty) return const SizedBox.shrink();
    // dl1: "Free calls (testing)" is ON server-side (every row carries it).
    final callsFree = plans.any((p) => p['calls_free'] == true);

    Map<String, dynamic> byId(String id) =>
        plans.firstWhere((p) => (p['id'] ?? '') == id, orElse: () => const {});

    // Owner decision: NOTHING is unlimited in any plan — paid plans carry a
    // monthly credit pool. Paid-only perks key off "not the free plan".
    bool paid(Map<String, dynamic> p) => (p['id'] ?? '') != 'free';
    int family(Map<String, dynamic> p) =>
        (p['family'] is num) ? (p['family'] as num).toInt() : 0;
    bool noAds(Map<String, dynamic> p) => p['ads'] != true;
    int credits(Map<String, dynamic> p) =>
        (p['credits'] is num) ? (p['credits'] as num).toInt() : 0;
    // Bangla UI shows Bangla digits (U+09E6..U+09EF).
    final bnUi = t.localeName.startsWith('bn');
    String digits(int n) => bnUi
        ? String.fromCharCodes(
            '$n'.codeUnits.map((c) => c >= 48 && c <= 57 ? 0x09E6 + c - 48 : c))
        : '$n';
    // AI allowance from the LIVE config pool (never a hardcoded "15 / mo").
    String aiCell(Map<String, dynamic> p) => credits(p) > 0
        ? t.a1CmpCreditsPerMonth(digits(credits(p)))
        : t.a1CmpPacksOrAds;

    // A cell value is bool (check/dash) or a String note.
    final rows = <_Group>[
      _Group(t.plansCmpAi, [
        _Row(t.plansCmpAiScans,
            {for (final p in cols) p['id']: aiCell(p)}),
        _Row(t.plansCmpNoAds, {for (final p in cols) p['id']: noAds(p)}),
        _Row(t.plansCmpBriefings,
            {for (final p in cols) p['id']: paid(p)}),
      ]),
      _Group(t.plansCmpSafety, [
        _Row(t.plansCmpSos, {for (final p in cols) p['id']: true}),
        _Row(t.plansCmpJourney, {for (final p in cols) p['id']: true}),
        _Row(t.plansCmpScam, {for (final p in cols) p['id']: true}),
        _Row(t.plansCmpMedicine, {for (final p in cols) p['id']: true}),
      ]),
      _Group(t.plansCmpCalls, [
        _Row(t.plansCmpTextVoice, {for (final p in cols) p['id']: true}),
        // Video is premium (caller-pays): everyone except the free plan —
        // unless the server says calls are free while testing (dl1).
        _Row(t.plansCmpVideo, {
          for (final p in cols)
            p['id']: callsFree
                ? t.dlCallsFreeTesting
                : (p['id'] ?? '') != 'free'
        }),
      ]),
      _Group(t.plansCmpFamily, [
        _Row(t.plansCmpMembers,
            {for (final p in cols) p['id']: family(p) > 0 ? t.plansCmpUpTo(digits(family(p))) : false}),
        _Row(t.plansCmpCaregiver,
            {for (final p in cols) p['id']: family(p) > 0}),
      ]),
      if (byId('business').isNotEmpty)
        _Group(t.plansCmpBusiness, [
          _Row(t.plansCmpBusinessMode,
              {for (final p in cols) p['id']: (p['id'] ?? '') == 'business'}),
        ]),
      _Group(t.plansCmpSupport, [
        _Row(t.plansCmpPriority,
            {for (final p in cols) p['id']: paid(p)}),
      ]),
    ];

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _headerRow(context, cols),
          for (final g in rows) ...[
            _groupHeader(context, g.title, cols.length),
            for (final r in g.rows) _featureRow(context, cols, r),
          ],
        ]),
      ),
    );
  }

  static const double _labelW = 160;
  static const double _colW = 92;

  Widget _headerRow(BuildContext context, List<Map<String, dynamic>> cols) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      child: Row(children: [
        const SizedBox(width: _labelW),
        for (final p in cols)
          Container(
            width: _colW,
            padding: const EdgeInsets.symmetric(vertical: Gap.sm, horizontal: 4),
            alignment: Alignment.center,
            decoration: (p['id'] == current)
                ? BoxDecoration(
                    border: Border(
                        bottom: BorderSide(color: scheme.primary, width: 2)))
                : null,
            child: Text(
              (p['name'] ?? p['id'] ?? '').toString(),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: p['id'] == current ? scheme.primary : scheme.onSurface,
              ),
            ),
          ),
      ]),
    );
  }

  Widget _groupHeader(BuildContext context, String title, int nCols) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      // finite: this sits inside a HORIZONTAL scroll view, where
      // double.infinity forces an infinite width (layout assertion; the
      // table rendered blank in release).
      width: _labelW + _colW * nCols,
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, 2),
      color: scheme.surfaceContainerHigh.withValues(alpha: 0.4),
      child: Text(title,
          style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.3,
              color: scheme.onSurfaceVariant)),
    );
  }

  Widget _featureRow(
      BuildContext context, List<Map<String, dynamic>> cols, _Row r) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
          border: Border(
              top: BorderSide(color: scheme.outlineVariant, width: 0.5))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        SizedBox(
          width: _labelW,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.sm, Gap.sm),
            child: Text(r.label,
                style: const TextStyle(fontSize: 12, height: 1.3)),
          ),
        ),
        for (final p in cols)
          SizedBox(
            width: _colW,
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(vertical: Gap.sm, horizontal: 4),
              color: p['id'] == current
                  ? scheme.primary.withValues(alpha: 0.06)
                  : null,
              child: _cell(context, r.cells[p['id']]),
            ),
          ),
      ]),
    );
  }

  Widget _cell(BuildContext context, dynamic v) {
    final scheme = Theme.of(context).colorScheme;
    if (v is String) {
      return Text(v,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600));
    }
    if (v == true) {
      return Icon(Icons.check_circle, size: 18, color: Brand.success);
    }
    // not included — a muted dash, with a screen-reader label.
    return Semantics(
      label: AppLocalizations.of(context).plansCmpNotIncluded,
      child: Icon(Icons.remove, size: 16, color: scheme.onSurfaceVariant),
    );
  }
}

class _Group {
  final String title;
  final List<_Row> rows;
  _Group(this.title, this.rows);
}

class _Row {
  final String label;
  final Map<dynamic, dynamic> cells; // plan-id -> bool | String
  _Row(this.label, this.cells);
}
