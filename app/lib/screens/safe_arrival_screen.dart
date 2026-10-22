import '../l10n/app_localizations.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../theme.dart';
import 'package:provider/provider.dart';
import 'package:geolocator/geolocator.dart';
import 'package:share_plus/share_plus.dart';
import '../state.dart';
import '../widgets/arrival_model.dart';
import '../widgets/arrival_target_card.dart';
import '../widgets/arrival_setup_sheet.dart';
import '../widgets/arrival_history_tile.dart';
import '../widgets/scam_safety_api.dart';
import '../widgets/journey_api.dart';

/// Safe-arrival / "I've arrived" check-in — ADVANCED (SPEC v2.1 §21).
///
/// Concept: the user says "I'll reach X by TIME" and picks who to alert. If
/// they don't tap "I've arrived" by then (+grace), the chosen family
/// is alerted AND the last known location is shared — all REUSING the existing
/// Safe Journey / family-alert backend (no duplicate audience, PIN, or alert
/// path). Advanced extras over the GOOD inline card:
///   - who-to-alert selection (circle/emergency contacts)
///   - LIVE per-second countdown + pre-arrival reminder nudge
///   - escalation on miss: family alert + share last location
///   - recurring daily-commute ROUTINE ("alert if not home by 9pm")
///   - women's NIGHT-SAFETY framing (tighter grace at night)
///   - DURESS-aware arrival (confirm with duress PIN -> looks normal, silently
///     alerts) reusing journey SOS
///   - history, honest empty / loading / offline states
///
/// Status / countdown / grace math mirror backend/core/logic/safety.py via
/// arrival_model so the UI stays correct offline.
class SafeArrivalScreen extends StatefulWidget {
  const SafeArrivalScreen({super.key});
  @override
  State<SafeArrivalScreen> createState() => _SafeArrivalScreenState();
}

class _SafeArrivalScreenState extends State<SafeArrivalScreen> {
  // active check-in (mirrors keys the GOOD card already persisted)
  String? _place;
  DateTime? _eta;
  Set<int> _alertIds = {};
  bool _nightMode = false;

  bool _hasDuress = false;
  List<Map<String, dynamic>> _contacts = [];
  List<Map<String, dynamic>> _routines = [];
  List<Map<String, dynamic>> _history = [];

  bool _loading = true;
  bool _offline = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final place = await Settings.getString('safety_checkin_place');
    final eta = await Settings.getString('safety_checkin_eta');
    _place = (place != null && place.isNotEmpty) ? place : null;
    _eta = (eta != null && eta.isNotEmpty) ? DateTime.tryParse(eta) : null;
    _nightMode = await Settings.getBool('arrival_night_mode', false);
    _hasDuress = await Settings.getBool('journey_has_duress', false);
    _alertIds = _decodeIds(await Settings.getString('arrival_alert_ids'));
    _history = _decodeList(await Settings.getString('arrival_history'));
    // contacts + routines come from the server — degrade to offline cleanly.
    try {
      final c = await context.read<AppState>().api.getEmergency();
      _contacts = ((c['contacts'] ?? []) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      _offline = true;
    }
    try {
      _routines = await context.read<AppState>().api.journeyRoutines();
    } catch (_) {
      _offline = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  Set<int> _decodeIds(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      return (jsonDecode(raw) as List).map((e) => (e as num).toInt()).toSet();
    } catch (_) {
      return {};
    }
  }

  List<Map<String, dynamic>> _decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  // ---- set / edit a check-in -------------------------------------------
  Future<void> _setCheckin() async {
    final result = await showModalBottomSheet<ArrivalSetupResult>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ArrivalSetupSheet(
        place: _place,
        eta: _eta,
        contacts: _contacts,
        selectedIds: _alertIds,
        nightMode: _nightMode,
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      _place = result.place;
      _eta = result.eta;
      _alertIds = result.alertIds.toSet();
      _nightMode = result.nightMode;
    });
    await Settings.setString('safety_checkin_place', _place ?? '');
    await Settings.setString('safety_checkin_eta', _eta!.toIso8601String());
    await Settings.setBool('arrival_night_mode', _nightMode);
    await Settings.setString('arrival_alert_ids', jsonEncode(_alertIds.toList()));
    // REUSE the existing check-in endpoint so the family poll detects overdue.
    try {
      await context.read<AppState>().api.safetyCheckinStart(
          place: _place, etaIso: _eta!.toIso8601String());
    } catch (_) {
      // q1-seams: the family poll only sees a SERVER check-in — say so instead
      // of a silent local-only check-in (same copy as safety_screen).
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context).realityCheckinNotSent)));
      }
    }
  }

  // ---- arrived (plain) -------------------------------------------------
  Future<void> _markArrived({bool duress = false}) async {
    final eta = _eta;
    if (eta != null) {
      _history.insert(0, {
        'place': _place ?? '',
        'eta': eta.toIso8601String(),
        'arrived': true,
      });
      if (_history.length > 30) _history = _history.sublist(0, 30);
      await Settings.setString('arrival_history', jsonEncode(_history));
    }
    setState(() {
      _place = null;
      _eta = null;
    });
    await Settings.setString('safety_checkin_place', '');
    await Settings.setString('safety_checkin_eta', '');
    try {
      await context.read<AppState>().api.safetyCheckinArrived();
    } catch (_) {
      // m2-reality: never a false "arrived" — the server may still alert
      // family. (Duress keeps its normal-looking cover screen.)
      if (mounted && !duress) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context).realityArrivedNotSent)));
      }
      if (!duress) return;
    }
    // DURESS: the screen looks like a normal arrival, but a SILENT SOS fires so
    // family is alerted (reuses journeySos(silent:true) — identical to the
    // journey duress path). We never reveal this on-screen.
    if (duress) {
      // q1-seams: one silent attempt used to be the only one. The cover screen
      // must stay normal, so retry quietly a few times before giving up.
      final api = context.read<AppState>().api;
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          await api.journeySos(silent: true);
          break;
        } catch (_) {
          if (attempt < 2) {
            await Future<void>.delayed(Duration(seconds: 2 * (attempt + 1)));
          }
        }
      }
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).aArrivedDone)));
    }
  }

  // ---- share last location (used on overdue / escalation) --------------
  Future<void> _shareLastLocation() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) return;
      final pos = await Geolocator.getCurrentPosition();
      final link = 'https://maps.google.com/?q=${pos.latitude},${pos.longitude}';
      await Share.share(link);
    } catch (_) {}
  }

  // ---- recurring routine ("alert if not home by 9pm") ------------------
  Future<void> _addRoutine() async {
    TimeOfDay time = const TimeOfDay(hour: 21, minute: 0);
    final days = <String>{'sun', 'mon', 'tue', 'wed', 'thu'};
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
            title: Text(AppLocalizations.of(context).aRoutineAdd),
            content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.schedule),
                  label: Text('${AppLocalizations.of(context).aRoutineHomeBy}: ${time.format(ctx)}'),
                  onPressed: () async {
                    final p = await showTimePicker(context: ctx, initialTime: time);
                    if (p != null) setD(() => time = p);
                  },
                ),
                const SizedBox(height: 10),
                Text(AppLocalizations.of(context).aRoutineDays,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                Wrap(spacing: 6, children: List.generate(7, (i) {
                  final code = kRoutineDayCodes[i];
                  return FilterChip(
                    label: Text(arrivalLabel(context, kRoutineDayLabelKeys[i])),
                    selected: days.contains(code),
                    onSelected: (v) => setD(() =>
                        v ? days.add(code) : days.remove(code)),
                  );
                })),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(AppLocalizations.of(context).aCancel)),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(AppLocalizations.of(context).aSave)),
            ],
          )),
    );
    if (ok != true || !mounted) return;
    final hhmm = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    final routine = {
      'days': days.toList(),
      'time': hhmm,
      'destination': {'name': AppLocalizations.of(context).aRoutineHomeBy},
      'watcher_ids': _alertIds.toList(),
      'enabled': true,
    };
    setState(() => _routines = [..._routines, routine]);
    try {
      await context.read<AppState>().api.saveJourneyRoutine(routine);
    } catch (_) {
      // q1-seams: an optimistic routine that never reached the server would
      // never alert anyone — take it back out and say so.
      if (!mounted) return;
      setState(() => _routines =
          _routines.where((r) => !identical(r, routine)).toList());
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppLocalizations.of(context).grpActionFailed)));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(AppLocalizations.of(context).aTitle)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(AppLocalizations.of(context).aTitle)),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          if (_offline)
            Container(
              padding: const EdgeInsets.all(10),
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: Colors.amber.withOpacity(0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(children: [
                Icon(Icons.cloud_off, size: 18, color: Brand.warnInk(context)),
                const SizedBox(width: 8),
                Expanded(child: Text(AppLocalizations.of(context).aOffline,
                    style: TextStyle(fontSize: 12, color: Brand.warnInk(context)))),
                TextButton(onPressed: _load, child: Text(AppLocalizations.of(context).aRetry)),
              ]),
            ),
          Text(AppLocalizations.of(context).aSubtitle,
              style: const TextStyle(fontSize: 13, color: Colors.grey)),
          const SizedBox(height: 10),
          ArrivalTargetCard(
            place: _place,
            eta: _eta,
            nightMode: _nightMode,
            hasDuressPin: _hasDuress,
            onSet: _setCheckin,
            onArrived: () => _markArrived(),
            onArrivedWithPin: () => _markArrived(duress: true),
          ),
          if (_eta != null) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _shareLastLocation,
              icon: const Icon(Icons.my_location, size: 18),
              label: Text(AppLocalizations.of(context).aShareLastLocation),
            ),
          ],
          if (_nightMode) ...[
            const SizedBox(height: 8),
            Row(children: [
              Icon(Icons.nightlight_round, size: 16, color: Colors.indigo.shade300),
              const SizedBox(width: 6),
              Expanded(child: Text(AppLocalizations.of(context).aNightSafetyOn,
                  style: const TextStyle(fontSize: 12, color: Colors.indigo))),
            ]),
          ],
          if (_hasDuress) ...[
            const SizedBox(height: 10),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.lock_outline, size: 16, color: Colors.grey),
              const SizedBox(width: 6),
              Expanded(child: Text(AppLocalizations.of(context).aDuressHint,
                  style: const TextStyle(fontSize: 11, color: Colors.grey))),
            ]),
          ],
          const Divider(height: 28),

          // ---- recurring routine ----
          Row(children: [
            Expanded(child: Text(AppLocalizations.of(context).aRoutineTitle,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
            TextButton.icon(
              onPressed: _addRoutine,
              icon: const Icon(Icons.add, size: 18),
              label: Text(AppLocalizations.of(context).aRoutineAdd),
            ),
          ]),
          Text(AppLocalizations.of(context).aRoutineDesc,
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 6),
          if (_routines.isEmpty)
            Text(AppLocalizations.of(context).aRoutineNone,
                style: const TextStyle(fontSize: 13, color: Colors.grey))
          else
            ..._routines.map(_routineTile),
          const Divider(height: 28),

          // ---- history ----
          Text(AppLocalizations.of(context).aHistoryTitle,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 4),
          if (_history.isEmpty)
            Text(AppLocalizations.of(context).aHistoryNone,
                style: const TextStyle(fontSize: 13, color: Colors.grey))
          else
            ..._history.map((h) => ArrivalHistoryTile(
                  place: (h['place'] ?? '').toString(),
                  eta: DateTime.tryParse((h['eta'] ?? '').toString()) ?? DateTime.now(),
                  arrived: h['arrived'] == true,
                )),
        ]),
      ),
    );
  }

  Widget _routineTile(Map<String, dynamic> r) {
    final time = (r['time'] ?? '').toString();
    final days = ((r['days'] ?? []) as List).map((d) {
      final i = kRoutineDayCodes.indexOf(d.toString());
      return i >= 0 ? arrivalLabel(context, kRoutineDayLabelKeys[i]) : d.toString();
    }).join(', ');
    final enabled = r['enabled'] == true;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(Icons.repeat,
          color: enabled ? Theme.of(context).colorScheme.primary : Colors.grey),
      title: Text('${AppLocalizations.of(context).aRoutineHomeBy}: $time'),
      subtitle: Text(days),
      trailing: Text(enabled ? AppLocalizations.of(context).aRoutineEnabled : '',
          style: const TextStyle(fontSize: 12, color: Colors.green)),
    );
  }
}
