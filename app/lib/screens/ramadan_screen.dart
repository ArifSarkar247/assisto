import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:geolocator/geolocator.dart';
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../widgets/life_eid_card.dart';

/// Ramadan mode (module-5 "Life"). Benchmarked vs a SAFE subset of Muslim Pro.
///
///   - Sehri (suhoor) & Iftar times computed FROM LOCATION by the backend
///     using a standard astronomical calc (NOAA solar position; Karachi 18/18
///     angle set by default). The UI notes local committee times may differ.
///   - Sehri wake-alarm + iftar heads-up offsets (the native alarm is a
///     platform hook; wake-for-sehri IVR CALL is key-gated and shown as such).
///   - Zakat -> reuses Finance zakat (single source of truth).
///   - Eid greeting + salami card DRAFTS (editable, never auto-sent).
///
/// Mirrors core.logic.ramadan.
class RamadanScreen extends StatefulWidget {
  const RamadanScreen({super.key});
  @override
  State<RamadanScreen> createState() => _RamadanScreenState();
}

class _RamadanScreenState extends State<RamadanScreen> {
  bool _loading = false;
  Map<String, dynamic>? _times;
  String? _error;

  int _sehriPrewake = 60;
  int _iftarPrealert = 10;

  // Wake-for-sehri IVR is key-gated (telephony/partner).
  static const bool _wakeIvrAvailable = false;

  @override
  void initState() {
    super.initState();
    _loadTimes();
  }

  Future<Position?> _position() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return null;
      }
      return await Geolocator.getCurrentPosition();
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadTimes() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final pos = await _position();
    if (pos == null) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'location';
        });
      }
      return;
    }
    try {
      final r = await context.read<AppState>().api.getJson(
          '/ramadan/times?lat=${pos.latitude}&lon=${pos.longitude}');
      if (mounted) setState(() => _times = r);
    } catch (_) {
      if (mounted) setState(() => _error = 'fetch');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // Mirror ramadan._shift_hhmm for the offset previews.
  String _shift(String hhmm, int deltaMin) {
    final parts = hhmm.split(':');
    if (parts.length != 2) return hhmm;
    final total = (int.parse(parts[0]) * 60 + int.parse(parts[1]) + deltaMin) %
        (24 * 60);
    final norm = (total + 24 * 60) % (24 * 60);
    return '${(norm ~/ 60).toString().padLeft(2, '0')}:'
        '${(norm % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.ramadanTitle), actions: [
        IconButton(
          tooltip: t.ramadanRefresh,
          icon: const Icon(Icons.my_location),
          onPressed: _loadTimes,
        ),
      ]),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(Gap.md),
              children: [
                if (_error == 'location') _errorBox(t.ramadanLocationNeeded),
                if (_error == 'fetch') _errorBox(t.ramadanFetchFailed),
                if (_times != null) ..._timesSection(t),
                const SizedBox(height: Gap.lg),
                _zakatTile(t),
                const Divider(height: Gap.xl),
                _sectionTitle(t.ramadanEidSection),
                const SizedBox(height: Gap.sm),
                const LifeEidCard(),
              ],
            ),
    );
  }

  List<Widget> _timesSection(AppLocalizations t) {
    final tm = _times!;
    final sehri = '${tm['sehri_end'] ?? '--:--'}';
    final iftar = '${tm['iftar'] ?? '--:--'}';
    return [
      Row(children: [
        Expanded(
          child: _timeCard(
            icon: Icons.nightlight_round,
            label: t.ramadanSehri,
            time: sehri,
            color: Brand.purple,
          ),
        ),
        const SizedBox(width: Gap.md),
        Expanded(
          child: _timeCard(
            icon: Icons.wb_twilight,
            label: t.ramadanIftar,
            time: iftar,
            color: Brand.warning,
          ),
        ),
      ]),
      const SizedBox(height: Gap.sm),
      Text(t.ramadanMethodNote('${tm['method'] ?? 'karachi'}'),
          style: const TextStyle(fontSize: 11, color: Colors.grey)),
      const SizedBox(height: Gap.md),

      // other prayer times
      _prayerRow(t.ramadanFajr, '${tm['fajr'] ?? '--:--'}'),
      _prayerRow(t.ramadanDhuhr, '${tm['dhuhr'] ?? '--:--'}'),
      _prayerRow(t.ramadanAsr, '${tm['asr'] ?? '--:--'}'),
      _prayerRow(t.ramadanMaghrib, '${tm['maghrib'] ?? '--:--'}'),
      _prayerRow(t.ramadanIsha, '${tm['isha'] ?? '--:--'}'),
      const Divider(height: Gap.xl),

      // alarms
      _sectionTitle(t.ramadanAlarmsSection),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.alarm),
        title: Text(t.ramadanSehriWake),
        subtitle: Text(t.ramadanSehriWakeValue(_sehriPrewake, _shift(sehri, -_sehriPrewake))),
      ),
      Slider(
        value: _sehriPrewake.toDouble(),
        min: 10,
        max: 120,
        divisions: 11,
        label: '$_sehriPrewake',
        onChanged: (v) => setState(() => _sehriPrewake = v.round()),
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.notifications_active_outlined),
        title: Text(t.ramadanIftarAlert),
        subtitle: Text(t.ramadanIftarAlertValue(_iftarPrealert, _shift(iftar, -_iftarPrealert))),
      ),
      Slider(
        value: _iftarPrealert.toDouble(),
        min: 0,
        max: 30,
        divisions: 6,
        label: '$_iftarPrealert',
        onChanged: (v) => setState(() => _iftarPrealert = v.round()),
      ),
      const SizedBox(height: Gap.sm),
      // wake-for-sehri IVR (key-gated)
      if (!_wakeIvrAvailable)
        Container(
          padding: const EdgeInsets.all(Gap.sm),
          decoration: BoxDecoration(
            color: Colors.grey.withOpacity(0.10),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(children: [
            const Icon(Icons.phone_in_talk_outlined, size: 16, color: Colors.grey),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(t.ramadanWakeCallComing,
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ),
          ]),
        ),
    ];
  }

  Widget _timeCard({
    required IconData icon,
    required String label,
    required String time,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(children: [
        Icon(icon, color: color, size: 28),
        const SizedBox(height: Gap.xs),
        Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
        const SizedBox(height: 2),
        Text(time,
            style: TextStyle(
                color: color, fontSize: 26, fontWeight: FontWeight.bold)),
      ]),
    );
  }

  Widget _prayerRow(String label, String time) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(label),
        Text(time, style: const TextStyle(fontWeight: FontWeight.w600)),
      ]),
    );
  }

  Widget _zakatTile(AppLocalizations t) {
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: const Icon(Icons.volunteer_activism_outlined, color: Brand.blue),
        title: Text(t.ramadanZakat),
        subtitle: Text(t.ramadanZakatSubtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: () {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(t.ramadanZakatOpenFinance)));
        },
      ),
    );
  }

  Widget _sectionTitle(String s) =>
      Text(s, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15));

  Widget _errorBox(String msg) {
    return Container(
      margin: const EdgeInsets.only(bottom: Gap.md),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: Brand.warning.withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(children: [
        const Icon(Icons.info_outline, size: 18, color: Color(0xFF8A6D00)),
        const SizedBox(width: Gap.sm),
        Expanded(child: Text(msg, style: const TextStyle(color: Color(0xFF8A6D00)))),
      ]),
    );
  }
}
