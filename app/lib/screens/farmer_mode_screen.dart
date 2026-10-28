import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/farmer_engine.dart';
import '../widgets/skeleton.dart';
import 'package:assisto/widgets/app_sheet.dart';
import '../services/error_kind.dart' show honestFailText; // qa2

/// FARMER / VILLAGE MODE — ADVANCED (#199, SPEC v2.1 §20).
///
/// A simple, large-touch mode for rural users, benchmarked against the
/// large-touch / high-contrast patterns of [ElderlyHomeScreen] (big glyphs,
/// generous >= 56dp targets, few choices, honest states). Three tabs:
///
///   • LEDGER — the farmer's crops as rows (planting / harvest dates, input
///     cost ৳, sale income ৳). We compute profit, margin and a lifecycle
///     status (planned / growing / harvested / sold) and a farm-wide summary.
///     We NEVER invent a price — with no income the row honestly reads a loss
///     equal to cost.
///   • CALENDAR — a FIXED Bangladeshi cropping-season almanac (Rabi /
///     Kharif-1 / Kharif-2): which crops are typically sown and harvested in
///     each season, with the current season flagged from the device date.
///     This is a reading almanac, NOT live weather or agronomy advice.
///   • LIVESTOCK — animal head counts and a vaccination-DUE check (due / soon /
///     ok / unknown) from the last-vaccination date. The reminder itself is a
///     SEAM: the engine says a shot is due; delivery (local notification now,
///     SMS/IVR when an owner key exists) is documented, not faked.
///
/// All math mirrors backend/core/logic/farmer_mode.py VERBATIM via
/// [FarmerEngine], so results are identical online or offline. ZERO Bangla
/// literals — every string is an AppLocalizations getter; ৳ is the currency
/// sign (gate-exempt).
///
/// Persistence (generic REST collections, no api.dart edit):
///   listItems('farmer/records')   → [{id, name, crop, planted, harvest,
///                                      cost, income, notes}]
///   listItems('farmer/livestock') → [{id, animal, count, last_vaccinated,
///                                      notes}]
///   create/update/deleteItem on the same paths; each row round-trips as
///   {id, ...data} through one flexible per-user JSON collection.
class FarmerModeScreen extends StatefulWidget {
  const FarmerModeScreen({super.key});

  @override
  State<FarmerModeScreen> createState() => _FarmerModeScreenState();
}

const String _recordsPath = 'farmer/records';
const String _livestockPath = 'farmer/livestock';

// Large-touch sizing shared across the screen (elderly-mode benchmark).
// Snapped to the type scale (f4): body 20 / title 22 / big number 28.
const _body = AType.titleLarge;
const _title = AType.headlineSmall;
const _bigNumber = AType.headlineLarge;

class _FarmerModeScreenState extends State<FarmerModeScreen> {
  List<Map<String, dynamic>> _records = const [];
  List<Map<String, dynamic>> _livestock = const [];
  bool _loading = true;
  bool _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

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
      final r = await api.listItems(_recordsPath);
      final l = await api.listItems(_livestockPath);
      _records = r;
      _livestock = l;
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  AppLocalizations get _t => AppLocalizations.of(context);

  void _toast(String m) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(m, style: _body)));

  // locale digits without a Bangla literal in source (elderly-mode pattern).
  String _digits(Object n) {
    final latin = n.toString();
    if (!_t.localeName.startsWith('bn')) return latin;
    const bnZero = 0x09E6;
    final b = StringBuffer();
    for (final ch in latin.runes) {
      b.writeCharCode(ch >= 0x30 && ch <= 0x39 ? bnZero + (ch - 0x30) : ch);
    }
    return b.toString();
  }

  String _money(num v) => '৳${_digits(v)}';

  @override
  Widget build(BuildContext context) {
    final t = _t;
    if (_loading) {
      return Scaffold(
        appBar: AppBar(
            toolbarHeight: 68,
            title: Text(t.farmerTitle,
                style: _title.copyWith(fontWeight: FontWeight.bold))),
        body: const SkeletonList(count: 5),
      );
    }
    if (_error) {
      return Scaffold(
        appBar: AppBar(
            toolbarHeight: 68,
            title: Text(t.farmerTitle,
                style: _title.copyWith(fontWeight: FontWeight.bold))),
        body: StateMessage(
          icon: Icons.cloud_off_rounded,
          tint: Brand.danger,
          title: t.loadFailed,
          message: honestFailText(t, _failCause, otherwise: t.farmerLoadError),
          action: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: FilledButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded, size: 24),
                label: Text(t.retry, style: _body)),
          ),
        ),
      );
    }
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          toolbarHeight: 68,
          title: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(t.farmerTitle,
                maxLines: 1,
                style: _title.copyWith(fontWeight: FontWeight.bold)),
          ),
          bottom: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelStyle: AType.titleMedium.copyWith(fontWeight: FontWeight.w700),
            tabs: [
              Tab(icon: const Icon(Icons.agriculture_rounded, size: 26), text: t.farmerTabLedger),
              Tab(icon: const Icon(Icons.calendar_month_rounded, size: 26), text: t.farmerTabCalendar),
              Tab(icon: const Icon(Icons.pets_rounded, size: 26), text: t.farmerTabLivestock),
            ],
          ),
        ),
        body: TabBarView(children: [
          _LedgerTab(
            records: _records,
            money: _money,
            digits: _digits,
            onAdd: () => _editRecord(),
            onEdit: _editRecord,
            onRefresh: _load,
          ),
          _CalendarTab(digits: _digits),
          _LivestockTab(
            livestock: _livestock,
            digits: _digits,
            onAdd: () => _editLivestock(),
            onEdit: _editLivestock,
            onRefresh: _load,
          ),
        ]),
      ),
    );
  }

  // ---- record CRUD --------------------------------------------------------

  Future<void> _editRecord([Map<String, dynamic>? existing]) async {
    final t = _t;
    final api = context.read<AppState>().api;
    final result = await showAppSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _RecordForm(existing: existing),
    );
    if (result == null || !mounted) return;
    if (result['__delete__'] == true) {
      await _deleteRecord(existing);
      return;
    }
    try {
      if (existing != null && existing['id'] is int) {
        await api.updateItem(_recordsPath, existing['id'] as int, result);
      } else {
        await api.createItem(_recordsPath, result);
      }
      await _load();
      if (mounted) _toast(t.farmerSaved);
    } catch (_) {
      if (mounted) _toast(t.saveFailed);
    }
  }

  Future<void> _deleteRecord(Map<String, dynamic>? existing) async {
    final t = _t;
    if (existing == null || existing['id'] is! int) return;
    final ok = await _confirmDelete(t.farmerDeleteRecordTitle, t.farmerDeleteRecordBody);
    if (ok != true || !mounted) return;
    try {
      await context.read<AppState>().api.deleteItem(_recordsPath, existing['id'] as int);
      await _load();
      if (mounted) _toast(t.farmerDeleted);
    } catch (_) {
      if (mounted) _toast(t.saveFailed);
    }
  }

  // ---- livestock CRUD -----------------------------------------------------

  Future<void> _editLivestock([Map<String, dynamic>? existing]) async {
    final t = _t;
    final api = context.read<AppState>().api;
    final result = await showAppSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _LivestockForm(existing: existing),
    );
    if (result == null || !mounted) return;
    if (result['__delete__'] == true) {
      if (existing != null && existing['id'] is int) {
        final ok = await _confirmDelete(
            t.farmerDeleteAnimalTitle, t.farmerDeleteAnimalBody);
        if (ok != true || !mounted) return;
        try {
          await api.deleteItem(_livestockPath, existing['id'] as int);
          await _load();
          if (mounted) _toast(t.farmerDeleted);
        } catch (_) {
          if (mounted) _toast(t.saveFailed);
        }
      }
      return;
    }
    try {
      if (existing != null && existing['id'] is int) {
        await api.updateItem(_livestockPath, existing['id'] as int, result);
      } else {
        await api.createItem(_livestockPath, result);
      }
      await _load();
      if (mounted) _toast(t.farmerSaved);
    } catch (_) {
      if (mounted) _toast(t.saveFailed);
    }
  }

  Future<bool?> _confirmDelete(String title, String body) => showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          scrollable: true, // insets: 200% text / keyboard
          icon: const Icon(Icons.delete_outline_rounded, color: Brand.danger, size: 30),
          title: Text(title, style: _title),
          content: Text(body, style: _body),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(_t.cancel, style: _body)),
            FilledButton(
              style: Brand.dangerButton(),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(_t.delete, style: _body),
            ),
          ],
        ),
      );
}

// =========================================================================== //
// token → localised label helpers (no Bangla literals; switches over tokens)
// =========================================================================== //

String farmerCropLabel(AppLocalizations t, String key) {
  switch (key) {
    case 'boro_rice':
      return t.farmerCropBoroRice;
    case 'aus_rice':
      return t.farmerCropAusRice;
    case 'aman_rice':
      return t.farmerCropAmanRice;
    case 'wheat':
      return t.farmerCropWheat;
    case 'potato':
      return t.farmerCropPotato;
    case 'mustard':
      return t.farmerCropMustard;
    case 'lentil':
      return t.farmerCropLentil;
    case 'onion':
      return t.farmerCropOnion;
    case 'garlic':
      return t.farmerCropGarlic;
    case 'maize':
      return t.farmerCropMaize;
    case 'tomato':
      return t.farmerCropTomato;
    case 'cabbage':
      return t.farmerCropCabbage;
    case 'jute':
      return t.farmerCropJute;
    case 'chilli':
      return t.farmerCropChilli;
    case 'aubergine':
      return t.farmerCropAubergine;
    case 'cucumber':
      return t.farmerCropCucumber;
    case 'bitter_gourd':
      return t.farmerCropBitterGourd;
    case 'okra':
      return t.farmerCropOkra;
    case 'pumpkin':
      return t.farmerCropPumpkin;
    case 'spinach':
      return t.farmerCropSpinach;
    case 'radish':
      return t.farmerCropRadish;
    case 'cauliflower':
      return t.farmerCropCauliflower;
    case 'bean':
      return t.farmerCropBean;
    default:
      return key;
  }
}

String farmerSeasonLabel(AppLocalizations t, String code) {
  switch (code) {
    case 'rabi':
      return t.farmerSeasonRabi;
    case 'kharif1':
      return t.farmerSeasonKharif1;
    case 'kharif2':
      return t.farmerSeasonKharif2;
    default:
      return code;
  }
}

String farmerAnimalLabel(AppLocalizations t, String key) {
  switch (key) {
    case 'cow':
      return t.farmerAnimalCow;
    case 'goat':
      return t.farmerAnimalGoat;
    case 'sheep':
      return t.farmerAnimalSheep;
    case 'buffalo':
      return t.farmerAnimalBuffalo;
    case 'chicken':
      return t.farmerAnimalChicken;
    case 'duck':
      return t.farmerAnimalDuck;
    case 'other':
      return t.farmerAnimalOther;
    default:
      return key;
  }
}

String farmerStatusLabel(AppLocalizations t, String status) {
  switch (status) {
    case kStatusPlanned:
      return t.farmerStatusPlanned;
    case kStatusGrowing:
      return t.farmerStatusGrowing;
    case kStatusHarvested:
      return t.farmerStatusHarvested;
    case kStatusSold:
      return t.farmerStatusSold;
    default:
      return status;
  }
}

/// Status chip fill + ink from the theme (AA in light and dark).
(Color, Color) _statusColors(BuildContext context, String status) {
  final s = Theme.of(context).colorScheme;
  final k = AssistoTokens.of(context);
  switch (status) {
    case kStatusSold:
      return (k.successContainer, k.onSuccessContainer);
    case kStatusHarvested:
      return (s.tertiaryContainer, s.onTertiaryContainer);
    case kStatusGrowing:
      return (k.infoContainer, k.onInfoContainer);
    default:
      return (s.surfaceContainerHighest, s.onSurfaceVariant);
  }
}

String _monthName(AppLocalizations t, int m) {
  switch (m) {
    case 1:
      return t.monthJan;
    case 2:
      return t.monthFeb;
    case 3:
      return t.monthMar;
    case 4:
      return t.monthApr;
    case 5:
      return t.monthMay;
    case 6:
      return t.monthJun;
    case 7:
      return t.monthJul;
    case 8:
      return t.monthAug;
    case 9:
      return t.monthSep;
    case 10:
      return t.monthOct;
    case 11:
      return t.monthNov;
    default:
      return t.monthDec;
  }
}

String _monthRange(AppLocalizations t, List<int> months) {
  if (months.isEmpty) return '';
  return '${_monthName(t, months.first)} – ${_monthName(t, months.last)}';
}

// =========================================================================== //
// LEDGER TAB
// =========================================================================== //

class _LedgerTab extends StatelessWidget {
  final List<Map<String, dynamic>> records;
  final String Function(num) money;
  final String Function(Object) digits;
  final VoidCallback onAdd;
  final void Function(Map<String, dynamic>) onEdit;
  final Future<void> Function() onRefresh;
  const _LedgerTab({
    required this.records,
    required this.money,
    required this.digits,
    required this.onAdd,
    required this.onEdit,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (records.isEmpty) {
      return _WelcomeState(
        icon: Icons.agriculture_rounded,
        title: t.farmerLedgerWelcomeTitle,
        body: t.farmerLedgerWelcomeBody,
        cta: t.farmerAddRecord,
        onCta: onAdd,
      );
    }
    final now = DateTime.now();
    final summary = FarmerEngine.ledgerSummary(records, now: now);
    return Scaffold(
      floatingActionButton: _BigFab(label: t.farmerAddRecord, icon: Icons.add_rounded, onTap: onAdd),
      body: RefreshIndicator(
        onRefresh: onRefresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 100),
          children: [
            _LedgerSummaryCard(summary: summary, money: money, digits: digits),
            const SizedBox(height: Gap.lg),
            for (final r in records) ...[
              _RecordCard(record: r, money: money, now: now, onTap: () => onEdit(r)),
              const SizedBox(height: Gap.md),
            ],
          ],
        ),
      ),
    );
  }
}

class _LedgerSummaryCard extends StatelessWidget {
  final LedgerSummary summary;
  final String Function(num) money;
  final String Function(Object) digits;
  const _LedgerSummaryCard(
      {required this.summary, required this.money, required this.digits});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final net = summary.netProfit;
    final netColor = net > 0
        ? AssistoTokens.of(context).success
        : (net < 0 ? scheme.error : scheme.onSurface);
    return Card(
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.farmerSummaryTitle,
                style: _title.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 14),
            Row(
              children: [
                _stat(context, money(summary.totalIncome), t.farmerIncome, AssistoTokens.of(context).success),
                _stat(context, money(summary.totalCost), t.farmerCost, scheme.error),
              ],
            ),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: netColor.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: netColor.withValues(alpha: 0.5), width: 2),
              ),
              child: Column(
                children: [
                  Text(t.farmerNetProfit, style: _body),
                  const SizedBox(height: Gap.xs),
                  Text(money(net),
                      style: _bigNumber.copyWith(fontWeight: FontWeight.bold,
                          color: netColor, fontFeatures: AFonts.tabular)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(BuildContext context, String value, String label, Color c) => Expanded(
        child: Column(
          children: [
            Text(value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _title.copyWith(
                    fontWeight: FontWeight.bold, color: c, fontFeatures: AFonts.tabular)),
            const SizedBox(height: Gap.xxs),
            Text(label, style: AType.bodyLarge),
          ],
        ),
      );
}

class _RecordCard extends StatelessWidget {
  final Map<String, dynamic> record;
  final String Function(num) money;
  final DateTime now;
  final VoidCallback onTap;
  const _RecordCard(
      {required this.record, required this.money, required this.now, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final status = FarmerEngine.recordStatus(record, now: now);
    final profit = FarmerEngine.recordProfit(record);
    final name = (record['name'] ?? '').toString().trim();
    final cropKey = (record['crop'] ?? '').toString().trim();
    final title = name.isNotEmpty
        ? name
        : (cropKey.isNotEmpty ? farmerCropLabel(t, cropKey) : t.farmerUntitledRecord);
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: _title.copyWith(fontWeight: FontWeight.w700)),
                  ),
                  _StatusChip(status: status),
                ],
              ),
              if (cropKey.isNotEmpty && name.isNotEmpty) ...[
                const SizedBox(height: Gap.xs),
                Text(farmerCropLabel(t, cropKey),
                    style: AType.bodyLarge.copyWith(color: scheme.onSurfaceVariant)),
              ],
              const SizedBox(height: Gap.md),
              Row(
                children: [
                  Expanded(
                      child: _kv(t.farmerCost, money(profit.cost),
                          scheme.error)),
                  Expanded(
                      child: _kv(t.farmerIncome, money(profit.income),
                          AssistoTokens.of(context).success)),
                ],
              ),
              const SizedBox(height: Gap.sm),
              Row(
                children: [
                  Icon(profit.profit >= 0 ? Icons.trending_up_rounded : Icons.trending_down_rounded,
                      size: 22,
                      color: profit.profit >= 0 ? AssistoTokens.of(context).success : scheme.error),
                  const SizedBox(width: 6),
                  Text('${t.farmerProfit}: ${money(profit.profit)}',
                      style: _body.copyWith(fontWeight: FontWeight.w700,
                          color: profit.profit >= 0 ? AssistoTokens.of(context).success : scheme.error)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _kv(String k, String v, Color c) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(k, style: AType.bodyMedium),
          Text(v,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _body.copyWith(
                  fontWeight: FontWeight.w700, color: c, fontFeatures: AFonts.tabular)),
        ],
      );
}

class _StatusChip extends StatelessWidget {
  final String status;
  const _StatusChip({required this.status});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final (bg, fg) = _statusColors(context, status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(farmerStatusLabel(t, status),
          style: AType.titleSmall.copyWith(color: fg, fontWeight: FontWeight.w700)),
    );
  }
}

// =========================================================================== //
// CALENDAR TAB
// =========================================================================== //

class _CalendarTab extends StatelessWidget {
  final String Function(Object) digits;
  const _CalendarTab({required this.digits});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final now = DateTime.now();
    final seasons = FarmerEngine.calendar(now);
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.xl),
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Brand.blue.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Brand.blue.withValues(alpha: 0.4), width: 2),
          ),
          child: Row(
            children: [
              const Icon(Icons.info_outline_rounded, size: 26, color: Brand.blue),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Text(t.farmerCalendarNote,
                    style: AType.bodyLarge.copyWith(height: 1.3)),
              ),
            ],
          ),
        ),
        const SizedBox(height: Gap.lg),
        for (final s in seasons) ...[
          _SeasonCard(season: s),
          const SizedBox(height: 14),
        ],
      ],
    );
  }
}

class _SeasonCard extends StatelessWidget {
  final SeasonView season;
  const _SeasonCard({required this.season});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: season.current
          ? AssistoTokens.of(context).success.withValues(alpha: 0.10)
          : scheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: season.current
            ? BorderSide(color: AssistoTokens.of(context).success, width: 2)
            : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(farmerSeasonLabel(t, season.season),
                      style: _title.copyWith(fontWeight: FontWeight.bold)),
                ),
                if (season.current)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: 6),
                    decoration: BoxDecoration(
                      color: Brand.successFill,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(t.farmerSeasonCurrent,
                        style: AType.titleSmall.copyWith(color: Colors.white, fontWeight: FontWeight.w700)),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            _line(context, Icons.grass_rounded, t.farmerSowWindow, _monthRange(t, season.sowMonths)),
            const SizedBox(height: Gap.xs),
            _line(context, Icons.agriculture_rounded, t.farmerHarvestWindow,
                _monthRange(t, season.harvestMonths)),
            const SizedBox(height: Gap.md),
            Text(t.farmerCommonCrops,
                style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: Gap.sm),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in season.crops)
                  Chip(
                    label: Text(farmerCropLabel(t, c), style: AType.bodyLarge),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: Gap.xxs),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _line(BuildContext context, IconData icon, String label, String value) => Row(
        children: [
          Icon(icon, size: 22, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text('$label: $value', style: _body),
          ),
        ],
      );
}

// =========================================================================== //
// LIVESTOCK TAB
// =========================================================================== //

class _LivestockTab extends StatelessWidget {
  final List<Map<String, dynamic>> livestock;
  final String Function(Object) digits;
  final VoidCallback onAdd;
  final void Function(Map<String, dynamic>) onEdit;
  final Future<void> Function() onRefresh;
  const _LivestockTab({
    required this.livestock,
    required this.digits,
    required this.onAdd,
    required this.onEdit,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (livestock.isEmpty) {
      return _WelcomeState(
        icon: Icons.pets_rounded,
        title: t.farmerLivestockWelcomeTitle,
        body: t.farmerLivestockWelcomeBody,
        cta: t.farmerAddAnimal,
        onCta: onAdd,
      );
    }
    final now = DateTime.now();
    final summary = FarmerEngine.livestockSummary(livestock, now: now);
    return Scaffold(
      floatingActionButton: _BigFab(label: t.farmerAddAnimal, icon: Icons.add_rounded, onTap: onAdd),
      body: RefreshIndicator(
        onRefresh: onRefresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 100),
          children: [
            _LivestockSummaryCard(summary: summary, digits: digits),
            const SizedBox(height: Gap.lg),
            for (final a in livestock) ...[
              _AnimalCard(animal: a, digits: digits, now: now, onTap: () => onEdit(a)),
              const SizedBox(height: Gap.md),
            ],
          ],
        ),
      ),
    );
  }
}

class _LivestockSummaryCard extends StatelessWidget {
  final LivestockSummary summary;
  final String Function(Object) digits;
  const _LivestockSummaryCard({required this.summary, required this.digits});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.pets_rounded, size: 26),
                const SizedBox(width: Gap.sm),
                Text('${t.farmerTotalHead}: ${digits(summary.totalHead)}',
                    style: _title.copyWith(fontWeight: FontWeight.bold)),
              ],
            ),
            if (summary.vaccDue > 0 || summary.vaccSoon > 0) ...[
              const SizedBox(height: Gap.md),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(Gap.md),
                decoration: BoxDecoration(
                  color: Brand.warning.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(Radii.md),
                  border: Border.all(color: Brand.warning, width: 2),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.vaccines_rounded, size: 24, color: Brand.warning),
                    const SizedBox(width: Gap.sm),
                    Expanded(
                      child: Text(
                          t.farmerVaccDueSummary(
                              digits(summary.vaccDue), digits(summary.vaccSoon)),
                          style: AType.bodyLarge.copyWith(height: 1.3)),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AnimalCard extends StatelessWidget {
  final Map<String, dynamic> animal;
  final String Function(Object) digits;
  final DateTime now;
  final VoidCallback onTap;
  const _AnimalCard(
      {required this.animal, required this.digits, required this.now, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final key = (animal['animal'] ?? '').toString().trim();
    final count = (animal['count'] ?? 0);
    final v = FarmerEngine.vaccinationStatus(animal['last_vaccinated'], now: now);
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(farmerAnimalLabel(t, key),
                        style: _title.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: Gap.xxs),
                    Text('${t.farmerCount}: ${digits(count)}',
                        style: _body.copyWith(color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              _VaccBadge(v: v),
            ],
          ),
        ),
      ),
    );
  }
}

class _VaccBadge extends StatelessWidget {
  final VaccStatus v;
  const _VaccBadge({required this.v});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    late final Color c;
    late final String label;
    late final IconData icon;
    switch (v.status) {
      case kVaccDue:
        c = Theme.of(context).colorScheme.error;
        label = t.farmerVaccDue;
        icon = Icons.vaccines_rounded;
        break;
      case kVaccSoon:
        c = AssistoTokens.of(context).warning;
        label = t.farmerVaccSoon;
        icon = Icons.schedule_rounded;
        break;
      case kVaccOk:
        c = AssistoTokens.of(context).success;
        label = t.farmerVaccOk;
        icon = Icons.check_circle_rounded;
        break;
      default:
        c = AssistoTokens.of(context).textMuted;
        label = t.farmerVaccUnknown;
        icon = Icons.help_outline_rounded;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: c, width: 1.5),
      ),
      child: Column(
        children: [
          Icon(icon, size: 22, color: c),
          const SizedBox(height: Gap.xxs),
          Text(label, style: AType.titleSmall.copyWith(color: c, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

// =========================================================================== //
// shared atoms
// =========================================================================== //

class _WelcomeState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final String cta;
  final VoidCallback onCta;
  const _WelcomeState(
      {required this.icon,
      required this.title,
      required this.body,
      required this.cta,
      required this.onCta});

  @override
  Widget build(BuildContext context) {
    // Theme success green: dark on light surfaces, lifted on near-black (its
    // 0.12-alpha badge and button stay visible in dark mode).
    final k = AssistoTokens.of(context);
    final green = k.success;
    return StateMessage(
      icon: icon,
      tint: green,
      title: title,
      message: body,
      action: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56, minWidth: 200),
        child: FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: green,
            // qa1: white on the lifted dark-mode green was 2.5:1
            foregroundColor: k.onSuccess,
          ),
          onPressed: onCta,
          icon: const Icon(Icons.add_rounded, size: 26),
          label: Text(cta, style: _body),
        ),
      ),
    );
  }
}

class _BigFab extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  const _BigFab({required this.label, required this.icon, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return FloatingActionButton.extended(
      backgroundColor: Brand.successFill,
      foregroundColor: Colors.white,
      onPressed: onTap,
      icon: Icon(icon, size: 26),
      label: Text(label, style: _body.copyWith(fontWeight: FontWeight.w700)),
    );
  }
}

// =========================================================================== //
// FORMS
// =========================================================================== //

class _RecordForm extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _RecordForm({this.existing});
  @override
  State<_RecordForm> createState() => _RecordFormState();
}

class _RecordFormState extends State<_RecordForm> {
  late final TextEditingController _name;
  late final TextEditingController _cost;
  late final TextEditingController _income;
  late final TextEditingController _notes;
  String? _crop;
  DateTime? _planted;
  DateTime? _harvest;
  String? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.existing ?? const {};
    _name = TextEditingController(text: (e['name'] ?? '').toString());
    _cost = TextEditingController(
        text: (e['cost'] == null || e['cost'] == 0) ? '' : e['cost'].toString());
    _income = TextEditingController(
        text: (e['income'] == null || e['income'] == 0) ? '' : e['income'].toString());
    _notes = TextEditingController(text: (e['notes'] ?? '').toString());
    final c = (e['crop'] ?? '').toString();
    _crop = c.isEmpty ? null : c;
    _planted = _parse(e['planted']);
    _harvest = _parse(e['harvest']);
  }

  DateTime? _parse(dynamic v) {
    if (v == null) return null;
    final s = v.toString();
    return s.length >= 10 ? DateTime.tryParse(s.substring(0, 10)) : null;
  }

  @override
  void dispose() {
    _name.dispose();
    _cost.dispose();
    _income.dispose();
    _notes.dispose();
    super.dispose();
  }

  String? _iso(DateTime? d) => d == null
      ? null
      : '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _pick(bool planted) async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: (planted ? _planted : _harvest) ?? now,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 3),
    );
    if (d == null) return;
    setState(() => planted ? _planted = d : _harvest = d);
  }

  void _save() {
    final t = AppLocalizations.of(context);
    final row = <String, dynamic>{
      'name': _name.text.trim(),
      'crop': _crop ?? '',
      'planted': _iso(_planted) ?? '',
      'harvest': _iso(_harvest) ?? '',
      'cost': num.tryParse(_cost.text.trim()) ?? 0,
      'income': num.tryParse(_income.text.trim()) ?? 0,
      'notes': _notes.text.trim(),
    };
    final problems = FarmerEngine.validateRecord(row);
    if (problems.isNotEmpty) {
      setState(() => _error = _problemText(t, problems.first));
      return;
    }
    Navigator.pop(context, row);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 4,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.existing == null ? t.farmerAddRecord : t.farmerEditRecord,
                style: _title.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: Gap.lg),
            _bigField(_name, t.farmerFieldName, Icons.label_outline_rounded),
            const SizedBox(height: Gap.md),
            DropdownButtonFormField<String>(
              initialValue: _crop,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: t.farmerFieldCrop,
                prefixIcon: const Icon(Icons.eco_rounded, size: 24),
                border: const OutlineInputBorder(),
              ),
              style: _body,
              items: [
                for (final c in kSeasons.values.expand((s) => (s['crops']! as List)).cast<String>().toSet())
                  DropdownMenuItem(value: c, child: Text(farmerCropLabel(t, c))),
              ],
              onChanged: (v) => setState(() => _crop = v),
            ),
            const SizedBox(height: Gap.md),
            Row(children: [
              Expanded(
                  child: _dateTile(t.farmerFieldPlanted, _planted, () => _pick(true))),
              const SizedBox(width: Gap.md),
              Expanded(
                  child: _dateTile(t.farmerFieldHarvest, _harvest, () => _pick(false))),
            ]),
            const SizedBox(height: Gap.md),
            Row(children: [
              Expanded(child: _bigField(_cost, t.farmerFieldCost, Icons.payments_rounded, number: true)),
              const SizedBox(width: Gap.md),
              Expanded(child: _bigField(_income, t.farmerFieldIncome, Icons.sell_rounded, number: true)),
            ]),
            const SizedBox(height: Gap.md),
            _bigField(_notes, t.farmerFieldNotes, Icons.notes_rounded, lines: 2),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: AType.bodyLarge.copyWith(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 18),
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56),
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Brand.successFill, foregroundColor: Colors.white),
                onPressed: _save,
                child: Text(t.save, style: _body),
              ),
            ),
            if (widget.existing != null) ...[
              const SizedBox(height: Gap.sm),
              TextButton.icon(
                onPressed: () => Navigator.pop(context, {'__delete__': true}),
                icon: const Icon(Icons.delete_outline_rounded, color: Brand.danger),
                label: Text(t.delete, style: _body.copyWith(color: Theme.of(context).colorScheme.error)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _bigField(TextEditingController c, String label, IconData icon,
          {bool number = false, int lines = 1}) =>
      TextField(
        controller: c,
        maxLines: lines,
        keyboardType: number ? const TextInputType.numberWithOptions(decimal: true) : null,
        style: _body,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon, size: 24),
          border: const OutlineInputBorder(),
        ),
      );

  Widget _dateTile(String label, DateTime? value, VoidCallback onTap) {
    final t = AppLocalizations.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Radii.sm),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: const Icon(Icons.event_rounded, size: 24),
          border: const OutlineInputBorder(),
        ),
        child: Text(
          value == null
              ? t.farmerPickDate
              : '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}',
          style: AType.bodyLarge,
        ),
      ),
    );
  }

  String _problemText(AppLocalizations t, String code) {
    switch (code) {
      case 'name_required':
        return t.farmerErrNameRequired;
      case 'harvest_before_planting':
        return t.farmerErrHarvestBeforePlanting;
      default:
        return t.farmerErrInvalid;
    }
  }
}

class _LivestockForm extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _LivestockForm({this.existing});
  @override
  State<_LivestockForm> createState() => _LivestockFormState();
}

class _LivestockFormState extends State<_LivestockForm> {
  String? _animal;
  late final TextEditingController _count;
  late final TextEditingController _notes;
  DateTime? _lastVacc;
  String? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.existing ?? const {};
    final a = (e['animal'] ?? '').toString();
    _animal = a.isEmpty ? null : a;
    _count = TextEditingController(
        text: (e['count'] == null || e['count'] == 0) ? '' : e['count'].toString());
    _notes = TextEditingController(text: (e['notes'] ?? '').toString());
    final lv = (e['last_vaccinated'] ?? '').toString();
    _lastVacc = lv.length >= 10 ? DateTime.tryParse(lv.substring(0, 10)) : null;
  }

  @override
  void dispose() {
    _count.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _save() {
    final t = AppLocalizations.of(context);
    final row = <String, dynamic>{
      'animal': _animal ?? '',
      'count': int.tryParse(_count.text.trim()) ?? 0,
      'last_vaccinated': _lastVacc == null
          ? ''
          : '${_lastVacc!.year.toString().padLeft(4, '0')}-${_lastVacc!.month.toString().padLeft(2, '0')}-${_lastVacc!.day.toString().padLeft(2, '0')}',
      'notes': _notes.text.trim(),
    };
    final problems = FarmerEngine.validateLivestock(row);
    if (problems.isNotEmpty) {
      setState(() => _error = problems.first == 'animal_required'
          ? t.farmerErrAnimalRequired
          : t.farmerErrInvalid);
      return;
    }
    Navigator.pop(context, row);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.only(
          left: 16, right: 16, top: 4, bottom: MediaQuery.of(context).viewInsets.bottom + 20),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.existing == null ? t.farmerAddAnimal : t.farmerEditAnimal,
                style: _title.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: Gap.lg),
            DropdownButtonFormField<String>(
              initialValue: _animal,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: t.farmerFieldAnimal,
                prefixIcon: const Icon(Icons.pets_rounded, size: 24),
                border: const OutlineInputBorder(),
              ),
              style: _body,
              items: [
                for (final a in kAnimalKeys)
                  DropdownMenuItem(value: a, child: Text(farmerAnimalLabel(t, a))),
              ],
              onChanged: (v) => setState(() => _animal = v),
            ),
            const SizedBox(height: Gap.md),
            TextField(
              controller: _count,
              keyboardType: TextInputType.number,
              style: _body,
              decoration: InputDecoration(
                labelText: t.farmerFieldCount,
                prefixIcon: const Icon(Icons.numbers_rounded, size: 24),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: Gap.md),
            InkWell(
              onTap: () async {
                final now = DateTime.now();
                final d = await showDatePicker(
                  context: context,
                  initialDate: _lastVacc ?? now,
                  firstDate: DateTime(now.year - 5),
                  lastDate: now,
                );
                if (d != null) setState(() => _lastVacc = d);
              },
              borderRadius: BorderRadius.circular(Radii.sm),
              child: InputDecorator(
                decoration: InputDecoration(
                  labelText: t.farmerFieldLastVacc,
                  prefixIcon: const Icon(Icons.vaccines_rounded, size: 24),
                  helperText: t.farmerLastVaccHelper,
                  border: const OutlineInputBorder(),
                ),
                child: Text(
                  _lastVacc == null
                      ? t.farmerPickDate
                      : '${_lastVacc!.year}-${_lastVacc!.month.toString().padLeft(2, '0')}-${_lastVacc!.day.toString().padLeft(2, '0')}',
                  style: AType.bodyLarge,
                ),
              ),
            ),
            const SizedBox(height: Gap.md),
            TextField(
              controller: _notes,
              maxLines: 2,
              style: _body,
              decoration: InputDecoration(
                labelText: t.farmerFieldNotes,
                prefixIcon: const Icon(Icons.notes_rounded, size: 24),
                border: const OutlineInputBorder(),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: AType.bodyLarge.copyWith(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 18),
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56),
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Brand.successFill, foregroundColor: Colors.white),
                onPressed: _save,
                child: Text(t.save, style: _body),
              ),
            ),
            if (widget.existing != null) ...[
              const SizedBox(height: Gap.sm),
              TextButton.icon(
                onPressed: () => Navigator.pop(context, {'__delete__': true}),
                icon: const Icon(Icons.delete_outline_rounded, color: Brand.danger),
                label: Text(t.delete, style: _body.copyWith(color: Theme.of(context).colorScheme.error)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
