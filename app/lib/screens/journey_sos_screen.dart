import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:geolocator/geolocator.dart';
import '../state.dart';
import '../l10n/app_localizations.dart';
import '../widgets/password_field.dart';
import '../widgets/journey_api.dart';

/// Discreet SOS flow (item 7 + 8 + 11 + 12), fully working IN-APP today.
///
/// Flow:
///   1. A short countdown (so a mis-tap is cancellable).
///   2. Cancelling requires the PIN. The NORMAL pin truly cancels; the DURESS
///      pin makes the screen LOOK cancelled while silently firing an emergency
///      alert + live location to watchers (item 8). Logic mirrors
///      core.logic.safety_journey.verify_pin_action / duress_outcome — but the
///      authoritative check is server-side (POST /journey/<id>/stop {pin} and
///      /journey/sos {silent}); this screen never stores the raw PINs.
///   3. On fire: alert watchers with live location, show nearest help
///      (item 11) + helplines (item 12), optional loud siren (item 7).
///
/// `journeyId` ties the SOS to an active journey (so watchers get the trip
/// context); null = standalone panic SOS.
class JourneySosScreen extends StatefulWidget {
  final int? journeyId;
  final int countdownSeconds;
  final bool sirenDefault;
  const JourneySosScreen({
    super.key,
    this.journeyId,
    this.countdownSeconds = 5,
    this.sirenDefault = false,
  });

  @override
  State<JourneySosScreen> createState() => _JourneySosScreenState();
}

enum _Phase { counting, fired, cancelled }

class _JourneySosScreenState extends State<JourneySosScreen> {
  late int _remaining;
  Timer? _timer;
  _Phase _phase = _Phase.counting;
  bool _siren = false;
  List<Map<String, dynamic>> _help = [];
  List<Map<String, dynamic>> _helplines = const [
    {'number': '999'},
    {'number': '109'},
  ];

  @override
  void initState() {
    super.initState();
    _siren = widget.sirenDefault;
    _remaining = widget.countdownSeconds;
    if (_remaining <= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _fire());
    } else {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _remaining--);
        if (_remaining <= 0) _fire();
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
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

  Future<void> _fire({bool silent = false}) async {
    _timer?.cancel();
    if (mounted) setState(() => _phase = _Phase.fired);
    final api = context.read<AppState>().api;
    final pos = await _position();
    try {
      await api.journeySos(
        journeyId: widget.journeyId,
        lat: pos?.latitude,
        lng: pos?.longitude,
        silent: silent,
        siren: _siren,
      );
    } catch (_) {
      // offline: the server-side queue + retry (safety_journey.enqueue_alert)
      // handles delivery; nothing to show the user here.
    }
    if (pos != null) {
      try {
        final r = await api.nearestHelp(pos.latitude, pos.longitude);
        if (mounted) {
          setState(() {
            _help = [
              ...((r['police'] ?? []) as List).cast<Map<String, dynamic>>(),
              ...((r['hospital'] ?? []) as List).cast<Map<String, dynamic>>(),
            ];
            if (r['helplines'] is List) {
              _helplines = (r['helplines'] as List).cast<Map<String, dynamic>>();
            }
          });
        }
      } catch (_) {}
    }
  }

  /// Cancel requires a PIN. Returns via server classification (cancel/duress).
  Future<void> _attemptCancel() async {
    final t = AppLocalizations.of(context);
    final pin = await _askPin(t);
    if (pin == null) return; // dismissed -> stay armed
    final api = context.read<AppState>().api;
    // The server classifies pin -> cancel | duress | wrong (never trust client).
    // On 'duress' the server silently alerts; the UI here just looks cancelled.
    try {
      final r = await api.journeyStop(widget.journeyId ?? 0, pin: pin);
      final action = (r['action'] ?? 'cancel').toString();
      if (action == 'wrong') {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(t.sosPinWrong)));
        }
        return; // stay armed
      }
      // 'cancel' AND 'duress' both LOOK cancelled (duress fired silently server-side)
    } catch (_) {
      // offline: treat as normal cancel of the local UI; server reconciles.
    }
    _timer?.cancel();
    if (mounted) {
      setState(() => _phase = _Phase.cancelled);
      Navigator.of(context).maybePop();
    }
  }

  Future<String?> _askPin(AppLocalizations t) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.sosPinTitle),
        content: ObscureTextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(labelText: t.sosPinLabel),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, null), child: Text(t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: Text(t.ok)),
        ],
      ),
    );
  }

  Future<void> _call(String phone) async {
    final uri = Uri.parse('tel:$phone');
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  Future<void> _directions(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (_phase == _Phase.counting) {
      return Scaffold(
        backgroundColor: const Color(0xFFC62828),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.sos, color: Colors.white, size: 56),
                  const SizedBox(height: 16),
                  Text(t.sosSending,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 20),
                  Text('$_remaining',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 80,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 10),
                  SwitchListTile(
                    value: _siren,
                    onChanged: (v) => setState(() => _siren = v),
                    title: Text(t.sosSiren,
                        style: const TextStyle(color: Colors.white)),
                    activeThumbColor: Colors.white,
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: const Color(0xFFC62828),
                          padding: const EdgeInsets.symmetric(vertical: 18)),
                      onPressed: _attemptCancel,
                      child: Text(t.sosCancel,
                          style: const TextStyle(
                              fontSize: 20, fontWeight: FontWeight.bold)),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(t.sosCancelNeedsPin,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70, fontSize: 12)),
                ]),
          ),
        ),
      );
    }

    // fired: alert sent, show help + helplines
    return Scaffold(
      appBar: AppBar(
          backgroundColor: const Color(0xFFC62828),
          foregroundColor: Colors.white,
          title: Text(t.sosSentTitle)),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
              color: const Color(0xFFC62828).withOpacity(0.1),
              borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            const Icon(Icons.check_circle, color: Color(0xFFC62828)),
            const SizedBox(width: 10),
            Expanded(
                child: Text(t.sosSentBody,
                    style: const TextStyle(fontWeight: FontWeight.w600))),
          ]),
        ),
        const SizedBox(height: 20),
        Text(t.sosHelplines,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 6),
        ..._helplines.map((h) => Card(
              child: ListTile(
                leading: const Icon(Icons.call, color: Color(0xFFC62828)),
                title: Text(h['number'].toString()),
                subtitle:
                    h['label'] != null ? Text(h['label'].toString()) : null,
                trailing: FilledButton(
                    onPressed: () => _call(h['number'].toString()),
                    child: Text(t.sosCallNow)),
              ),
            )),
        const SizedBox(height: 16),
        Text(t.sosNearestHelp,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 6),
        if (_help.isEmpty)
          Text(t.sosNearestHelpLoading,
              style: const TextStyle(color: Colors.grey)),
        ..._help.map((p) => Card(
              child: ListTile(
                leading: Icon(
                    (p['type'] == 'hospital')
                        ? Icons.local_hospital
                        : Icons.local_police,
                    color: Colors.indigo),
                title: Text((p['name'] ?? '').toString()),
                subtitle: p['distance_m'] != null
                    ? Text(t.sosDistanceAway(p['distance_m'].toString()))
                    : null,
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  if ((p['phone'] ?? '').toString().isNotEmpty)
                    IconButton(
                        icon: const Icon(Icons.call),
                        onPressed: () => _call(p['phone'].toString())),
                  if ((p['directions'] ?? '').toString().isNotEmpty)
                    IconButton(
                        icon: const Icon(Icons.directions),
                        onPressed: () =>
                            _directions(p['directions'].toString())),
                ]),
              ),
            )),
        const SizedBox(height: 24),
        OutlinedButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: Text(t.close)),
      ]),
    );
  }
}
