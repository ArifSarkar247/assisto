import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../vehicle/veh_format.dart';
import '../vehicle/vehicle_api.dart';
import '../widgets/skeleton.dart';
import 'plans_screen.dart';
import 'vehicle_tracker_screen.dart';

/// FLEET DASHBOARD (Business plan): every owned vehicle + vehicles a fleet
/// owner granted you, with today's distance and alerts. The server returns
/// 403 business_only for other plans; we show that honestly with a plan link.
class FleetDashboardScreen extends StatefulWidget {
  const FleetDashboardScreen({super.key});

  @override
  State<FleetDashboardScreen> createState() => _FleetDashboardScreenState();
}

class _FleetDashboardScreenState extends State<FleetDashboardScreen> {
  Map<String, dynamic>? _data;
  bool _loading = true, _error = false, _notBusiness = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
      _notBusiness = false;
    });
    try {
      _data = await context.read<AppState>().api.vehFleet();
    } on ApiException catch (e) {
      if (e.message == 'business_only') {
        _notBusiness = true;
      } else {
        _error = true;
      }
    } catch (_) {
      _error = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    Widget body;
    if (_loading) {
      body = const SkeletonList();
    } else if (_notBusiness) {
      body = StateMessage(
        icon: Icons.local_shipping_outlined,
        title: tr.vehFleetBusinessTitle,
        message: tr.vehErrBusinessOnly,
        action: FilledButton(
          onPressed: () => Navigator.push(
              context, MaterialPageRoute(builder: (_) => const PlansScreen())),
          child: Text(tr.vehSeePlans),
        ),
      );
    } else if (_error || _data == null) {
      body = StateMessage(
        icon: Icons.cloud_off,
        tint: scheme.error,
        title: tr.loadFailed,
        message: tr.vehLoadError,
        action: FilledButton.tonalIcon(
            onPressed: _load, icon: const Icon(Icons.refresh), label: Text(tr.retry)),
      );
    } else {
      final tot = vehMap(_data!['totals']);
      final rows = vehList(_data!['vehicles']);
      body = RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(Gap.md),
          children: [
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: Gap.sm,
              crossAxisSpacing: Gap.sm,
              childAspectRatio: 2.1,
              children: [
                _tile(tr.vehFleetVehicles, vehNumStr(context, vehInt(tot['vehicles']) ?? 0),
                    Icons.directions_car, Brand.blue),
                _tile(tr.vehFleetOnline, vehNumStr(context, vehInt(tot['online']) ?? 0),
                    Icons.wifi_tethering, Brand.success),
                _tile(tr.vehFleetMoving, vehNumStr(context, vehInt(tot['moving']) ?? 0),
                    Icons.speed, Brand.purple),
                _tile(tr.vehFleetKmToday,
                    tr.vehKm(vehNumStr(context, vehNum(tot['km_today']) ?? 0, decimals: 1)),
                    Icons.straighten, Brand.cyan),
              ],
            ),
            const SizedBox(height: Gap.sm),
            if ((vehInt(tot['alerts_today']) ?? 0) > 0)
              Card(
                margin: EdgeInsets.zero,
                color: scheme.errorContainer,
                child: ListTile(
                  leading: Icon(Icons.notifications_active, color: scheme.onErrorContainer),
                  title: Text(tr.vehFleetAlerts(vehNumStr(context, vehInt(tot['alerts_today'])!)),
                      style: TextStyle(color: scheme.onErrorContainer)),
                ),
              ),
            const SizedBox(height: Gap.sm),
            if (rows.isEmpty)
              StateMessage(
                  icon: Icons.gps_not_fixed, title: tr.vehEmptyTitle, message: tr.vehEmptyBody),
            for (final v in rows) _row(tr, scheme, v),
          ],
        ),
      );
    }
    return Scaffold(appBar: AppBar(title: Text(tr.vehFleetTitle)), body: body);
  }

  Widget _tile(String label, String value, IconData icon, Color color) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(children: [
        Icon(icon, color: color),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(value,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                Text(label,
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ]),
        ),
      ]),
    );
  }

  Widget _row(AppLocalizations tr, ColorScheme scheme, Map<String, dynamic> v) {
    final online = v['online'] == true;
    final live = vehMap(v['live']);
    final name = '${v['name'] ?? ''}'.trim();
    final status = !online
        ? tr.vehOfflineSince(vehAgo(context, tr, vehDate(v['last_seen_at'])))
        : (live['moving'] == true
            ? tr.vehMovingAt(vehNumStr(context, vehNum(live['speed_kmh']) ?? 0))
            : tr.vehParked);
    return Card(
      margin: const EdgeInsets.only(top: Gap.sm),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: (online ? Brand.success : scheme.outline).withValues(alpha: 0.16),
          child: Icon(Icons.directions_car, color: online ? Brand.success : scheme.outline),
        ),
        title: Text(name.isEmpty ? tr.vehUnnamedTracker : name,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '$status  ·  ${tr.vehKm(vehNumStr(context, vehNum(v['km_today']) ?? 0, decimals: 1))}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: (vehInt(v['alerts_today']) ?? 0) > 0
            ? Badge(
                label: Text(vehNumStr(context, vehInt(v['alerts_today'])!)),
                child: const Icon(Icons.notifications_outlined))
            : const Icon(Icons.chevron_right),
        onTap: v['state'] == 'paired'
            ? () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => VehicleTrackerScreen(trackerId: v['id'] as int)))
            : null,
      ),
    );
  }
}
