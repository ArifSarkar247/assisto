import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import '../widgets/ladder_common.dart' show fmtInt;

/// MY VEHICLES — anti-theft module Batch 2 (vehicle profile + expiry reminders
/// + an HONEST buying guide). CODE ONLY.
///
/// Persistence rides the generic per-user JSON collection (PaCollectionItem
/// precedent, same as mess_accounting):
///   listItems('vehicle/records')             → [{id, ...data}]
///   createItem('vehicle/records', data)      → {id, ...data}
///   updateItem('vehicle/records', id, data)
///   deleteItem('vehicle/records', id)
/// Each record's `data` carries: type ('car'|'motorcycle'), name,
/// registration_no, chassis_no, engine_no, tax_token_expiry, fitness_expiry,
/// insurance_expiry (all dates ISO yyyy-MM-dd). Vehicle reg/chassis/engine
/// numbers are USER DATA, not localized.
///
/// PHOTOS: the generic collection api is JSON-only (createItem/updateItem POST a
/// map) — it has NO multipart/file path (that lives only in the documents/vault
/// api). So vehicle photos are DEFERRED; not stored here.
///
/// When a vehicle is saved with an expiry date set, we OFFER to create a YEARLY
/// reminder via the existing reminder-create path (createItem('reminders', ...),
/// the same call fam_probashi_section uses) — guarded best-effort.
///
/// Live GPS tracking (GT06 server) is a LATER batch — the buying guide says so
/// honestly ("coming soon"); there is NO fake map and NO hardcoded prices here.
class MyVehiclesScreen extends StatefulWidget {
  const MyVehiclesScreen({super.key});
  @override
  State<MyVehiclesScreen> createState() => _MyVehiclesScreenState();
}

const String _vehiclePath = 'vehicle/records';

class _MyVehiclesScreenState extends State<MyVehiclesScreen> {
  List<Map<String, dynamic>> _vehicles = [];
  bool _loading = true, _error = false;

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
      _vehicles = await api.listItems(_vehiclePath);
    } catch (_) {
      _error = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Map<String, dynamic> _dataOf(Map<String, dynamic> v) {
    final d = v['data'];
    if (d is Map) return Map<String, dynamic>.from(d);
    // Fallback: some collections flatten data onto the row itself.
    return Map<String, dynamic>.from(v)..remove('id');
  }

  Future<void> _addOrEdit([Map<String, dynamic>? existing]) async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    final data = existing == null ? <String, dynamic>{} : _dataOf(existing);
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _VehicleForm(initial: data),
    );
    if (result == null) return;
    try {
      if (existing != null && existing['id'] is int) {
        await api.updateItem(_vehiclePath, existing['id'] as int,
            {'data': result});
      } else {
        await api.createItem(_vehiclePath, {'data': result});
      }
      await _load();
      if (!mounted) return;
      _toast(tr.vehiclesSaved);
      await _offerReminders(result);
    } catch (_) {
      if (mounted) _toast(tr.vehiclesSaveFailed);
    }
  }

  /// For each expiry date set on the vehicle, OFFER a yearly reminder. Reuses
  /// the existing reminder-create path; fully best-effort (never blocks save).
  Future<void> _offerReminders(Map<String, dynamic> data) async {
    final tr = AppLocalizations.of(context);
    final name = (data['name'] ?? '').toString().trim();
    final fields = <String, String>{
      'tax_token_expiry': tr.vehiclesTaxToken,
      'fitness_expiry': tr.vehiclesFitness,
      'insurance_expiry': tr.vehiclesInsurance,
    };
    for (final entry in fields.entries) {
      final iso = (data[entry.key] ?? '').toString();
      if (iso.isEmpty) continue;
      final due = DateTime.tryParse(iso);
      if (due == null) continue;
      if (!mounted) return;
      final label = name.isEmpty
          ? entry.value
          : tr.vehiclesReminderTitle(entry.value, name);
      final ok = await showDialog<bool>(
        context: context,
        builder: (dctx) => AlertDialog(
          title: Text(tr.vehiclesRemindTitle),
          content: Text(tr.vehiclesRemindBody(label)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dctx, false),
                child: Text(tr.vehiclesRemindSkip)),
            FilledButton(
                onPressed: () => Navigator.pop(dctx, true),
                child: Text(tr.vehiclesRemindCreate)),
          ],
        ),
      );
      if (ok != true) continue;
      try {
        await context.read<AppState>().api.createItem('reminders', {
          'title': label,
          'due': DateTime(due.year, due.month, due.day, 9).toIso8601String(),
          'kind': 'vehicle',
          'recurrence': 'yearly',
        });
        if (mounted) _toast(tr.vehiclesReminderCreated);
      } catch (_) {
        if (mounted) _toast(tr.vehiclesReminderFailed);
      }
    }
  }

  Future<void> _confirmDelete(Map<String, dynamic> v) async {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final api = context.read<AppState>().api;
    final name = (_dataOf(v)['name'] ?? '').toString();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.vehiclesDeleteTitle),
        content: Text(tr.vehiclesDeleteBody(name)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr.cancel)),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: scheme.error, foregroundColor: scheme.onError),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr.delete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final id = v['id'];
    if (id is int) await api.deleteItem(_vehiclePath, id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(tr.vehiclesTitle),
          bottom: TabBar(tabs: [
            Tab(text: tr.vehiclesTabMine),
            Tab(text: tr.vehiclesTabGuide),
          ]),
        ),
        body: TabBarView(children: [
          _buildMyVehicles(tr, scheme),
          const _BuyingGuideTab(),
        ]),
      ),
    );
  }

  Widget _buildMyVehicles(AppLocalizations tr, ColorScheme scheme) {
    if (_loading) return const SkeletonList();
    if (_error) {
      return StateMessage(
        icon: Icons.cloud_off,
        tint: scheme.error,
        title: tr.loadFailed,
        message: tr.vehiclesLoadError,
        action: FilledButton.tonalIcon(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            label: Text(tr.retry)),
      );
    }
    if (_vehicles.isEmpty) {
      // empty state has its own CTA: no duplicate FAB
      return Scaffold(
        body: StateMessage(
          icon: Icons.directions_car_outlined,
          title: tr.vehiclesEmptyTitle,
          message: tr.vehiclesEmptyBody,
          action: FilledButton.icon(
            onPressed: () => _addOrEdit(),
            icon: const Icon(Icons.add),
            label: Text(tr.vehiclesAdd),
          ),
        ),
      );
    }
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addOrEdit(),
        icon: const Icon(Icons.add),
        label: Text(tr.vehiclesAdd),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
          itemCount: _vehicles.length,
          separatorBuilder: (_, __) => const SizedBox(height: Gap.sm),
          itemBuilder: (_, i) => _vehicleCard(_vehicles[i], tr, scheme),
        ),
      ),
    );
  }

  Widget _vehicleCard(
      Map<String, dynamic> v, AppLocalizations tr, ColorScheme scheme) {
    final data = _dataOf(v);
    final isBike = (data['type'] ?? 'car').toString() == 'motorcycle';
    final name = (data['name'] ?? '').toString().trim();
    final reg = (data['registration_no'] ?? '').toString().trim();
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            CircleAvatar(
              backgroundColor: scheme.primaryContainer,
              child: Icon(
                  isBike
                      ? Icons.two_wheeler_outlined
                      : Icons.directions_car_outlined,
                  color: scheme.onPrimaryContainer),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name.isEmpty ? tr.vehiclesUnnamed : name,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    Text(
                        '${isBike ? tr.vehiclesTypeBike : tr.vehiclesTypeCar}'
                        '${reg.isEmpty ? '' : '  ·  $reg'}',
                        style: TextStyle(
                            fontSize: 12.5, color: scheme.onSurfaceVariant),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ]),
            ),
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: tr.edit,
              onPressed: () => _addOrEdit(v),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: tr.delete,
              onPressed: () => _confirmDelete(v),
            ),
          ]),
          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            _expiryChip(tr.vehiclesTaxToken, data['tax_token_expiry'], tr),
            _expiryChip(tr.vehiclesFitness, data['fitness_expiry'], tr),
            _expiryChip(tr.vehiclesInsurance, data['insurance_expiry'], tr),
          ]),
        ]),
      ),
    );
  }

  /// Expiry badge — mirrors vault_screen: red <7 days (and expired), orange <30.
  Widget _expiryChip(String label, dynamic iso, AppLocalizations tr) {
    final scheme = Theme.of(context).colorScheme;
    final d = iso == null ? null : DateTime.tryParse(iso.toString());
    if (d == null) {
      return _chip(
          '$label · ${tr.vehiclesNotSet}', scheme.onSurfaceVariant);
    }
    final days = d.difference(DateTime.now()).inDays;
    final daysStr = fmtInt(context, days.abs());
    Color c;
    String text;
    if (days < 0) {
      c = Brand.danger;
      text = '$label · ${tr.vehiclesExpired}';
    } else if (days <= 7) {
      c = Brand.danger;
      text = '$label · ${tr.vehiclesExpiresInDays(daysStr)}';
    } else if (days <= 30) {
      c = Brand.warning;
      text = '$label · ${tr.vehiclesExpiresInDays(daysStr)}';
    } else {
      c = Brand.success;
      text =
          '$label · ${DateFormat('d MMM yyyy', Localizations.localeOf(context).languageCode).format(d)}';
    }
    return _chip(text, c);
  }

  Widget _chip(String text, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 4),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(Radii.pill),
        ),
        child: Text(text,
            style:
                TextStyle(fontSize: 11.5, color: c, fontWeight: FontWeight.w600)),
      );
}

// ======================= ADD / EDIT FORM =======================
class _VehicleForm extends StatefulWidget {
  final Map<String, dynamic> initial;
  const _VehicleForm({required this.initial});
  @override
  State<_VehicleForm> createState() => _VehicleFormState();
}

class _VehicleFormState extends State<_VehicleForm> {
  late String _type;
  late final TextEditingController _name;
  late final TextEditingController _reg;
  late final TextEditingController _chassis;
  late final TextEditingController _engine;
  DateTime? _tax, _fitness, _insurance;

  @override
  void initState() {
    super.initState();
    final d = widget.initial;
    _type = (d['type'] ?? 'car').toString() == 'motorcycle' ? 'motorcycle' : 'car';
    _name = TextEditingController(text: (d['name'] ?? '').toString());
    _reg = TextEditingController(text: (d['registration_no'] ?? '').toString());
    _chassis = TextEditingController(text: (d['chassis_no'] ?? '').toString());
    _engine = TextEditingController(text: (d['engine_no'] ?? '').toString());
    _tax = DateTime.tryParse((d['tax_token_expiry'] ?? '').toString());
    _fitness = DateTime.tryParse((d['fitness_expiry'] ?? '').toString());
    _insurance = DateTime.tryParse((d['insurance_expiry'] ?? '').toString());
  }

  @override
  void dispose() {
    _name.dispose();
    _reg.dispose();
    _chassis.dispose();
    _engine.dispose();
    super.dispose();
  }

  Future<void> _pickDate(DateTime? current, ValueChanged<DateTime> onPick) async {
    final d = await showDatePicker(
      context: context,
      initialDate: current ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (d != null) setState(() => onPick(d));
  }

  String _dateLabel(String label, DateTime? d, AppLocalizations tr) {
    if (d == null) return label;
    return '$label: ${DateFormat('d MMM yyyy', Localizations.localeOf(context).languageCode).format(d)}';
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final insets = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
      child: SingleChildScrollView(
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr.vehiclesFormTitle,
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: Gap.lg),
              Wrap(spacing: Gap.sm, children: [
                ChoiceChip(
                  label: Text(tr.vehiclesTypeCar),
                  avatar: const Icon(Icons.directions_car_outlined, size: 18),
                  selected: _type == 'car',
                  onSelected: (_) => setState(() => _type = 'car'),
                ),
                ChoiceChip(
                  label: Text(tr.vehiclesTypeBike),
                  avatar: const Icon(Icons.two_wheeler_outlined, size: 18),
                  selected: _type == 'motorcycle',
                  onSelected: (_) => setState(() => _type = 'motorcycle'),
                ),
              ]),
              const SizedBox(height: Gap.md),
              TextField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                    labelText: tr.vehiclesFieldName,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: _reg,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                    labelText: tr.vehiclesFieldReg,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: _chassis,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                    labelText: tr.vehiclesFieldChassis,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: _engine,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                    labelText: tr.vehiclesFieldEngine,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.lg),
              Text(tr.vehiclesExpiriesHeader,
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: Gap.sm),
              OutlinedButton.icon(
                icon: const Icon(Icons.event, size: 18),
                label: Text(_dateLabel(tr.vehiclesTaxToken, _tax, tr)),
                onPressed: () => _pickDate(_tax, (d) => _tax = d),
              ),
              const SizedBox(height: Gap.sm),
              OutlinedButton.icon(
                icon: const Icon(Icons.event, size: 18),
                label: Text(_dateLabel(tr.vehiclesFitness, _fitness, tr)),
                onPressed: () => _pickDate(_fitness, (d) => _fitness = d),
              ),
              const SizedBox(height: Gap.sm),
              OutlinedButton.icon(
                icon: const Icon(Icons.event, size: 18),
                label: Text(_dateLabel(tr.vehiclesInsurance, _insurance, tr)),
                onPressed: () => _pickDate(_insurance, (d) => _insurance = d),
              ),
              const SizedBox(height: Gap.lg),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(tr.cancel)),
                ),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: FilledButton(
                    onPressed: _save,
                    child: Text(tr.save),
                  ),
                ),
              ]),
            ]),
      ),
    );
  }

  void _save() {
    String? iso(DateTime? d) =>
        d == null ? null : DateFormat('yyyy-MM-dd').format(d);
    Navigator.pop(context, <String, dynamic>{
      'type': _type,
      'name': _name.text.trim(),
      'registration_no': _reg.text.trim(),
      'chassis_no': _chassis.text.trim(),
      'engine_no': _engine.text.trim(),
      if (iso(_tax) != null) 'tax_token_expiry': iso(_tax),
      if (iso(_fitness) != null) 'fitness_expiry': iso(_fitness),
      if (iso(_insurance) != null) 'insurance_expiry': iso(_insurance),
    });
  }
}

// ======================= BUYING GUIDE (honest, static) =======================
class _BuyingGuideTab extends StatelessWidget {
  const _BuyingGuideTab();

  Future<void> _openSearch(String query) async {
    final uri = Uri.parse(
        'https://www.google.com/search?q=${Uri.encodeQueryComponent(query)}');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 32),
      children: [
        // Coming-soon note: Assisto's own tracking is a later batch — honest.
        Card(
          color: scheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Row(children: [
              Icon(Icons.info_outline, size: 18, color: scheme.primary),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(tr.vehiclesTrackingComingSoon,
                    style: TextStyle(
                        fontSize: 12.5, color: scheme.onSurfaceVariant)),
              ),
            ]),
          ),
        ),
        const SizedBox(height: Gap.lg),

        // SIM GPS vs Bluetooth tag comparison.
        _header(context, Icons.compare_arrows_outlined, tr.vehiclesCompareTitle),
        const SizedBox(height: Gap.sm),
        _compareCard(
          context,
          icon: Icons.sim_card_outlined,
          title: tr.vehiclesSimTitle,
          lines: [
            tr.vehiclesSimHow,
            tr.vehiclesSimCoverage,
            tr.vehiclesSimBattery,
            tr.vehiclesSimLimit,
          ],
        ),
        const SizedBox(height: Gap.sm),
        _compareCard(
          context,
          icon: Icons.bluetooth_outlined,
          title: tr.vehiclesBtTitle,
          lines: [
            tr.vehiclesBtHow,
            tr.vehiclesBtCoverage,
            tr.vehiclesBtBattery,
            tr.vehiclesBtLimit,
          ],
        ),
        const SizedBox(height: Gap.lg),

        // What to look for checklist.
        _header(context, Icons.checklist_outlined, tr.vehiclesChecklistTitle),
        const SizedBox(height: Gap.sm),
        _bullet(context, tr.vehiclesCheckCutoff),
        _bullet(context, tr.vehiclesCheckBackupBattery),
        _bullet(context, tr.vehiclesCheckTamperAlert),
        _bullet(context, tr.vehiclesCheckGt06),
        _bullet(context, tr.vehiclesCheckSimPlan),
        const SizedBox(height: Gap.lg),

        // Installation tips.
        _header(context, Icons.build_outlined, tr.vehiclesInstallTitle),
        const SizedBox(height: Gap.sm),
        _bullet(context, tr.vehiclesInstallHidden),
        _bullet(context, tr.vehiclesInstallPower),
        _bullet(context, tr.vehiclesInstallPro),
        const SizedBox(height: Gap.lg),

        // Prices — honest: no hardcoded numbers, just a live search.
        _header(context, Icons.payments_outlined, tr.vehiclesPriceTitle),
        const SizedBox(height: Gap.sm),
        Text(tr.vehiclesPriceNote,
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.sm),
        Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
          FilledButton.tonalIcon(
            onPressed: () => _openSearch(tr.vehiclesPriceQueryGps),
            icon: const Icon(Icons.search),
            label: Text(tr.vehiclesPriceCheckGps),
          ),
          FilledButton.tonalIcon(
            onPressed: () => _openSearch(tr.vehiclesPriceQueryBt),
            icon: const Icon(Icons.search),
            label: Text(tr.vehiclesPriceCheckBt),
          ),
        ]),
        const SizedBox(height: Gap.lg),
        Text(tr.vehiclesPriceDisclaimer,
            style: TextStyle(
                fontSize: 11.5,
                fontStyle: FontStyle.italic,
                color: scheme.onSurfaceVariant)),
      ],
    );
  }

  Widget _header(BuildContext context, IconData icon, String title) {
    final scheme = Theme.of(context).colorScheme;
    return Row(children: [
      Icon(icon, size: 18, color: scheme.primary),
      const SizedBox(width: Gap.sm),
      Expanded(
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      ),
    ]);
  }

  Widget _compareCard(BuildContext context,
      {required IconData icon,
      required String title,
      required List<String> lines}) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: 20, color: scheme.primary),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(title,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
          ]),
          const SizedBox(height: Gap.sm),
          for (final l in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.xs),
              child:
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(
                  padding: const EdgeInsets.only(top: 3, right: Gap.sm),
                  child: Icon(Icons.chevron_right,
                      size: 15, color: scheme.onSurfaceVariant),
                ),
                Expanded(
                    child: Text(l, style: const TextStyle(fontSize: 13))),
              ]),
            ),
        ]),
      ),
    );
  }

  Widget _bullet(BuildContext context, String text) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.check_circle_outline, size: 18, color: Brand.success),
        const SizedBox(width: Gap.sm),
        Expanded(
            child: Text(text,
                style: TextStyle(fontSize: 13, color: scheme.onSurface))),
      ]),
    );
  }
}
