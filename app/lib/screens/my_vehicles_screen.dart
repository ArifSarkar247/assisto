import '../feature_flags.dart' show FeatureFlags; // feature-flags
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import '../widgets/ladder_common.dart' show fmtInt;
import 'vehicle_tracking_screen.dart';
import 'package:assisto/widgets/app_sheet.dart';
import 'vehicle_drivers_screen.dart'; // veh100
import '../vehicle/vehicle_api.dart'; // veh100
import '../vehicle/veh_format.dart' show vehNumStr; // veh100
import '../services/error_kind.dart' show honestFailText; // qa2

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
/// Live GPS tracking of a paired GT06 / Teltonika tracker lives in
/// VehicleTrackingScreen (v1-vehicle) — reached from the AppBar and the guide.
class MyVehiclesScreen extends StatefulWidget {
  const MyVehiclesScreen({super.key});
  @override
  State<MyVehiclesScreen> createState() => _MyVehiclesScreenState();
}

const String _vehiclePath = 'vehicle/records';

class _MyVehiclesScreenState extends State<MyVehiclesScreen> {
  List<Map<String, dynamic>> _vehicles = [];
  // veh100: what the SERVER says is due (the same rules its reminder pushes use)
  List<Map<String, dynamic>> _due = const [];
  bool _loading = true, _error = false;
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
      _vehicles = await api.listItems(_vehiclePath);
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    try {
      _due = vehList((await api.vehMaintenance())['due']);
    } catch (_) {
      _due = const []; // the list still works; the banner just stays hidden
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
    final result = await showAppSheet<Map<String, dynamic>>(
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
      'route_permit_expiry': tr.v100RoutePermit,
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
          scrollable: true, // insets: 200% text / keyboard
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
        scrollable: true, // insets: 200% text / keyboard
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
          actions: [
            IconButton(
              tooltip: tr.v100DriversTitle,
              icon: const Icon(Icons.badge_rounded),
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const VehicleDriversScreen())),
            ),
            // v1-vehicle: live GPS tracking of paired hardware trackers
            // (feature-flags: its own flag, vehicle_tracking)
            if (FeatureFlags.instance.isOn('vehicle_tracking'))
            IconButton(
              tooltip: tr.vehTrackingTitle,
              icon: const Icon(Icons.gps_fixed_rounded),
              onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const VehicleTrackingScreen())),
            ),
          ],
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
        icon: Icons.cloud_off_rounded,
        tint: scheme.error,
        title: tr.loadFailed,
        message: honestFailText(tr, _failCause, otherwise: tr.vehiclesLoadError),
        action: FilledButton.tonalIcon(
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(tr.retry)),
      );
    }
    if (_vehicles.isEmpty) {
      // empty state has its own CTA: no duplicate FAB
      return Scaffold(
        body: StateMessage(
          icon: Icons.directions_car_rounded,
          title: tr.vehiclesEmptyTitle,
          message: tr.vehiclesEmptyBody,
          action: FilledButton.icon(
            onPressed: () => _addOrEdit(),
            icon: const Icon(Icons.add_rounded),
            label: Text(tr.vehiclesAdd),
          ),
        ),
      );
    }
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addOrEdit(),
        icon: const Icon(Icons.add_rounded),
        label: Text(tr.vehiclesAdd),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
          itemCount: _vehicles.length + 1,
          separatorBuilder: (_, __) => const SizedBox(height: Gap.sm),
          itemBuilder: (_, i) => i == 0
              ? _dueBanner(tr, scheme)
              : _vehicleCard(_vehicles[i - 1], tr, scheme),
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
                      ? Icons.two_wheeler_rounded
                      : Icons.directions_car_rounded,
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
                        style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ]),
            ),
            IconButton(
              icon: const Icon(Icons.edit_rounded),
              tooltip: tr.edit,
              onPressed: () => _addOrEdit(v),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded),
              tooltip: tr.delete,
              onPressed: () => _confirmDelete(v),
            ),
          ]),
          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            _expiryChip(tr.vehiclesTaxToken, data['tax_token_expiry'], tr),
            _expiryChip(tr.vehiclesFitness, data['fitness_expiry'], tr),
            _expiryChip(tr.vehiclesInsurance, data['insurance_expiry'], tr),
            if ((data['route_permit_expiry'] ?? '').toString().isNotEmpty)
              _expiryChip(tr.v100RoutePermit, data['route_permit_expiry'], tr),
          ]),
          if (data['maintenance'] is List && (data['maintenance'] as List).isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            Text(tr.v100ServiceRulesN(
                    vehNumStr(context, (data['maintenance'] as List).length)),
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ]),
      ),
    );
  }

  /// Expiry badge — mirrors vault_screen: red <7 days (and expired), orange <30.
  /// veh100: everything due soon, as the server computes it (papers 30/7/1
  /// days, service by km or date, driver licences). Hidden when nothing is due.
  Widget _dueBanner(AppLocalizations tr, ColorScheme scheme) {
    if (_due.isEmpty) return const SizedBox.shrink();
    final bn = Localizations.localeOf(context).languageCode != 'en';
    String line(Map<String, dynamic> d) {
      final label = '${bn ? d['label_bn'] : d['label_en']}';
      final who = '${d['name'] ?? ''}'.trim();
      final days = vehInt(d['days_left']);
      final km = vehNum(d['km_left']);
      final when = d['by'] == 'km' && km != null
          ? (km <= 0 ? tr.v100DueNow : tr.v100DueKm(vehNumStr(context, km.round())))
          : (days == null
              ? ''
              : (days <= 0 ? tr.v100DueToday : tr.v100DueDays(vehNumStr(context, days))));
      return [if (who.isNotEmpty) who, label, if (when.isNotEmpty) when].join(' · ');
    }

    return Card(
      key: const ValueKey('veh-due-banner'),
      margin: EdgeInsets.zero,
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.notification_important_rounded, color: scheme.onErrorContainer),
            const SizedBox(width: Gap.sm),
            Expanded(
                child: Text(tr.v100DueTitle,
                    style: TextStyle(
                        fontWeight: FontWeight.w700, color: scheme.onErrorContainer))),
          ]),
          const SizedBox(height: Gap.xs),
          for (final d in _due.take(6))
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(line(d), style: TextStyle(color: scheme.onErrorContainer)),
            ),
          const SizedBox(height: Gap.xs),
          Text(tr.v100DueFoot,
              style: AType.bodySmall.copyWith(color: scheme.onErrorContainer)),
        ]),
      ),
    );
  }

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
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xs),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(Radii.pill),
        ),
        child: Text(text,
            style:
                AType.bodySmall.copyWith(color: c, fontWeight: FontWeight.w600)),
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
  DateTime? _tax, _fitness, _insurance, _permit;
  late final TextEditingController _odo; // veh100: manual odometer (no tracker)
  late List<Map<String, dynamic>> _rules; // veh100: service by km and/or date

  @override
  void initState() {
    super.initState();
    final d = widget.initial;
    _permit = DateTime.tryParse((d['route_permit_expiry'] ?? '').toString());
    _odo = TextEditingController(text: (d['odometer_km'] ?? '').toString());
    _rules = [
      for (final r in (d['maintenance'] is List ? d['maintenance'] as List : const []))
        if (r is Map) Map<String, dynamic>.from(r),
    ];
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
    _odo.dispose();
    super.dispose();
  }

  Future<void> _editRule([int? index]) async {
    final r = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _RuleDialog(
          initial: index == null ? const {} : _rules[index],
          odometerKm: double.tryParse(_odo.text.trim())),
    );
    if (r == null) return;
    setState(() {
      if (index == null) {
        _rules.add(r);
      } else {
        _rules[index] = r;
      }
    });
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
                  avatar: const Icon(Icons.directions_car_rounded, size: 18),
                  selected: _type == 'car',
                  onSelected: (_) => setState(() => _type = 'car'),
                ),
                ChoiceChip(
                  label: Text(tr.vehiclesTypeBike),
                  avatar: const Icon(Icons.two_wheeler_rounded, size: 18),
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
                icon: const Icon(Icons.event_rounded, size: 18),
                label: Text(_dateLabel(tr.vehiclesTaxToken, _tax, tr)),
                onPressed: () => _pickDate(_tax, (d) => _tax = d),
              ),
              const SizedBox(height: Gap.sm),
              OutlinedButton.icon(
                icon: const Icon(Icons.event_rounded, size: 18),
                label: Text(_dateLabel(tr.vehiclesFitness, _fitness, tr)),
                onPressed: () => _pickDate(_fitness, (d) => _fitness = d),
              ),
              const SizedBox(height: Gap.sm),
              OutlinedButton.icon(
                icon: const Icon(Icons.event_rounded, size: 18),
                label: Text(_dateLabel(tr.vehiclesInsurance, _insurance, tr)),
                onPressed: () => _pickDate(_insurance, (d) => _insurance = d),
              ),
              const SizedBox(height: Gap.sm),
              OutlinedButton.icon(
                icon: const Icon(Icons.event_rounded, size: 18),
                label: Text(_dateLabel(tr.v100RoutePermit, _permit, tr)),
                onPressed: () => _pickDate(_permit, (d) => _permit = d),
              ),
              Padding(
                padding: const EdgeInsets.only(top: Gap.xs),
                child: Text(tr.v100PapersPushNote,
                    style: AType.bodySmall.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ),
              const SizedBox(height: Gap.lg),
              Text(tr.v100ServiceHeader, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: Gap.sm),
              TextField(
                controller: _odo,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                    labelText: tr.v100OdoLabel,
                    helperText: tr.v100OdoManualHelp,
                    helperMaxLines: 3,
                    border: const OutlineInputBorder()),
              ),
              for (var i = 0; i < _rules.length; i++)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.build_circle_rounded),
                  title: Text('${_rules[i]['name'] ?? ''}',
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(_ruleText(tr, _rules[i]), maxLines: 2),
                  onTap: () => _editRule(i),
                  trailing: IconButton(
                    tooltip: tr.delete,
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: () => setState(() => _rules.removeAt(i)),
                  ),
                ),
              TextButton.icon(
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: _rules.length >= 20 ? null : () => _editRule(),
                icon: const Icon(Icons.add_rounded),
                label: Text(tr.v100ServiceAdd),
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
      if (iso(_permit) != null) 'route_permit_expiry': iso(_permit),
      if (double.tryParse(_odo.text.trim()) != null)
        'odometer_km': double.parse(_odo.text.trim()),
      if (_rules.isNotEmpty) 'maintenance': _rules,
    });
  }

  String _ruleText(AppLocalizations tr, Map<String, dynamic> r) {
    final km = vehInt(r['every_km']) ?? 0;
    final days = vehInt(r['every_days']) ?? 0;
    return [
      if (km > 0) tr.v100EveryKm(vehNumStr(context, km)),
      if (days > 0) tr.v100EveryDays(vehNumStr(context, days)),
    ].join(' · ');
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
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xxl),
      children: [
        // v1-vehicle: Assisto live tracking now works with GT06 / Teltonika
        // trackers — say so honestly and link to it.
        if (FeatureFlags.instance.isOn('vehicle_tracking')) // feature-flags
        Card(
          color: scheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.info_outline_rounded, size: 18, color: scheme.primary),
                    const SizedBox(width: Gap.sm),
                    Expanded(
                      child: Text(tr.vehGuideTrackingNow,
                          style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
                    ),
                  ]),
                  const SizedBox(height: Gap.xs),
                  TextButton.icon(
                    onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const VehicleTrackingScreen())),
                    icon: const Icon(Icons.gps_fixed_rounded),
                    label: Text(tr.vehTrackingTitle),
                  ),
                ]),
          ),
        ),
        const SizedBox(height: Gap.lg),

        // SIM GPS vs Bluetooth tag comparison.
        _header(context, Icons.compare_arrows_rounded, tr.vehiclesCompareTitle),
        const SizedBox(height: Gap.sm),
        _compareCard(
          context,
          icon: Icons.sim_card_rounded,
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
          icon: Icons.bluetooth_rounded,
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
        _header(context, Icons.checklist_rounded, tr.vehiclesChecklistTitle),
        const SizedBox(height: Gap.sm),
        _bullet(context, tr.vehiclesCheckCutoff),
        _bullet(context, tr.vehiclesCheckBackupBattery),
        _bullet(context, tr.vehiclesCheckTamperAlert),
        _bullet(context, tr.vehiclesCheckGt06),
        _bullet(context, tr.vehiclesCheckSimPlan),
        const SizedBox(height: Gap.lg),

        // Installation tips.
        _header(context, Icons.build_rounded, tr.vehiclesInstallTitle),
        const SizedBox(height: Gap.sm),
        _bullet(context, tr.vehiclesInstallHidden),
        _bullet(context, tr.vehiclesInstallPower),
        _bullet(context, tr.vehiclesInstallPro),
        const SizedBox(height: Gap.lg),

        // Prices — honest: no hardcoded numbers, just a live search.
        _header(context, Icons.payments_rounded, tr.vehiclesPriceTitle),
        const SizedBox(height: Gap.sm),
        Text(tr.vehiclesPriceNote,
            style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.sm),
        Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
          FilledButton.tonalIcon(
            onPressed: () => _openSearch(tr.vehiclesPriceQueryGps),
            icon: const Icon(Icons.search_rounded),
            label: Text(tr.vehiclesPriceCheckGps),
          ),
          FilledButton.tonalIcon(
            onPressed: () => _openSearch(tr.vehiclesPriceQueryBt),
            icon: const Icon(Icons.search_rounded),
            label: Text(tr.vehiclesPriceCheckBt),
          ),
        ]),
        const SizedBox(height: Gap.lg),
        Text(tr.vehiclesPriceDisclaimer,
            style: AType.bodySmall.copyWith(fontStyle: FontStyle.italic, color: scheme.onSurfaceVariant)),
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
                  child: Icon(Icons.chevron_right_rounded,
                      size: 15, color: scheme.onSurfaceVariant),
                ),
                Expanded(
                    child: Text(l, style: AType.bodyMedium)),
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
        Icon(Icons.check_circle_outline_rounded, size: 18, color: Brand.success),
        const SizedBox(width: Gap.sm),
        Expanded(
            child: Text(text,
                style: AType.bodyMedium.copyWith(color: scheme.onSurface))),
      ]),
    );
  }
}

/// veh100: one service rule — every N km and/or every N days, with the last
/// time it was done ("done today" fills today + the current odometer).
class _RuleDialog extends StatefulWidget {
  final Map<String, dynamic> initial;
  final double? odometerKm;
  const _RuleDialog({required this.initial, this.odometerKm});

  @override
  State<_RuleDialog> createState() => _RuleDialogState();
}

class _RuleDialogState extends State<_RuleDialog> {
  late final _name = TextEditingController(text: '${widget.initial['name'] ?? ''}');
  late final _km = TextEditingController(text: '${widget.initial['every_km'] ?? ''}');
  late final _days = TextEditingController(text: '${widget.initial['every_days'] ?? ''}');
  late final _lastKm = TextEditingController(text: '${widget.initial['last_km'] ?? ''}');
  DateTime? _lastDate;

  @override
  void initState() {
    super.initState();
    _lastDate = DateTime.tryParse('${widget.initial['last_date'] ?? ''}');
  }

  @override
  void dispose() {
    for (final c in [_name, _km, _days, _lastKm]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final presets = <(String, int, int)>[
      (tr.v100SvcOil, 3000, 120),
      (tr.v100SvcGeneral, 5000, 180),
      (tr.v100SvcTyres, 20000, 0),
      (tr.v100SvcBrakes, 10000, 365),
    ];
    final ok = _name.text.trim().isNotEmpty &&
        ((int.tryParse(_km.text.trim()) ?? 0) > 0 || (int.tryParse(_days.text.trim()) ?? 0) > 0);
    return AlertDialog(
      title: Text(tr.v100ServiceAdd),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Wrap(spacing: Gap.xs, runSpacing: Gap.xs, children: [
            for (final p in presets)
              ActionChip(
                label: Text(p.$1),
                onPressed: () => setState(() {
                  _name.text = p.$1;
                  _km.text = p.$2 > 0 ? '${p.$2}' : '';
                  _days.text = p.$3 > 0 ? '${p.$3}' : '';
                }),
              ),
          ]),
          TextField(controller: _name, maxLength: 40,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(labelText: tr.v100SvcName)),
          TextField(controller: _km, keyboardType: TextInputType.number,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(labelText: tr.v100SvcEveryKm)),
          TextField(controller: _days, keyboardType: TextInputType.number,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(labelText: tr.v100SvcEveryDays)),
          TextField(controller: _lastKm, keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: tr.v100SvcLastKm)),
          const SizedBox(height: Gap.sm),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            icon: const Icon(Icons.event_rounded),
            label: Text(_lastDate == null
                ? tr.v100SvcLastDate
                : DateFormat('d MMM yyyy', Localizations.localeOf(context).languageCode)
                    .format(_lastDate!)),
            onPressed: () async {
              final d = await showDatePicker(
                  context: context,
                  initialDate: _lastDate ?? DateTime.now(),
                  firstDate: DateTime(2000),
                  lastDate: DateTime.now());
              if (d != null) setState(() => _lastDate = d);
            },
          ),
          TextButton(
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => setState(() {
              _lastDate = DateTime.now();
              if (widget.odometerKm != null) {
                _lastKm.text = widget.odometerKm!.round().toString();
              }
            }),
            child: Text(tr.v100SvcDoneToday),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr.cancel)),
        FilledButton(
          onPressed: !ok
              ? null
              : () => Navigator.pop(context, <String, dynamic>{
                    'id': '${widget.initial['id'] ?? 's${DateTime.now().millisecondsSinceEpoch % 100000}'}',
                    'name': _name.text.trim(),
                    if ((int.tryParse(_km.text.trim()) ?? 0) > 0)
                      'every_km': int.parse(_km.text.trim()),
                    if ((int.tryParse(_days.text.trim()) ?? 0) > 0)
                      'every_days': int.parse(_days.text.trim()),
                    if ((int.tryParse(_lastKm.text.trim()) ?? -1) >= 0)
                      'last_km': int.parse(_lastKm.text.trim()),
                    if (_lastDate != null)
                      'last_date': DateFormat('yyyy-MM-dd').format(_lastDate!),
                  }),
          child: Text(tr.save),
        ),
      ],
    );
  }
}
