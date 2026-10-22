import 'dart:async';
import 'package:flutter/material.dart';
import '../theme.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:geolocator/geolocator.dart';
import 'package:share_plus/share_plus.dart';
import '../state.dart';
import '../l10n/app_localizations.dart';
import '../widgets/safety_sos_countdown.dart';
import '../widgets/safety_checkin_card.dart';
import 'voice_sos_screen.dart';
import '../widgets/scam_safety_api.dart';
import '../widgets/sos_button.dart';
import 'journey_start_screen.dart';
import 'journey_live_screen.dart';
import 'journey_sos_screen.dart';
import 'journey_settings_screen.dart';
import '../widgets/journey_api.dart';
import 'fall_detect_screen.dart';

/// Advanced family-safety hub (benchmarked vs Life360 / bSafe):
///   - SOS with a configurable countdown (so a mis-tap can be cancelled)
///   - safe-arrival check-in (arrived / "pouchechi"; overdue -> family alerted)
///   - accident/fall-detection config (window, alarm, vibration) — the sensor
///     itself is platform-gated and clearly marked.
class SafetyScreen extends StatefulWidget {
  const SafetyScreen({super.key});
  @override
  State<SafetyScreen> createState() => _SafetyScreenState();
}

class _SafetyScreenState extends State<SafetyScreen> {
  // SOS
  int _sosCountdown = 5;
  // fall detection
  bool _fallEnabled = false;
  int _fallWindow = 120; // seconds
  bool _fallAlarm = true;
  bool _fallVibration = true;
  // the native accelerometer/fall sensor plugin is not wired yet.
  static bool get _sensorAvailable => FallDetectScreen.engineShipped;

  // check-in (local, surfaced to family via foreground poll)
  String? _checkinPlace;
  DateTime? _checkinEta;

  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _sosCountdown = int.tryParse(await Settings.getString('safety_sos_cd') ?? '') ?? 5;
    _fallEnabled = await Settings.getBool('safety_fall_on', false);
    _fallWindow = int.tryParse(await Settings.getString('safety_fall_win') ?? '') ?? 120;
    _fallAlarm = await Settings.getBool('safety_fall_alarm', true);
    _fallVibration = await Settings.getBool('safety_fall_vib', true);
    final place = await Settings.getString('safety_checkin_place');
    final eta = await Settings.getString('safety_checkin_eta');
    _checkinPlace = (place != null && place.isNotEmpty) ? place : null;
    _checkinEta = (eta != null && eta.isNotEmpty) ? DateTime.tryParse(eta) : null;
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _call(String phone) async {
    final uri = Uri.parse('tel:$phone');
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  Future<List<Map<String, dynamic>>> _contacts() async {
    try {
      final c = await context.read<AppState>().api.getEmergency();
      return ((c['contacts'] ?? []) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  /// Mirror core.logic.safety.sos_alert_targets: skip entries without a phone,
  /// keep the original (primary-first) order. Returns the first callable one.
  Map<String, dynamic>? _firstCallable(List<Map<String, dynamic>> contacts) {
    for (final c in contacts) {
      if ((c['phone'] ?? '').toString().trim().isNotEmpty) return c;
    }
    return null;
  }

  /// Resume an in-progress journey if one exists, else open the start flow.
  Future<void> _openJourney() async {
    final navigator = Navigator.of(context);
    int? activeId;
    try {
      final r = await context.read<AppState>().api.journeyActive();
      if (r['status'] == 'active') activeId = (r['id'] as num?)?.toInt();
    } catch (_) {}
    if (!mounted) return;
    navigator.push(MaterialPageRoute(
        builder: (_) => activeId != null
            ? JourneyLiveScreen(journeyId: activeId!)
            : const JourneyStartScreen()));
  }

  Future<void> _triggerSos() async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final contacts = await _contacts();
    if (!mounted) return;
    // Pick the first contact that actually has a phone — never blindly dial
    // contacts.first, which may be a blank/phoneless entry.
    final primary = _firstCallable(contacts);
    if (primary == null) {
      messenger.showSnackBar(SnackBar(content: Text(t.emergencyAddContactFirst)));
      return;
    }
    final fire = await SafetySosCountdown.show(context, _sosCountdown);
    if (!fire || !mounted) return;
    // share location best-effort, then call the primary contact
    await _shareLocationBestEffort();
    await _call(primary['phone'].toString());
  }

  Future<void> _shareLocationBestEffort() async {
    final t = AppLocalizations.of(context);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        return;
      }
      final pos = await Geolocator.getCurrentPosition();
      final link = 'https://maps.google.com/?q=${pos.latitude},${pos.longitude}';
      await Share.share(t.sosShareText(link));
    } catch (_) {}
  }

  Future<void> _setCountdown() async {
    final t = AppLocalizations.of(context);
    int v = _sosCountdown;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
            title: Text(t.safetySosCountdownTitle),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(t.safetySosCountdownValue(v)),
              Slider(
                value: v.toDouble(), min: 0, max: 30, divisions: 30,
                label: '$v',
                onChanged: (x) => setD(() => v = x.round()),
              ),
              Text(t.safetySosCountdownNote, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ]),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.save)),
            ],
          )),
    );
    if (ok == true) {
      setState(() => _sosCountdown = v);
      await Settings.setString('safety_sos_cd', '$v');
    }
  }

  Future<void> _setCheckin() async {
    final t = AppLocalizations.of(context);
    final place = TextEditingController(text: _checkinPlace ?? '');
    TimeOfDay time = TimeOfDay.now();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
            title: Text(t.safetyCheckinSetTitle),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: place,
                  decoration: InputDecoration(labelText: t.safetyCheckinPlaceLabel)),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.schedule, size: 18),
                label: Text(t.safetyCheckinByTime(time.format(ctx))),
                onPressed: () async {
                  final picked = await showTimePicker(context: ctx, initialTime: time);
                  if (picked != null) setD(() => time = picked);
                },
              ),
            ]),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.save)),
            ],
          )),
    );
    if (ok == true) {
      final now = DateTime.now();
      var eta = DateTime(now.year, now.month, now.day, time.hour, time.minute);
      if (eta.isBefore(now)) eta = eta.add(const Duration(days: 1));
      setState(() {
        _checkinPlace = place.text.trim().isEmpty ? null : place.text.trim();
        _checkinEta = eta;
      });
      await Settings.setString('safety_checkin_place', _checkinPlace ?? '');
      await Settings.setString('safety_checkin_eta', eta.toIso8601String());
      // surface to backend so family poll can see it. m2-reality: a failed
      // send used to be silent — the user believed family was watching.
      try {
        await context.read<AppState>().api.safetyCheckinStart(
            place: _checkinPlace, etaIso: eta.toIso8601String());
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(AppLocalizations.of(context).realityCheckinNotSent)));
        }
      }
    }
  }

  Future<void> _markArrived() async {
    setState(() {
      _checkinPlace = null;
      _checkinEta = null;
    });
    await Settings.setString('safety_checkin_place', '');
    await Settings.setString('safety_checkin_eta', '');
    // m2-reality: if the server never heard "arrived", the overdue alert can
    // still go to family — say so instead of a false "done".
    var ok = true;
    try {
      await context.read<AppState>().api.safetyCheckinArrived();
    } catch (_) {
      ok = false;
    }
    if (mounted) {
      final t = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(ok ? t.safetyArrivedDone : t.realityArrivedNotSent)));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.safetyTitle), actions: [
        IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: t.journeySettingsTitle,
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const JourneySettingsScreen()))),
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        // ---- Safe Journey (top-priority feature) ----
        Text(t.journeySection,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 8),
        Card(
          color: const Color(0xFF1976D2).withOpacity(0.06),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.navigation, color: Color(0xFF1976D2)),
                const SizedBox(width: 10),
                Expanded(
                    child: Text(t.journeyHubTitle,
                        style: const TextStyle(fontWeight: FontWeight.w700))),
              ]),
              const SizedBox(height: 6),
              Text(t.journeyHubDesc,
                  style: TextStyle(
                      fontSize: 13,
                      height: 1.4,
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14)),
                  onPressed: _openJourney,
                  icon: const Icon(Icons.navigation),
                  label: Text(t.journeyStartButton),
                ),
              ),
            ]),
          ),
        ),
        const Divider(height: 28),

        // ---- discreet SOS (full flow: nearest help + helplines + duress) ----
        SosButton(
          label: t.emergencySosButton,
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => JourneySosScreen(countdownSeconds: _sosCountdown))),
        ),
        const SizedBox(height: 8),
        // Legacy quick-call SOS (dials the first contact) kept as a fallback.
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _triggerSos,
            icon: const Icon(Icons.call, size: 20),
            label: Text(t.safetySosQuickCall),
          ),
        ),
        const SizedBox(height: 6),
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.timer_outlined),
          title: Text(t.safetySosCountdownValue(_sosCountdown)),
          trailing: TextButton(onPressed: _setCountdown, child: Text(t.edit)),
        ),
        // Hands-free Voice SOS (feature #79) — opt-in, OFF by default.
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.record_voice_over_outlined),
          title: Text(t.vsosTitle),
          subtitle: Text(t.vsosTileSubtitle,
              style: const TextStyle(fontSize: 12)),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const VoiceSosScreen())),
        ),
        const Divider(height: 28),

        // Safe-arrival check-in
        Text(t.safetyCheckinSection, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 8),
        SafetyCheckinCard(
          place: _checkinPlace,
          eta: _checkinEta,
          onSet: _setCheckin,
          onArrived: _markArrived,
        ),
        const Divider(height: 28),

        // NO SHOWPIECES: the fall switch is hidden until a real fall sensor
        // engine ships (FallDetectScreen.engineShipped).
        if (_sensorAvailable) ...[
        // Fall / accident detection
        Text(t.safetyFallSection, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 4),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(t.safetyFallEnable),
          subtitle: Text(t.safetyFallEnableDesc),
          value: _fallEnabled,
          onChanged: (v) async {
            setState(() => _fallEnabled = v);
            await Settings.setBool('safety_fall_on', v);
          },
        ),
        if (_fallEnabled) ...[
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t.safetyFallWindowLabel),
            subtitle: Text(t.safetyFallWindowValue(_fallWindow ~/ 60, _fallWindow % 60)),
          ),
          Slider(
            value: _fallWindow.toDouble(), min: 30, max: 600, divisions: 19,
            label: '${_fallWindow ~/ 60}:${(_fallWindow % 60).toString().padLeft(2, '0')}',
            onChanged: (x) => setState(() => _fallWindow = x.round()),
            onChangeEnd: (x) async =>
                await Settings.setString('safety_fall_win', '${x.round()}'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t.safetyFallAlarm),
            value: _fallAlarm,
            onChanged: (v) async {
              setState(() => _fallAlarm = v);
              await Settings.setBool('safety_fall_alarm', v);
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t.safetyFallVibration),
            value: _fallVibration,
            onChanged: (v) async {
              setState(() => _fallVibration = v);
              await Settings.setBool('safety_fall_vib', v);
            },
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.play_circle_outline),
            label: Text(t.safetyFallPreview),
            onPressed: () => _previewFall(t),
          ),
        ],
        ],
        const SizedBox(height: 20),
        Text(t.safetyFooterNote, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ]),
    );
  }

  // Shows the big "I'm OK" prompt so the user sees exactly what happens after a
  // detected fall. Logic mirrors core.logic.safety.fall_prompt_phase.
  Future<void> _previewFall(AppLocalizations t) async {
    int remaining = _fallWindow;
    Timer? timer;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
          if (remaining <= 0) {
            timer?.cancel();
            if (ctx.mounted) Navigator.pop(ctx, false);
          } else {
            setD(() => remaining--);
          }
        });
        return Dialog(
          backgroundColor: Colors.orange.shade800,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.personal_injury, color: Colors.white, size: 44),
              const SizedBox(height: 10),
              Text(t.safetyFallPromptTitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(t.safetyFallPromptBody(remaining),
                  textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: Colors.white, foregroundColor: Colors.orange.shade900,
                      padding: const EdgeInsets.symmetric(vertical: 18)),
                  onPressed: () {
                    timer?.cancel();
                    Navigator.pop(ctx, true);
                  },
                  child: Text(t.safetyImOk, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                ),
              ),
            ]),
          ),
        );
      }),
    );
    timer?.cancel();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok == true ? t.safetyFallPreviewOk : t.safetyFallPreviewAlert)));
  }
}
