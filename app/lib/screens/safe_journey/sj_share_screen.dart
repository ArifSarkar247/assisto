import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../services/action_feedback.dart';
import '../../services/journey_tracker.dart' show kPhonesKey;
import '../../services/oem_guide.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/circle_people_filter.dart';
import '../../widgets/journey_ride.dart' show jDigits;
import '../../widgets/permission_reason.dart';
import '../battery_guidance_screen.dart';
import '../journey_live_screen.dart';
import '../journey_start_screen.dart'
    show journeyWatcherRows, journeyNeedsBgSetup, kJourneyBgGuidedKey;
import '../messenger/messenger_home_screen.dart';
import 'sj_live_api.dart';

/// Share-for-a-while presets (minutes). Custom = "until" a time you pick.
const List<int> kSjSharePresets = [60, 180];
const int kSjShareMin = 15;
const int kSjShareMax = 24 * 60;

/// Minutes from [now] until [until] today (tomorrow when already past);
/// null when outside 15 min .. 24 h. Pure.
int? sjMinutesUntil(DateTime now, int hour, int minute) {
  var end = DateTime(now.year, now.month, now.day, hour, minute);
  if (!end.isAfter(now)) end = end.add(const Duration(days: 1));
  final m = end.difference(now).inMinutes;
  return (m >= kSjShareMin && m <= kSjShareMax) ? m : null;
}

/// Before any Live Location starts: the location permission (with the
/// existing honest reason) and — on phones that kill background apps — the
/// existing battery-saver / auto-start Bangla guide. true = go ahead.
Future<bool> sjPrepareLocation(BuildContext context, {OemGuideNative? oem}) async {
  final t = AppLocalizations.of(context);
  try {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied && context.mounted &&
        await showPermissionReason(context, PermKind.journey)) {
      perm = await Geolocator.requestPermission();
    }
  } catch (_) {
    // best-effort: the live screen says "location is off" if it stays off
  }
  OemInfo? info;
  var guided = false;
  try {
    info = await (oem ?? const ChannelOemGuideNative()).info();
    guided = await Settings.getBool(kJourneyBgGuidedKey, false);
  } catch (_) {
    info = null; // best-effort: unknown phone -> never block the start
  }
  if (!journeyNeedsBgSetup(info, guidedBefore: guided) || !context.mounted) return true;
  final pick = await showAppSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        key: const ValueKey('sjl_bg_sheet'),
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.j100bBgSheetTitle,
              style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.sm),
          Text(t.j100bBgSheetBody, style: AType.bodyMedium),
          const SizedBox(height: Gap.md),
          FilledButton.icon(
              key: const ValueKey('sjl_bg_fix'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              icon: const Icon(Icons.build_circle_rounded),
              label: Text(t.j100bBgSheetFix),
              onPressed: () => Navigator.pop(ctx, 'fix')),
          const SizedBox(height: Gap.sm),
          OutlinedButton(
              key: const ValueKey('sjl_bg_skip'),
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: () => Navigator.pop(ctx, 'start'),
              child: Text(t.j100bBgSheetSkip)),
        ]),
      ),
    ),
  );
  if (pick == 'start') return true;
  if (pick == 'fix' && context.mounted) {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => BatteryGuidanceScreen(native: oem)));
    await Settings.setBool(kJourneyBgGuidedKey, true);
  }
  return false;
}

/// sjlive — Card 1, button 4 "Share for a while": 1 h, 3 h or until a time
/// you pick; the people you choose from My Circle see you live; it stops by
/// itself (never "late"); Stop any time on the live screen.
class SjShareScreen extends StatefulWidget {
  final OemGuideNative? oem;
  /// Test seam: the permission + battery-saver step (default
  /// [sjPrepareLocation]; widget tests have no location plugin).
  final Future<bool> Function(BuildContext context)? prepare;
  const SjShareScreen({super.key, this.oem, this.prepare});
  @override
  State<SjShareScreen> createState() => _SjShareScreenState();
}

class _SjShareScreenState extends State<SjShareScreen> {
  List<Map<String, dynamic>> _people = [];
  final Set<int> _picked = {};
  bool _loading = true;
  bool _starting = false;
  int _minutes = 60;
  TimeOfDay? _until; // custom

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await context.read<AppState>().api.getJson('/circle/members');
      _people = journeyWatcherRows(r);
    } catch (_) {
      _people = []; // best-effort: offline -> the add-family step shows
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _pickUntil() async {
    final t = AppLocalizations.of(context);
    final p = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.fromDateTime(DateTime.now().add(const Duration(hours: 2))));
    if (p == null || !mounted) return;
    final m = sjMinutesUntil(DateTime.now(), p.hour, p.minute);
    if (m == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.sjlShareBadTime)));
      return;
    }
    setState(() {
      _until = p;
      _minutes = m;
    });
  }

  Future<void> _start() async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    if (_picked.isEmpty) {
      messenger.showSnackBar(SnackBar(content: Text(t.journeyNeedWatcher)));
      return;
    }
    if (_until != null) {
      // the clock moved while the screen was open: recount from now
      final m = sjMinutesUntil(DateTime.now(), _until!.hour, _until!.minute);
      if (m == null) {
        messenger.showSnackBar(SnackBar(content: Text(t.sjlShareBadTime)));
        return;
      }
      _minutes = m;
    }
    final ready = await (widget.prepare?.call(context) ??
        sjPrepareLocation(context, oem: widget.oem));
    if (!ready || !mounted) return;
    setState(() => _starting = true);
    try {
      final api = context.read<AppState>().api;
      final r = await api.sjShareStart(minutes: _minutes, watcherIds: _picked.toList());
      final id = (r['id'] as num?)?.toInt() ?? 0;
      final phones = _people
          .where((m) => _picked.contains((m['id'] as num?)?.toInt()))
          .map((m) => '${m['phone'] ?? ''}')
          .where((p) => p.isNotEmpty)
          .join(',');
      await Settings.setString(kPhonesKey, phones);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => JourneyLiveScreen(journeyId: id)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _starting = false);
      showActionFailed(context, 'sjlive.share', e);
    }
  }

  String _label(AppLocalizations t, int m) =>
      m % 60 == 0 ? t.sjlHours(jDigits(context, m ~/ 60)) : t.kwMinutes(jDigits(context, m));

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    Widget h(String s) => Padding(
        padding: const EdgeInsets.only(top: Gap.lg, bottom: Gap.sm),
        child: Semantics(
            header: true,
            child: Text(s, style: AType.titleMedium.copyWith(fontWeight: FontWeight.bold))));
    final ids = _people.map((m) => (m['id'] as num?)?.toInt()).whereType<int>().toList();
    final allOn = ids.isNotEmpty && ids.every(_picked.contains);
    return Scaffold(
      appBar: AppBar(title: Text(t.sjlBtnShare)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
              children: [
                Text(t.sjlShareIntro, style: AType.bodyLarge),
                h(t.sjlShareHowLong),
                Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
                  for (final m in kSjSharePresets)
                    ChoiceChip(
                      key: ValueKey('sjl_share_$m'),
                      label: Text(_label(t, m)),
                      selected: _until == null && _minutes == m,
                      onSelected: (_) => setState(() {
                        _until = null;
                        _minutes = m;
                      }),
                    ),
                  ChoiceChip(
                    key: const ValueKey('sjl_share_custom'),
                    avatar: const Icon(Icons.schedule_rounded, size: 18),
                    label: Text(_until == null
                        ? t.sjlShareCustom
                        : t.sjlShareUntil(_until!.format(context))),
                    selected: _until != null,
                    onSelected: (_) => _pickUntil(),
                  ),
                ]),
                h(t.sjlShareWho),
                if (_people.isEmpty) ...[
                  Text(t.journeyNoWatchers, style: AType.bodyMedium),
                  const SizedBox(height: Gap.sm),
                  FilledButton.tonalIcon(
                    key: const ValueKey('sjl_share_add_family'),
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                    icon: const Icon(Icons.person_add_alt_1_rounded),
                    label: Text(t.truthJourneyAddFamily),
                    onPressed: () async {
                      await Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => const MessengerHomeScreen(startAdd: true)));
                      if (mounted) _load();
                    },
                  ),
                ] else
                  Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
                    FilterChip(
                      key: const ValueKey('sjl_share_all'),
                      label: Text(t.j2SelectAll),
                      selected: allOn,
                      onSelected: (v) => setState(() {
                        v ? _picked.addAll(ids) : _picked.clear();
                      }),
                    ),
                    for (final (_, rs) in sectionPeople(_people))
                      for (final p in rs)
                        FilterChip(
                          key: ValueKey('sjl_share_p_${p['id']}'),
                          label: Text('${p['name'] ?? ''}'),
                          selected: _picked.contains((p['id'] as num?)?.toInt()),
                          onSelected: (v) => setState(() {
                            final id = (p['id'] as num?)?.toInt();
                            if (id == null) return;
                            v ? _picked.add(id) : _picked.remove(id);
                          }),
                        ),
                  ]),
                const SizedBox(height: Gap.lg),
                Text(t.sjlShareRules,
                    style: AType.bodySmall.copyWith(color: cs.onSurfaceVariant)),
                const SizedBox(height: Gap.md),
                FilledButton.icon(
                  key: const ValueKey('sjl_share_start'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                  onPressed: _starting ? null : _start,
                  icon: _starting
                      ? const SizedBox(
                          width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.share_location_rounded),
                  label: Text(t.sjlShareStart(_label(t, _minutes))),
                ),
              ],
            ),
    );
  }
}
