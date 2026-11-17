import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../l10n/app_localizations.dart';
import '../widgets/safety_checkin_card.dart';
import 'voice_sos_screen.dart';
import '../widgets/scam_safety_api.dart';
import '../widgets/sos_button.dart';
import 'journey_start_screen.dart';
import 'journey_live_screen.dart';
import 'journey_sos_screen.dart';
import 'journey_settings_screen.dart';
import 'sos_triggers_screen.dart'; // sosat
import '../widgets/journey_api.dart';
import '../widgets/subs_common.dart' show fmtInt;
import '../ds/ds.dart';
import '../theme.dart';
import 'package:assisto/widgets/app_sheet.dart';
import 'package:assisto/safety/ad_block_context.dart' show AdBlockedState;

/// Advanced family-safety hub (benchmarked vs Life360 / bSafe):
///   - SOS with a configurable countdown (so a mis-tap can be cancelled)
///   - safe-arrival check-in (arrived / "pouchechi"; overdue -> family alerted)
///   - sosat: "more ways to send SOS" (lock screen, power button x5,
///     experimental fall detection) on SosTriggersScreen
class SafetyScreen extends StatefulWidget {
  const SafetyScreen({super.key});
  @override
  State<SafetyScreen> createState() => _SafetyScreenState();
}

class _SafetyScreenState extends State<SafetyScreen>
    with AdBlockedState<SafetyScreen> {
  // SOS
  int _sosCountdown = 5;
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
    final place = await Settings.getString('safety_checkin_place');
    final eta = await Settings.getString('safety_checkin_eta');
    _checkinPlace = (place != null && place.isNotEmpty) ? place : null;
    _checkinEta = (eta != null && eta.isNotEmpty) ? DateTime.tryParse(eta) : null;
    if (mounted) setState(() => _loading = false);
  }

  /// Resume an in-progress journey if one exists, else open the start flow.
  Future<void> _openJourney() async {
    final navigator = Navigator.of(context);
    int? activeId;
    try {
      final r = await context.read<AppState>().api.journeyActive();
      if (r['status'] == 'active') activeId = (r['id'] as num?)?.toInt();
    } catch (_) {} // best-effort: no active journey known: the start flow opens instead
    if (!mounted) return;
    navigator.push(MaterialPageRoute(
        builder: (_) => activeId != null
            ? JourneyLiveScreen(journeyId: activeId!)
            : const JourneyStartScreen()));
  }

  Future<void> _setCountdown() async {
    final t = AppLocalizations.of(context);
    int v = _sosCountdown;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
            scrollable: true, // insets: 200% text / keyboard
            title: Text(t.safetySosCountdownTitle),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(t.safetySosCountdownValue(fmtInt(context, v))), // qa1
              Slider(
                value: v.toDouble(), min: 0, max: 30, divisions: 30,
                label: '$v',
                onChanged: (x) => setD(() => v = x.round()),
              ),
              Text(t.safetySosCountdownNote, style: AType.bodySmall.copyWith(color: Theme.of(context).colorScheme.ds.muted)),
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
            scrollable: true, // insets: 200% text / keyboard
            title: Text(t.safetyCheckinSetTitle),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: place,
                  decoration: InputDecoration(labelText: t.safetyCheckinPlaceLabel)),
              const SizedBox(height: Gap.md),
              OutlinedButton.icon(
                icon: const Icon(Icons.schedule_rounded, size: 18),
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
            place: _checkinPlace, etaIso: eta.toUtc().toIso8601String());
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
      return Scaffold(
          body: ListView(padding: const EdgeInsets.all(Gap.lg), children: [
        for (var i = 0; i < 3; i++)
          Padding(padding: const EdgeInsets.only(bottom: Gap.md), child: DsSkeleton.card(lines: 3)),
      ]));
    }
    final t = AppLocalizations.of(context);
    final ds = DsTokens.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.safetyTitle), actions: [
        IconButton(
            icon: const Icon(Icons.settings_rounded),
            tooltip: t.journeySettingsTitle,
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const JourneySettingsScreen()))),
      ]),
      // designv2 page rule: SOS (the urgent action) first, then Safe Journey,
      // the check-in and the other ways; DS cards, no long lines.
      body: ListView(padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)), children: [
        // ---- discreet SOS (full flow: nearest help + helplines + duress) ----
        SosButton(
          label: t.emergencySosButton,
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => JourneySosScreen(countdownSeconds: _sosCountdown))),
        ),
        const SizedBox(height: Gap.sm),
        DsGroup(margin: EdgeInsets.zero, children: [
          DsListRow(
            leading: DsAvatar(child: Icon(Icons.timer_rounded, color: ds.primaryInk)),
            title: t.safetySosCountdownValue(fmtInt(context, _sosCountdown)), // qa1
            trailing: TextButton(onPressed: _setCountdown, child: Text(t.edit)),
          ),
          // Hands-free Voice SOS (feature #79) — opt-in, OFF by default.
          DsListRow(
            leading: DsAvatar(child: Icon(Icons.record_voice_over_rounded, color: ds.primaryInk)),
            title: t.vsosTitle,
            subtitle: t.vsosTileSubtitle,
            trailing: Icon(Icons.chevron_right_rounded, color: ds.muted),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const VoiceSosScreen())),
          ),
          // sosat: lock-screen SOS, power button x5 and the EXPERIMENTAL fall
          // detection live on one screen (each says honestly when it works:
          // only while Always-on protection runs).
          DsListRow(
            key: const ValueKey('sosat-more-ways'),
            leading: DsAvatar(child: Icon(Icons.touch_app_rounded, color: ds.primaryInk)),
            title: t.saMoreWaysTitle,
            subtitle: t.saMoreWaysSub,
            trailing: Icon(Icons.chevron_right_rounded, color: ds.muted),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const SosTriggersScreen())),
          ),
        ]),

        // ---- Safe Journey (top-priority feature) ----
        DsSectionHeader(t.journeySection),
        DsHeroCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              DsAvatar(child: Icon(Icons.navigation_rounded, color: ds.primaryInk)),
              const SizedBox(width: Gap.md),
              Expanded(
                  child: Text(t.journeyHubTitle,
                      style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700, color: ds.text))),
            ]),
            const SizedBox(height: Gap.sm),
            Text(t.journeyHubDesc,
                style: AType.bodyMedium.copyWith(height: 1.4, color: ds.muted)),
            const SizedBox(height: Gap.md),
            DsButton(
              expand: true,
              onPressed: _openJourney,
              icon: Icons.navigation_rounded,
              label: t.journeyStartButton,
            ),
          ]),
        ),

        // Safe-arrival check-in
        DsSectionHeader(t.safetyCheckinSection),
        SafetyCheckinCard(
          place: _checkinPlace,
          eta: _checkinEta,
          onSet: _setCheckin,
          onArrived: _markArrived,
        ),
        const SizedBox(height: Gap.lg),
        Text(t.safetyFooterNote, style: AType.bodySmall.copyWith(color: ds.muted)),
      ]),
    );
  }
}
