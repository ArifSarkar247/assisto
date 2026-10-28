import 'dart:async';
import '../theme.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:geolocator/geolocator.dart';
import '../state.dart';
import '../l10n/app_localizations.dart';
import '../api.dart';
import '../services/action_feedback.dart';
import '../services/journey_tracker.dart';
import '../widgets/password_field.dart';
import '../widgets/journey_api.dart';
import 'package:assisto/widgets/app_sheet.dart';

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

  /// journey100: a safety PIN is set (cancel asks for it). Null = ask the
  /// server (GET /journey/duress-pin) when Cancel is tapped.
  final bool? pinRequired;

  /// Last known position (used for the SMS text if GPS is slow / off).
  final double? lastLat, lastLng;
  const JourneySosScreen({
    super.key,
    this.journeyId,
    this.countdownSeconds = 5,
    this.sirenDefault = false,
    this.pinRequired,
    this.lastLat,
    this.lastLng,
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
  bool _sending = false;
  bool _sendFailed = false; // journey100: the alert did NOT reach the server
  String _helpState = 'loading'; // loading | ok | none_nearby | failed | no_location
  double? _lat, _lng;
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
    _lat = pos?.latitude ?? widget.lastLat;
    _lng = pos?.longitude ?? widget.lastLng;
    await _send(api, silent: silent);
    if (_lat == null || _lng == null) {
      if (mounted) setState(() => _helpState = 'no_location');
      return;
    }
    try {
      final r = await api.nearestHelp(_lat!, _lng!);
      if (mounted) {
        setState(() {
          _help = [
            ...((r['police'] ?? []) as List).cast<Map<String, dynamic>>(),
            ...((r['hospital'] ?? []) as List).cast<Map<String, dynamic>>(),
          ];
          if (r['helplines'] is List) {
            _helplines = (r['helplines'] as List).cast<Map<String, dynamic>>();
          }
          _helpState = (r['state'] ?? (_help.isEmpty ? 'none_nearby' : 'ok')).toString();
        });
      }
    } catch (_) {
      if (mounted) setState(() => _helpState = 'failed');
    }
  }

  /// Send (or re-send) the SOS. A failure is SHOWN — with the SMS fallback
  /// and 999 — never swallowed; three quiet retries first.
  Future<void> _send(ApiClient api, {bool silent = false}) async {
    if (mounted) setState(() => _sending = true);
    var ok = false;
    for (var attempt = 0; attempt < 3 && !ok; attempt++) {
      try {
        await api.journeySos(
          journeyId: widget.journeyId,
          lat: _lat,
          lng: _lng,
          silent: silent,
          siren: _siren,
        );
        ok = true;
      } catch (_) {
        if (attempt < 2) {
          await Future<void>.delayed(Duration(seconds: 2 * (attempt + 1)));
        }
      }
    }
    if (mounted) {
      setState(() {
        _sending = false;
        _sendFailed = !ok;
      });
    }
  }

  Future<void> _sms() async {
    final t = AppLocalizations.of(context);
    final phones = <String>{
      ...(await Settings.getString(kPhonesKey) ?? '')
          .split(',')
          .where((p) => p.trim().isNotEmpty),
    };
    if (phones.isEmpty && mounted) {
      try {
        final c = await context.read<AppState>().api.getEmergency();
        for (final m in ((c['contacts'] ?? []) as List)) {
          final ph = (m is Map ? m['phone'] : null)?.toString() ?? '';
          if (ph.isNotEmpty) phones.add(ph);
        }
      } catch (_) {
        // best-effort: offline — the SMS app opens without recipients
      }
    }
    if (!mounted) return;
    final body = (_lat == null || _lng == null)
        ? t.j100SmsBodyNoLoc
        : t.j100SosSmsBody(journeyMapsLink(_lat!, _lng!),
            TimeOfDay.now().format(context));
    await openForUser(context, journeySmsUri(phones.toList(), body),
        where: 'journey.sosSms');
  }

  /// Cancel. No PIN set -> cancels. With a PIN the SERVER classifies it:
  /// normal -> cancel; duress -> the SAME cancelled screen while a silent SOS
  /// goes out; wrong -> stay armed. Never stops the journey itself.
  Future<void> _attemptCancel() async {
    final t = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    var needPin = widget.pinRequired;
    if (needPin == null) {
      try {
        needPin = await api.duressPinConfigured();
      } catch (_) {
        needPin = await Settings.getBool('journey_has_duress', false);
      }
    }
    if (!mounted) return;
    String? pin;
    if (needPin == true) {
      pin = await _askPin(t);
      if (pin == null || pin.isEmpty) return; // dismissed -> stay armed
    }
    try {
      await api.journeySosCancel(
          pin: pin, journeyId: widget.journeyId, lat: widget.lastLat, lng: widget.lastLng);
    } on ApiException catch (e) {
      if (e.status == 400 || e.status == 429) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(e.status == 429 ? t.j100PinLocked : t.sosPinWrong)));
        }
        return; // stay armed
      }
      // server error: nothing was sent yet (countdown) — cancel locally
    } catch (_) {
      // best-effort: offline — nothing was sent yet during the countdown, so
      // the local cancel is the honest outcome (a duress PIN cannot alert
      // silently without internet; the SMS button needs the user's tap)
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
        scrollable: true, // insets: 200% text / keyboard
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

  // DIAL intent (tel:) — the user presses call; no CALL_PHONE needed here.
  Future<void> _call(String phone) =>
      openForUser(context, Uri.parse('tel:$phone'), where: 'journey.sosCall');

  Future<void> _directions(String url) => openForUser(context, Uri.parse(url),
      where: 'journey.sosDirections', mode: LaunchMode.externalApplication);

  Future<void> _searchMap(String what) => openForUser(
      context,
      Uri.parse('https://www.google.com/maps/search/?api=1&query='
          '${Uri.encodeComponent(what)}${_lat != null ? '&center=$_lat,$_lng' : ''}'),
      where: 'journey.sosSearch',
      mode: LaunchMode.externalApplication);

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (_phase == _Phase.counting) {
      return Scaffold(
        backgroundColor: Brand.dangerFill,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.sos_rounded, color: Colors.white, size: 56),
                  const SizedBox(height: Gap.lg),
                  Text(t.sosSending,
                      style: AType.headlineSmall.copyWith(color: Colors.white,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 20),
                  Text('$_remaining',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 80, // countdown hero digit, above the scale
                          fontFeatures: AFonts.tabular,
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
                          foregroundColor: Brand.dangerFill,
                          padding: const EdgeInsets.symmetric(vertical: 18)),
                      onPressed: _attemptCancel,
                      child: Text(t.sosCancel,
                          style: AType.titleLarge.copyWith(fontWeight: FontWeight.bold)),
                    ),
                  ),
                  const SizedBox(height: Gap.sm),
                  Text(t.sosCancelNeedsPin,
                      textAlign: TextAlign.center,
                      style: AType.bodyMedium.copyWith(color: Colors.white)),
                ]),
          ),
        ),
      );
    }

    // fired: alert sent, show help + helplines
    return Scaffold(
      appBar: AppBar(
          backgroundColor: Brand.dangerFill,
          foregroundColor: Colors.white,
          title: Text(t.sosSentTitle)),
      body: ListView(padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)), children: [
        Container(
          key: const ValueKey('j100_sos_state'),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.error.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(Radii.md)),
          child: Row(children: [
            if (_sending)
              const SizedBox(
                  width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
            else
              Icon(_sendFailed ? Icons.cloud_off_rounded : Icons.check_circle_rounded,
                  color: Theme.of(context).colorScheme.error),
            const SizedBox(width: 10),
            Expanded(
                child: Text(
                    _sending
                        ? t.sosSending
                        : (_sendFailed ? t.j100SosNotSent : t.sosSentBody),
                    style: const TextStyle(fontWeight: FontWeight.w600))),
          ]),
        ),
        if (_sendFailed && !_sending)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
                key: const ValueKey('j100_sos_retry'),
                icon: const Icon(Icons.refresh_rounded),
                label: Text(t.retry),
                onPressed: () => _send(context.read<AppState>().api)),
          ),
        const SizedBox(height: Gap.sm),
        FilledButton.icon(
          key: const ValueKey('j100_sos_sms'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          icon: const Icon(Icons.sms_rounded),
          label: Text(t.j100SendSms),
          onPressed: _sms,
        ),
        const SizedBox(height: 20),
        Text(t.sosHelplines,
            style: AType.titleMedium.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        ..._helplines.map((h) => Card(
              child: ListTile(
                leading: Icon(Icons.call_rounded, color: Theme.of(context).colorScheme.error),
                title: Text(h['number'].toString()),
                subtitle:
                    h['label'] != null ? Text(h['label'].toString()) : null,
                trailing: FilledButton(
                    onPressed: () => _call(h['number'].toString()),
                    child: Text(t.call)),
              ),
            )),
        const SizedBox(height: Gap.lg),
        Text(t.sosNearestHelp,
            style: AType.titleMedium.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        if (_help.isEmpty)
          Text(
              switch (_helpState) {
                'loading' => t.sosNearestHelpLoading,
                'failed' || 'no_location' => t.j100NearbyFailed,
                _ => t.j100NearbyNone,
              },
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        if (_help.isEmpty && _helpState != 'loading')
          Wrap(spacing: Gap.sm, children: [
            OutlinedButton.icon(
                icon: const Icon(Icons.local_police_rounded),
                label: Text(t.j100SearchPolice),
                onPressed: () => _searchMap(t.j100SearchPoliceQuery)),
            OutlinedButton.icon(
                icon: const Icon(Icons.local_hospital_rounded),
                label: Text(t.j100SearchHospital),
                onPressed: () => _searchMap(t.j100SearchHospitalQuery)),
          ]),
        ..._help.map((p) => Card(
              child: ListTile(
                leading: Icon(
                    (p['type'] == 'hospital')
                        ? Icons.local_hospital_rounded
                        : Icons.local_police_rounded,
                    color: Colors.indigo),
                title: Text((p['name'] ?? '').toString()),
                subtitle: p['distance_m'] != null
                    ? Text(t.sosDistanceAway(p['distance_m'].toString()))
                    : null,
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  if ((p['phone'] ?? '').toString().isNotEmpty)
                    IconButton(tooltip: AppLocalizations.of(context).call,
                        icon: const Icon(Icons.call_rounded),
                        onPressed: () => _call(p['phone'].toString())),
                  if ((p['directions'] ?? '').toString().isNotEmpty)
                    IconButton(tooltip: AppLocalizations.of(context).emergencyDirections,
                        icon: const Icon(Icons.directions_rounded),
                        onPressed: () =>
                            _directions(p['directions'].toString())),
                ]),
              ),
            )),
        const SizedBox(height: Gap.xl),
        OutlinedButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: Text(t.close)),
      ]),
    );
  }
}
