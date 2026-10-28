import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../kids_watch_api.dart';
import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/notif_models.dart' show notifLocalizeDigits;
import 'kw_recorder.dart';
import 'school_plan_form.dart' show SchoolEventsSheet;

/// kidswatch — the CHILD's side of School Mode (route `school_mode`, never
/// hidden by a flag: transparency and the one-tap stop must always work).
///
///  * always shows that School Mode is on and WHO sees it;
///  * a phone plan does nothing until the child taps "I agree";
///  * ONE big button — "leaving now" / "reached" (kwLeavingNow / kwReached) — sends the location of THAT moment (only if the child
///    allows; foreground only, no background location) and an optional
///    voice note; "I'm OK" (kwImOk) answers the "are you OK?" question;
///  * stop in one tap, pause for today, delete the history.
class SchoolModeChildScreen extends StatefulWidget {
  const SchoolModeChildScreen({super.key, this.locate});

  /// Test seam: the phone's location right now (default: Geolocator,
  /// foreground permission only).
  final Future<({double lat, double lng})?> Function()? locate;

  @override
  State<SchoolModeChildScreen> createState() => _SchoolModeChildScreenState();
}

class _SchoolModeChildScreenState extends State<SchoolModeChildScreen> {
  ApiClient get _api => context.read<AppState>().api;
  bool _loading = true;
  bool _failed = false;
  bool _busy = false;
  bool _shareLocation = true;
  List<Map<String, dynamic>> _plans = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final r = await _api.smMine();
      if (!mounted) return;
      setState(() {
        _plans = kwRows(r, 'plans');
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<({double lat, double lng})?> _locate() async {
    if (widget.locate != null) return widget.locate!();
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        return null;
      }
      final p = await Geolocator.getCurrentPosition().timeout(const Duration(seconds: 10));
      return (lat: p.latitude, lng: p.longitude);
    } catch (_) {
      return null;
    }
  }

  Future<void> _checkin(Map<String, dynamic> p, String kind, {bool voice = false}) async {
    final t = AppLocalizations.of(context);
    List<int>? audio;
    if (voice) {
      audio = await showKwRecorder(context, amr: false);
      if (audio == null || !mounted) return;
    }
    setState(() => _busy = true);
    try {
      final loc = _shareLocation ? await _locate() : null;
      await _api.smCheckin(p['id'] as int, kind, lat: loc?.lat, lng: loc?.lng, audio: audio);
      if (!mounted) return;
      final String done = switch (kind) {
        'ok' => t.kwSentOk,
        'leaving' => t.kwSentLeaving,
        _ => t.kwSentArrived,
      };
      _snack(loc == null && _shareLocation ? '$done ${t.kwNoLocationSent}' : done);
      await _load();
    } catch (e) {
      if (mounted) {
        _snack(e is ApiException && e.message.isNotEmpty ? e.message : t.kwActionFailed);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _action(Map<String, dynamic> p, String action) async {
    final t = AppLocalizations.of(context);
    if (action == 'stop') {
      final yes = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          scrollable: true,
          title: Text(t.kwStopQ),
          content: Text(t.kwStopBody),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.kwStop)),
          ],
        ),
      );
      if (yes != true || !mounted) return;
    }
    try {
      await _api.smAction(p['id'] as int, action);
      await _load();
    } catch (e) {
      if (mounted) _snack(t.kwActionFailed);
    }
  }

  Future<void> _history(Map<String, dynamic> p) => showAppSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => SchoolEventsSheet(plan: p),
      );

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.kwChildTitle)),
      body: _body(t),
    );
  }

  Widget _body(AppLocalizations t) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_failed) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(t.kwLoadFailed, textAlign: TextAlign.center, style: AType.bodyLarge),
            const SizedBox(height: Gap.md),
            FilledButton.icon(
                onPressed: _load, icon: const Icon(Icons.refresh_rounded), label: Text(t.kwRetry)),
          ]),
        ),
      );
    }
    if (_plans.isEmpty) {
      return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
        const Icon(Icons.school_rounded, size: 56),
        const SizedBox(height: Gap.md),
        Text(t.kwChildEmpty, textAlign: TextAlign.center, style: AType.bodyLarge),
      ]);
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xl)),
        children: [for (final p in _plans) _plan(t, p)],
      ),
    );
  }

  Widget _plan(AppLocalizations t, Map<String, dynamic> p) {
    final scheme = Theme.of(context).colorScheme;
    final watchers = kwRows(p, 'watchers').map((w) => '${w['name']}').join(', ');
    final accepted = p['accepted'] == true;
    final enabled = p['enabled'] == true;
    final phone = p['mode'] == 'phone';
    final today = (p['today'] as Map?)?.cast<String, dynamic>() ?? const {};
    final asked = (today['ask'] as Map?)?.isNotEmpty == true;
    final st = '${today['state'] ?? 'idle'}';
    final arriveNext = st == 'to_school' || st == 'to_home';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // the banner: on + who sees, always first
      Container(
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          color: enabled ? scheme.primaryContainer : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(children: [
          Icon(enabled ? Icons.visibility_rounded : Icons.visibility_off_rounded,
              color: enabled ? scheme.onPrimaryContainer : scheme.onSurfaceVariant),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(
              !enabled ? t.kwChildOff : (accepted ? t.kwChildOnSeenBy(watchers) : t.kwChildInvite(watchers)),
              style: AType.bodyLarge.copyWith(
                  color: enabled ? scheme.onPrimaryContainer : scheme.onSurfaceVariant),
            ),
          ),
        ]),
      ),
      const SizedBox(height: Gap.sm),
      Text(phone ? t.kwChildWhatPhone : t.kwChildWhatWatch, style: AType.bodyMedium),
      const SizedBox(height: Gap.md),
      if (enabled && !accepted)
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
          onPressed: () => _action(p, 'accept'),
          child: Text(t.kwAgree),
        ),
      if (enabled && accepted && phone) ...[
        if (asked)
          FilledButton.icon(
            style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(64), backgroundColor: Brand.danger),
            onPressed: _busy ? null : () => _checkin(p, 'ok'),
            icon: const Icon(Icons.favorite_rounded),
            label: Text(t.kwImOk, style: AType.titleMedium),
          ),
        if (asked) const SizedBox(height: Gap.sm),
        FilledButton.icon(
          key: const ValueKey('kw-big-button'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(88)),
          onPressed: _busy ? null : () => _checkin(p, arriveNext ? 'arrived' : 'leaving'),
          icon: Icon(arriveNext ? Icons.where_to_vote_rounded : Icons.directions_walk_rounded,
              size: 32),
          label: Text(arriveNext ? t.kwReached : t.kwLeavingNow,
              textAlign: TextAlign.center,
              style: AType.headlineSmall.copyWith(color: scheme.onPrimary)),
        ),
        const SizedBox(height: Gap.sm),
        OutlinedButton(
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: _busy ? null : () => _checkin(p, arriveNext ? 'leaving' : 'arrived'),
          child: Text(arriveNext ? t.kwLeavingNow : t.kwReached),
        ),
        const SizedBox(height: Gap.sm),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: _busy ? null : () => _checkin(p, arriveNext ? 'arrived' : 'leaving', voice: true),
          icon: const Icon(Icons.mic_rounded),
          label: Text(t.kwWithVoice),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _shareLocation,
          title: Text(t.kwShareLocationNow),
          subtitle: Text(t.kwShareLocationSub),
          onChanged: (v) => setState(() => _shareLocation = v),
        ),
      ],
      if (accepted && today['arrive_due'] != null && enabled)
        Text(t.kwExpectedBy(notifLocalizeDigits(context, kwClock(today['arrive_due'])),
                notifLocalizeDigits(context, kwClock(today['home_due']))),
            style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
      const SizedBox(height: Gap.md),
      Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
        if (enabled && accepted)
          OutlinedButton.icon(
              onPressed: () => _action(p, today['paused'] == true ? 'resume-today' : 'pause-today'),
              icon: const Icon(Icons.pause_circle_outline_rounded),
              label: Text(today['paused'] == true ? t.kwResumeToday : t.kwPauseToday)),
        OutlinedButton.icon(
            onPressed: () => _history(p),
            icon: const Icon(Icons.history_rounded),
            label: Text(t.kwHistory)),
        if (enabled)
          TextButton.icon(
              onPressed: () => _action(p, 'stop'),
              icon: Icon(Icons.stop_circle_outlined, color: scheme.error),
              label: Text(accepted ? t.kwStop : t.kwDecline,
                  style: TextStyle(color: scheme.error))),
      ]),
      const Divider(height: Gap.xxl),
    ]);
  }
}
