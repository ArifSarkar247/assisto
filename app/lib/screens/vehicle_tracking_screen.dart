import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../vehicle/veh_format.dart';
import '../vehicle/vehicle_api.dart';
import '../vehicle/veh_setup.dart'; // veh100
import '../widgets/skeleton.dart';
import 'car_mode_screen.dart';
import 'fleet_dashboard_screen.dart';
import 'vehicle_tracker_screen.dart';
import 'package:assisto/widgets/app_sheet.dart';
import '../services/error_kind.dart' show honestFailText; // qa2

/// LIVE TRACKING — the list of paired hardware trackers (v1-vehicle).
///
/// Honest scope: live tracking needs a GPS tracker (Concox GT06 family or
/// Teltonika FMxxx) with its own SIM, pointed at track.lifeassisto.com:5023.
/// A phone or head unit alone cannot follow a parked car; we say so up front.
class VehicleTrackingScreen extends StatefulWidget {
  const VehicleTrackingScreen({super.key});

  @override
  State<VehicleTrackingScreen> createState() => _VehicleTrackingScreenState();
}

class _VehicleTrackingScreenState extends State<VehicleTrackingScreen> {
  List<Map<String, dynamic>> _trackers = [];
  int _monthCredits = 0;
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
    try {
      final r = await context.read<AppState>().api.vehTrackers();
      _trackers = vehList(r['trackers']);
      _monthCredits = vehInt(r['month_credits']) ?? 0;
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _pair() async {
    final ok = await showAppSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => PairTrackerSheet(monthCredits: _monthCredits),
    );
    if (ok == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr.vehTrackingTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: tr.vehCarModeTitle,
            icon: const Icon(Icons.drive_eta_rounded),
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const CarModeScreen())),
          ),
          IconButton(
            tooltip: tr.vehFleetTitle,
            icon: const Icon(Icons.local_shipping_rounded),
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const FleetDashboardScreen())),
          ),
        ],
      ),
      floatingActionButton: _loading || _error
          ? null
          : FloatingActionButton.extended(
              onPressed: _pair,
              icon: const Icon(Icons.add_link_rounded),
              label: Text(tr.vehPairCta),
            ),
      body: _body(tr, scheme),
    );
  }

  Widget _body(AppLocalizations tr, ColorScheme scheme) {
    if (_loading) return const SkeletonList();
    if (_error) {
      return StateMessage(
        icon: Icons.cloud_off_rounded,
        tint: scheme.error,
        title: tr.loadFailed,
        message: honestFailText(tr, _failCause, otherwise: tr.vehLoadError),
        action: FilledButton.tonalIcon(
            onPressed: _load, icon: const Icon(Icons.refresh_rounded), label: Text(tr.retry)),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
        children: [
          _HonestCard(),
          const SizedBox(height: Gap.md),
          if (_trackers.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Gap.xl),
              child: StateMessage(
                icon: Icons.gps_not_fixed_rounded,
                title: tr.vehEmptyTitle,
                message: tr.vehEmptyBody,
              ),
            ),
          for (final t in _trackers) ...[
            _TrackerCard(t: t, onChanged: _load),
            const SizedBox(height: Gap.sm),
          ],
        ],
      ),
    );
  }
}

class _HonestCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.info_outline_rounded, color: scheme.onSecondaryContainer),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(tr.vehHonestHardware,
                style: TextStyle(color: scheme.onSecondaryContainer, height: 1.35)),
          ),
        ]),
      ),
    );
  }
}

class _TrackerCard extends StatelessWidget {
  final Map<String, dynamic> t;
  final VoidCallback onChanged;
  const _TrackerCard({required this.t, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final state = '${t['state']}';
    final online = t['online'] == true;
    final live = vehMap(t['live']);
    final name = '${t['name'] ?? ''}'.trim();
    final speed = vehNum(live['speed_kmh']);
    String status;
    Color color;
    switch (state) {
      case 'pending':
        status = tr.vehStatePending;
        color = Brand.warning;
        break;
      case 'expired':
        status = tr.vehStateExpired;
        color = scheme.error;
        break;
      case 'disabled':
        status = '${t['disabled_reason']}' == 'no_credits'
            ? tr.vehStateUnpaid
            : tr.vehStateOff;
        color = scheme.onSurfaceVariant;
        break;
      default:
        if (!online) {
          status = tr.vehOfflineSince(vehAgo(context, tr, vehDate(t['last_seen_at'])));
          color = scheme.onSurfaceVariant;
        } else if (live['moving'] == true && speed != null) {
          status = tr.vehMovingAt(vehNumStr(context, speed));
          color = Brand.success;
        } else {
          status = tr.vehParked;
          color = Brand.blue;
        }
    }
    final shared = t['is_owner'] != true;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: state == 'paired'
            ? () async {
                await Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => VehicleTrackerScreen(trackerId: t['id'] as int)));
                onChanged();
              }
            : null,
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              CircleAvatar(
                backgroundColor: color.withValues(alpha: 0.15),
                child: Icon(Icons.gps_fixed_rounded, color: color),
              ),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(name.isEmpty ? tr.vehUnnamedTracker : name,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  Text(status,
                      style: AType.bodyMedium.copyWith(color: color, fontWeight: FontWeight.w600),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                ]),
              ),
              if (shared)
                Chip(
                  label: Text(tr.vehSharedWithYou, maxLines: 1),
                  visualDensity: VisualDensity.compact,
                ),
              if (state == 'paired') const Icon(Icons.chevron_right_rounded),
            ]),
            if (state == 'pending' || state == 'expired') ...[
              const SizedBox(height: Gap.sm),
              Text(
                state == 'pending'
                    ? tr.vehPendingBody(vehTime(context, vehDate(t['pair_expires_at'])))
                    : tr.vehExpiredBody,
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}

/// Bottom sheet: pair a tracker by IMEI (+ optional My Vehicles record).
class PairTrackerSheet extends StatefulWidget {
  final int monthCredits;
  const PairTrackerSheet({super.key, required this.monthCredits});

  @override
  State<PairTrackerSheet> createState() => _PairTrackerSheetState();
}

class _PairTrackerSheetState extends State<PairTrackerSheet> {
  final _imei = TextEditingController();
  final _name = TextEditingController();
  String _protocol = 'auto';
  String _brand = 'auto'; // veh100: brand -> protocol (kVehBrands)
  String _operator = 'gp';
  final _sim = TextEditingController();
  int? _vehicleId;
  List<Map<String, dynamic>> _vehicles = [];
  bool _busy = false;
  String? _err;
  Map<String, dynamic>? _done;

  @override
  void initState() {
    super.initState();
    _loadVehicles();
  }

  Future<void> _loadVehicles() async {
    try {
      final v = await context.read<AppState>().api.listItems('vehicle/records');
      if (mounted) setState(() => _vehicles = v);
    } catch (_) {}
  }

  Future<void> _submit() async {
    final tr = AppLocalizations.of(context);
    final imei = _imei.text.replaceAll(RegExp(r'\D'), '');
    // H02 (Sinotrack ST-901 family) trackers use a 10-digit device id.
    final ok = _protocol == 'h02' ? (imei.length >= 10 && imei.length <= 15) : imei.length == 15;
    if (!ok) {
      setState(() => _err = _protocol == 'h02' ? tr.e2eVehBadDeviceId : tr.vehErrBadImei);
      return;
    }
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      final r = await context.read<AppState>().api.vehPair(imei,
          name: _name.text.trim(), vehicleRecordId: _vehicleId, protocol: _protocol);
      // veh100: remember the tracker SIM so the setup screen can open the SMS
      // app with each command filled in (stays on this phone only).
      if (mounted) setState(() => _done = r);
    } catch (e) {
      if (mounted) setState(() => _err = vehReasonText(tr, e));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    // insets (owner 28 Oct): the "Start pairing" button sat under the phone's
    // navigation bar. showAppSheet keeps the sheet above the bar / keyboard and
    // AppSheetBody pins the button while the form scrolls.
    if (_done != null) {
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.lg),
        child: VehSetupView(
          tracker: vehMap(_done!['tracker']),
          brand: _brand,
          operator: _operator,
          simNumber: _sim.text.trim(),
          onClose: () => Navigator.pop(context, true),
        ),
      );
    }
    return AppSheetBody(
      child: _form(tr, scheme),
      primary: FilledButton.icon(
        key: const ValueKey('veh-pair-submit'),
        onPressed: _busy ? null : _submit,
        icon: _busy
            ? const SizedBox(
                width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.link_rounded),
        label: Text(tr.vehPairSubmit),
      ),
    );
  }

  Widget _form(AppLocalizations tr, ColorScheme scheme) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(tr.vehPairTitle, style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: Gap.xs),
      Text(tr.vehPairBody, style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35)),
      const SizedBox(height: Gap.md),
      TextField(
        controller: _imei,
        keyboardType: TextInputType.number,
        maxLength: 15,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(
            labelText: tr.vehImeiLabel,
            helperText: _protocol == 'h02' ? tr.e2eVehH02Help : tr.vehImeiHelp,
            helperMaxLines: 2),
      ),
      const SizedBox(height: Gap.sm),
      TextField(
        controller: _name,
        maxLength: 40,
        decoration: InputDecoration(labelText: tr.vehNameLabel),
      ),
      if (_vehicles.isNotEmpty) ...[
        const SizedBox(height: Gap.sm),
        DropdownButtonFormField<int?>(
          initialValue: _vehicleId,
          isExpanded: true,
          decoration: InputDecoration(labelText: tr.vehLinkVehicle),
          items: [
            DropdownMenuItem<int?>(value: null, child: Text(tr.vehLinkNone)),
            for (final v in _vehicles)
              DropdownMenuItem<int?>(
                value: v['id'] as int?,
                child: Text(
                  '${vehMap(v['data'])['name'] ?? vehMap(v['data'])['registration_no'] ?? v['id']}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (v) => setState(() => _vehicleId = v),
        ),
      ],
      const SizedBox(height: Gap.md),
      // veh100: pick the BRAND printed on the box (the protocol follows);
      // chips wrap at 400 dp / large font (48 dp targets).
      Text(tr.v100BrandLabel, style: Theme.of(context).textTheme.labelLarge),
      const SizedBox(height: Gap.xs),
      Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
        for (final b in kVehBrands)
          ChoiceChip(
            key: ValueKey('veh-brand-${b.$1}'),
            materialTapTargetSize: MaterialTapTargetSize.padded,
            label: Text(vehBrandLabel(tr, b.$1)),
            selected: _brand == b.$1,
            onSelected: (_) => setState(() {
              _brand = b.$1;
              _protocol = b.$2;
            }),
          ),
      ]),
      const SizedBox(height: Gap.sm),
      Text(tr.v100OperatorLabel, style: Theme.of(context).textTheme.labelLarge),
      const SizedBox(height: Gap.xs),
      Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
        for (final o in kVehOperators)
          ChoiceChip(
            materialTapTargetSize: MaterialTapTargetSize.padded,
            label: Text(vehOperatorLabel(o)),
            selected: _operator == o,
            onSelected: (_) => setState(() => _operator = o),
          ),
      ]),
      const SizedBox(height: Gap.sm),
      TextField(
        controller: _sim,
        keyboardType: TextInputType.phone,
        maxLength: 14,
        decoration: InputDecoration(
            labelText: tr.v100SimLabel, helperText: tr.v100SimHelp, helperMaxLines: 3),
      ),
      const SizedBox(height: Gap.md),
      Text(tr.vehMonthlyCost(vehNumStr(context, widget.monthCredits)),
          style: TextStyle(color: scheme.onSurfaceVariant)),
      if (_err != null) ...[
        const SizedBox(height: Gap.sm),
        Text(_err!, style: TextStyle(color: scheme.error, fontWeight: FontWeight.w600)),
      ],
    ]);
  }

}
