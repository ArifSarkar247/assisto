import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../vehicle/elm327.dart';
import '../vehicle/veh_format.dart';
import '../vehicle/vehicle_api.dart';

/// OBD-II health: (a) whatever a 4G OBD tracker reported through our server,
/// (b) a Bluetooth ELM327 dongle read directly by this phone.
///
/// Bluetooth is LAZY: the permission prompt and the native channel are only
/// touched when the user taps "Read dongle" here — never at app launch.
/// Honest limits shown on screen: many cars don't expose fuel level; only
/// classic-Bluetooth dongles already paired in phone settings; reading codes
/// never clears them.
class VehicleObdScreen extends StatefulWidget {
  final int? trackerId;

  /// Screenshot/test hook: show this reading without touching Bluetooth.
  final ObdReading? previewReading;
  const VehicleObdScreen({super.key, this.trackerId, this.previewReading});

  @override
  State<VehicleObdScreen> createState() => _VehicleObdScreenState();
}

class _VehicleObdScreenState extends State<VehicleObdScreen> {
  Map<String, dynamic>? _tracker; // server snapshot
  bool _loadingTracker = false;

  ObdReading? _bt;
  List<Map<String, dynamic>> _btDtc = [];
  bool _btBusy = false;
  String? _btMsg;

  @override
  void initState() {
    super.initState();
    if (widget.trackerId != null) _loadTracker();
    if (widget.previewReading != null) {
      _bt = widget.previewReading;
      WidgetsBinding.instance.addPostFrameCallback((_) => _decode(_bt!.dtcs));
    }
  }

  Future<void> _loadTracker() async {
    setState(() => _loadingTracker = true);
    try {
      _tracker = await context.read<AppState>().api.vehObd(widget.trackerId!);
    } catch (_) {
      _tracker = null;
    }
    if (mounted) setState(() => _loadingTracker = false);
  }

  Future<void> _decode(List<String> codes) async {
    if (codes.isEmpty) return;
    try {
      final r = await context.read<AppState>().api.vehObdDecode(codes);
      if (mounted) setState(() => _btDtc = vehList(r['dtc']));
    } catch (_) {
      if (mounted) {
        setState(() => _btDtc = [
              for (final c in codes) {'code': c, 'known': false}
            ]);
      }
    }
  }

  Future<void> _readDongle() async {
    final tr = AppLocalizations.of(context);
    setState(() {
      _btBusy = true;
      _btMsg = null;
    });
    try {
      var st = await ObdBluetooth.state();
      if (st == ObdBtState.noPermission) {
        try {
          await Permission.bluetoothConnect.request();
        } catch (_) {}
        st = await ObdBluetooth.state();
      }
      if (st != ObdBtState.ready) {
        setState(() => _btMsg = switch (st) {
              ObdBtState.bluetoothOff => tr.vehBtOff,
              ObdBtState.noPermission => tr.vehBtNoPermission,
              _ => tr.vehBtUnavailable,
            });
        return;
      }
      final devices = await ObdBluetooth.bonded();
      if (!mounted) return;
      if (devices.isEmpty) {
        setState(() => _btMsg = tr.vehBtNoPaired);
        return;
      }
      final pick = await showModalBottomSheet<Map<String, String>>(
        context: context,
        builder: (ctx) => SafeArea(
          child: ListView(shrinkWrap: true, children: [
            ListTile(title: Text(tr.vehBtPick, style: Theme.of(ctx).textTheme.titleMedium)),
            for (final d in devices)
              ListTile(
                leading: const Icon(Icons.bluetooth),
                title: Text(d['name']!.isEmpty ? d['address']! : d['name']!,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(d['address']!),
                onTap: () => Navigator.pop(ctx, d),
              ),
          ]),
        ),
      );
      if (pick == null) return;
      if (!await ObdBluetooth.connect(pick['address']!)) {
        setState(() => _btMsg = tr.vehBtConnectFailed);
        return;
      }
      final r = await ObdBluetooth.readAll();
      await ObdBluetooth.disconnect();
      if (r == null) {
        setState(() => _btMsg = tr.vehBtNoAnswer);
        return;
      }
      setState(() => _bt = r);
      await _decode(r.dtcs);
    } catch (_) {
      if (mounted) setState(() => _btMsg = tr.vehBtUnavailable);
    } finally {
      if (mounted) setState(() => _btBusy = false);
    }
  }

  Widget _metric(String label, String? value, IconData icon) {
    final scheme = Theme.of(context).colorScheme;
    final tr = AppLocalizations.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: scheme.primaryContainer,
        child: Icon(icon, color: scheme.onPrimaryContainer),
      ),
      title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Text(value ?? tr.vehNotSupported,
          style: TextStyle(
              fontWeight: FontWeight.w700,
              color: value == null ? scheme.onSurfaceVariant : scheme.onSurface)),
    );
  }

  Widget _dtcList(List<Map<String, dynamic>> dtc) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final bn = vehIsBn(context);
    if (dtc.isEmpty) {
      return ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.check_circle, color: Brand.success),
        title: Text(tr.vehNoDtc),
      );
    }
    return Column(children: [
      for (final d in dtc)
        Card(
          margin: const EdgeInsets.only(top: Gap.xs),
          color: '${d['severity']}' == 'high'
              ? scheme.errorContainer
              : scheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${d['code']}',
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              if (d['bn'] != null || d['en'] != null) ...[
                const SizedBox(height: 2),
                Text('${bn ? d['bn'] : d['en']}', style: const TextStyle(height: 1.35)),
                const SizedBox(height: 4),
                Text('${bn ? d['advice_bn'] : d['advice_en']}',
                    style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
              ],
            ]),
          ),
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final obd = vehMap(_tracker?['obd']);
    final bt = _bt;
    return Scaffold(
      appBar: AppBar(title: Text(tr.vehObdTitle)),
      body: ListView(
        padding: const EdgeInsets.all(Gap.md),
        children: [
          if (widget.trackerId != null)
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(Gap.md),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr.vehObdFromTracker, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: Gap.xs),
                  if (_loadingTracker)
                    const LinearProgressIndicator()
                  else if (_tracker == null || _tracker!['available'] != true)
                    Text(tr.vehObdTrackerNone,
                        style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35))
                  else ...[
                    _metric(tr.vehCoolant,
                        obd['coolant_temp_c'] == null
                            ? null
                            : tr.vehCelsius(vehNumStr(context, vehNum(obd['coolant_temp_c'])!)),
                        Icons.thermostat),
                    _metric(tr.vehBattery,
                        vehNum(_tracker!['battery_v']) == null
                            ? null
                            : tr.vehVolts(vehNumStr(context, vehNum(_tracker!['battery_v'])!,
                                decimals: 1)),
                        Icons.battery_charging_full),
                    _metric(tr.vehFuel,
                        obd['fuel_level_pct'] == null
                            ? null
                            : tr.vehPercent(vehNumStr(context, vehNum(obd['fuel_level_pct'])!)),
                        Icons.local_gas_station),
                    _metric(tr.vehRpm,
                        obd['rpm'] == null ? null : vehNumStr(context, vehNum(obd['rpm'])!),
                        Icons.speed),
                    const SizedBox(height: Gap.xs),
                    Text(tr.vehDtcTitle, style: Theme.of(context).textTheme.labelLarge),
                    _dtcList(vehList(_tracker!['dtc'])),
                  ],
                ]),
              ),
            ),
          if (widget.trackerId != null) const SizedBox(height: Gap.md),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(tr.vehObdBtTitle, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: Gap.xs),
                Text(tr.vehObdBtBody,
                    style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35)),
                const SizedBox(height: Gap.sm),
                FilledButton.icon(
                  onPressed: _btBusy ? null : _readDongle,
                  icon: _btBusy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.bluetooth_searching),
                  label: Text(_btBusy ? tr.vehBtReading : tr.vehBtRead),
                ),
                if (_btMsg != null) ...[
                  const SizedBox(height: Gap.sm),
                  Text(_btMsg!, style: TextStyle(color: scheme.error)),
                ],
                if (bt != null) ...[
                  const SizedBox(height: Gap.sm),
                  _metric(
                      tr.vehCoolant,
                      bt.coolantC == null
                          ? null
                          : tr.vehCelsius(vehNumStr(context, bt.coolantC!)),
                      Icons.thermostat),
                  _metric(
                      tr.vehBattery,
                      bt.batteryV == null
                          ? null
                          : tr.vehVolts(vehNumStr(context, bt.batteryV!, decimals: 1)),
                      Icons.battery_charging_full),
                  _metric(
                      tr.vehFuel,
                      bt.fuelPct == null
                          ? null
                          : tr.vehPercent(vehNumStr(context, bt.fuelPct!)),
                      Icons.local_gas_station),
                  _metric(tr.vehRpm, bt.rpm == null ? null : vehNumStr(context, bt.rpm!),
                      Icons.speed),
                  const SizedBox(height: Gap.xs),
                  Text(tr.vehDtcTitle, style: Theme.of(context).textTheme.labelLarge),
                  _dtcList(_btDtc.isNotEmpty || bt.dtcs.isEmpty
                      ? _btDtc
                      : [for (final c in bt.dtcs) {'code': c}]),
                ],
                const SizedBox(height: Gap.sm),
                Text(tr.vehObdHonest,
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant, height: 1.35)),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}
