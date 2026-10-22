import 'dart:async';
import 'package:flutter/material.dart';
import '../widgets/adaptive_button_pair.dart';
import 'package:provider/provider.dart';
import 'package:geolocator/geolocator.dart';
import 'package:share_plus/share_plus.dart';
import '../state.dart';
import '../l10n/app_localizations.dart';
import '../widgets/journey_api.dart';
import '../widgets/sos_button.dart';
import 'journey_sos_screen.dart';
import 'journey_fake_call_screen.dart';
import '../services/action_feedback.dart'; // db1

/// In-app LIVE journey screen (item 2). Works NOW: while open it pushes the
/// device location (+battery) to the server every ~15s, which runs the
/// auto-arrival geofence (item 4), the overdue state machine (item 5), the
/// low-battery trigger (item 6) and route-deviation (item 15). It also hosts
/// the always-available in-app SOS button (item 7), the "I'm safe" arrival,
/// the share-an-expiring-web-link action (item 13) and the fake-call escape
/// (item 9).
///
/// The battery-efficient background FOREGROUND SERVICE + prominent-location
/// disclosure is native platform work — this screen is the in-app path that
/// works today; the integrator wires the service to call the same
/// journeyLocation endpoint when the app is backgrounded (see report).
class JourneyLiveScreen extends StatefulWidget {
  final int journeyId;
  const JourneyLiveScreen({super.key, required this.journeyId});
  @override
  State<JourneyLiveScreen> createState() => _JourneyLiveScreenState();
}

class _JourneyLiveScreenState extends State<JourneyLiveScreen>
    with WidgetsBindingObserver {
  Timer? _ticker;
  Map<String, dynamic> _journey = {};
  String _status = 'active';
  String _overdue = 'on_time';
  bool _asked = false; // overdue "Are you OK?" prompt showing

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tick();
    _ticker = Timer.periodic(const Duration(seconds: 15), (_) => _tick());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _tick();
  }

  Future<void> _tick() async {
    if (!mounted || _status != 'active') return;
    final api = context.read<AppState>().api;
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return;
      }
      final pos = await Geolocator.getCurrentPosition();
      // Battery % for the low-battery trigger (item 6) comes from a native
      // channel the integrator wires (no battery_plus dependency yet); the
      // <15% auto-send logic lives server-side in safety_journey. Null today.
      final int? batt = null;
      final r = await api.journeyLocation(widget.journeyId,
          lat: pos.latitude, lng: pos.longitude, battery: batt);
      if (!mounted) return;
      setState(() {
        _journey = r;
        _status = (r['status'] ?? 'active').toString();
        _overdue = (r['overdue_state'] ?? _overdue).toString();
      });
      if (_status == 'arrived') {
        _onArrived();
      } else if (_overdue == 'ask' && !_asked) {
        _promptOk();
      }
    } catch (_) {
      // offline: server-side queue handles watcher alerts; retry next tick.
    }
  }

  void _snackText(String msg) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(msg)));

  void _onArrived() {
    final t = AppLocalizations.of(context);
    _ticker?.cancel();
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(t.journeyArrivedSafely)));
    if (Navigator.canPop(context)) Navigator.pop(context);
  }

  Future<void> _promptOk() async {
    setState(() => _asked = true);
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(t.journeyAreYouOkTitle),
        content: Text(t.journeyAreYouOkBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.journeyNeedHelp)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.journeyImOk)),
        ],
      ),
    );
    if (!mounted) return;
    if (ok == true) {
      // q1-seams: a failed "I'm OK" used to be silent, so the server could
      // still escalate to family while the user believed it was handled.
      try {
        await context.read<AppState>().api.journeyRespondOk(widget.journeyId);
      } catch (_) {
        if (mounted) _snackText(AppLocalizations.of(context).grpActionFailed);
        // _asked=false so the next overdue tick asks again.
        if (mounted) setState(() => _asked = false);
        return;
      }
      setState(() => _asked = false);
    } else {
      _openSos();
    }
  }

  Future<void> _markArrived() async {
    final api = context.read<AppState>().api;
    try {
      await api.journeyArrived(widget.journeyId);
    } catch (_) {
      // q1-seams: never a false "arrived safely" — the server did not hear it,
      // so family may still be alerted. Stay on the live screen.
      if (mounted) {
        _snackText(AppLocalizations.of(context).realityArrivedNotSent);
      }
      return;
    }
    if (mounted) _onArrived();
  }

  Future<void> _stop() async {
    final t = AppLocalizations.of(context);
    // Stopping may require the PIN (duress flow) — the server classifies it.
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.journeyStopTitle),
        content: Text(t.journeyStopBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: Text(t.journeyStopConfirm)),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await context.read<AppState>().api.journeyStop(widget.journeyId);
    } catch (_) {
      // q1-seams: the journey is still live on the server (watchers still
      // see it) — say so and keep the screen instead of a silent close.
      if (mounted) _snackText(AppLocalizations.of(context).grpActionFailed);
      return;
    }
    _ticker?.cancel();
    if (mounted && Navigator.canPop(context)) Navigator.pop(context);
  }

  Future<void> _shareWebLink() async {
    final t = AppLocalizations.of(context);
    try {
      final r = await context.read<AppState>().api.journeyWebLink(widget.journeyId);
      final url = (r['url'] ?? '').toString();
      if (url.isNotEmpty) {
        await Share.share(t.journeyShareLinkText(url));
      }
    } catch (e) {
      showActionFailed(context, 'journey.shareLink', e, open: true); // db1
    }
  }

  void _openSos() {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => JourneySosScreen(
            journeyId: widget.journeyId, countdownSeconds: 5)));
  }

  Future<void> _fakeCall() async {
    final t = AppLocalizations.of(context);
    final ctrl = TextEditingController(text: t.fakeCallDefaultName);
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.fakeCallSetup),
        content: TextField(
            controller: ctrl,
            decoration: InputDecoration(labelText: t.fakeCallCaller)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: Text(t.fakeCallStart)),
        ],
      ),
    );
    if (go == true && mounted) {
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => JourneyFakeCallScreen(
              caller: ctrl.text.trim().isEmpty
                  ? t.fakeCallDefaultName
                  : ctrl.text.trim(),
              delaySeconds: 15)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final dest = (_journey['destination'] as Map?)?['name']?.toString();
    final loc = _journey['last_location'] as Map?;
    return Scaffold(
      appBar: AppBar(title: Text(t.journeyLiveTitle), actions: [
        IconButton(
            icon: const Icon(Icons.link),
            tooltip: t.journeyShareLink,
            onPressed: _shareWebLink),
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
              color: Colors.green.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            const Icon(Icons.navigation, color: Colors.green),
            const SizedBox(width: 10),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(t.journeyWatchingNotif,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  if (dest != null && dest.isNotEmpty)
                    Text(t.journeyToward(dest),
                        style: const TextStyle(fontSize: 13)),
                ])),
          ]),
        ),
        const SizedBox(height: 12),
        if (loc != null && loc['at'] != null)
          Text(t.journeyLastFix(loc['at'].toString()),
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        const SizedBox(height: 16),
        SosButton(label: t.emergencySosButton, onPressed: _openSos),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
                // QA a6: white on Colors.green was 2.8:1 — deeper green 5:1.
                backgroundColor: const Color(0xFF1E7E4E),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16)),
            onPressed: _markArrived,
            icon: const Icon(Icons.check_circle),
            label: Text(t.journeyImSafe, style: const TextStyle(fontSize: 17)),
          ),
        ),
        const SizedBox(height: 12),
        AdaptiveButtonPair(
          first: OutlinedButton.icon(
              icon: const Icon(Icons.phone_callback),
              label: Text(t.fakeCallTitle),
              onPressed: _fakeCall),
          second: OutlinedButton.icon(
              icon: const Icon(Icons.stop_circle_outlined),
              label: Text(t.journeyStop),
              onPressed: _stop),
        ),
        const SizedBox(height: 20),
        Text(t.journeyLiveFooter,
            style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ]),
    );
  }
}
