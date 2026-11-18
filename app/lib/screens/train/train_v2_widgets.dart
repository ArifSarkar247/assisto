import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../ds/ds.dart';
import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import '../../train/dest_alarm_service.dart';
import '../../train/train_offline.dart';
import '../../train/train_share_service.dart';
import '../../widgets/notif_models.dart' show notifLocalizeDigits;

/// train-app (Train Tracker V2): the small V2 pieces of the train screen —
/// the freshness chip (never "100 % accurate"), the rider card + consent
/// sheet, the one-time "Are you on this train?" prompt, the station
/// check-in sheet and the offline-pack card.

/// Gallery seam: the review shots capture sheets fully open (no slide-in).
bool trainSheetsInstant = false;

/// How fresh the shown position is: live | stale (N min ago) | predicted |
/// timetable | offline_tower | offline_timetable.
class TrainFresh {
  final String kind;
  final int ageMin;
  const TrainFresh(this.kind, [this.ageMin = 0]);
}

/// [sinceLoadS]: seconds since this answer arrived (no internet for a
/// while -> "live" turns into "N min ago" on its own).
TrainFresh trainFreshOf(Map<String, dynamic> v, {int sinceLoadS = 0}) {
  final f = v['freshness'];
  final live = v['live'] is Map ? v['live'] as Map : null;
  int ageS = (live?['age_s'] as num?)?.toInt() ?? 0;
  String? state;
  if (f is Map) {
    state = '${f['state'] ?? ''}';
    ageS = (f['age_s'] as num?)?.toInt() ?? ageS;
  }
  ageS += sinceLoadS;
  state ??= live != null ? (ageS <= 120 ? 'live' : 'stale') : 'timetable';
  if (state == 'estimate') state = 'timetable';
  if (state == 'live' && ageS > 120) state = 'stale';
  if (!{'live', 'stale', 'predicted', 'timetable'}.contains(state)) state = 'timetable';
  return TrainFresh(state, (ageS / 60).ceil());
}

String trainFreshLabel(AppLocalizations t, TrainFresh f) => switch (f.kind) {
      'live' => t.tr2FreshLive,
      'stale' => t.tr2FreshAgo('${f.ageMin < 1 ? 1 : f.ageMin}'),
      'predicted' => t.tr2FreshPredicted,
      'offline_tower' => t.tr2FreshTower,
      'offline_timetable' => t.tr2FreshOfflineTt,
      _ => t.tr2FreshTimetable,
    };

class TrainFreshChip extends StatelessWidget {
  const TrainFreshChip({super.key, required this.fresh});
  final TrainFresh fresh;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final ds = Theme.of(context).colorScheme.ds;
    final (Color bg, Color fg, IconData icon) = switch (fresh.kind) {
      'live' => (ds.successBg, ds.successInk, Icons.sensors_rounded),
      'stale' => (ds.cardHigh, ds.text, Icons.history_rounded),
      'predicted' => (ds.primarySoft, ds.primaryInk, Icons.insights_rounded),
      'offline_tower' => (ds.cardHigh, ds.text, Icons.cell_tower_rounded),
      'offline_timetable' => (ds.cardHigh, ds.text, Icons.cloud_off_rounded),
      _ => (ds.cardHigh, ds.text, Icons.schedule_rounded),
    };
    final label = notifLocalizeDigits(context, trainFreshLabel(t, fresh));
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Container(
        key: const ValueKey('tr2_fresh'),
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xs),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 16, color: fg),
          const SizedBox(width: Gap.xs),
          Flexible(
              child: Text(label,
                  style: AType.labelLarge.copyWith(color: fg, fontWeight: FontWeight.w700))),
        ]),
      ),
    );
  }
}

/// The four rider benefits (shown on the consent sheet and the ask prompt).
class TrainRiderBenefits extends StatelessWidget {
  const TrainRiderBenefits({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final ds = Theme.of(context).colorScheme.ds;
    Widget row(IconData i, String s) => Padding(
          padding: const EdgeInsets.only(bottom: Gap.xs),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(i, size: 20, color: ds.primaryInk),
            const SizedBox(width: Gap.sm),
            Expanded(child: Text(s, style: AType.bodyMedium)),
          ]),
        );
    return Column(key: const ValueKey('tr2_benefits'), crossAxisAlignment: CrossAxisAlignment.start, children: [
      row(Icons.cloud_off_rounded, t.tr2BenefitOffline),
      row(Icons.alarm_rounded, t.tr2BenefitAlarm),
      row(Icons.family_restroom_rounded, t.tr2BenefitFamily),
      row(Icons.stars_rounded, t.tr2BenefitPoints),
    ]);
  }
}

/// Consent before sharing: what is shared, the benefits, the optional
/// mobile-tower yes. Returns null (cancel) or (start, cell).
Future<(bool, bool)?> showTrainShareConsent(BuildContext context) {
  final t = AppLocalizations.of(context);
  var cell = false;
  return showAppSheet<(bool, bool)>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    sheetAnimationStyle: trainSheetsInstant ? AnimationStyle.noAnimation : null,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.trShareTitle, style: AType.titleLarge),
          const SizedBox(height: Gap.sm),
          Text(t.trShareConsent, style: AType.bodyMedium),
          const SizedBox(height: Gap.md),
          const TrainRiderBenefits(),
          const SizedBox(height: Gap.xs),
          SwitchListTile(
            key: const ValueKey('tr2_cell_optin'),
            contentPadding: EdgeInsets.zero,
            value: cell,
            onChanged: (v) => set(() => cell = v),
            title: Text(t.tr2CellOptIn, style: AType.titleSmall),
            subtitle: Text(t.tr2CellOptInSub, style: AType.bodySmall),
          ),
          const SizedBox(height: Gap.sm),
          DsButton(
            buttonKey: const ValueKey('tr2_share_go'),
            expand: true,
            icon: Icons.my_location_rounded,
            label: t.trShareStart,
            onPressed: () => Navigator.pop(ctx, (true, cell)),
          ),
          const SizedBox(height: Gap.xs),
          DsButton.secondary(
            expand: true,
            label: t.trCancel,
            onPressed: () => Navigator.pop(ctx),
          ),
        ]),
      ),
    ),
  );
}

/// The one-time "Are you on this train?" prompt (phone moves along this
/// line at train speed while the screen is open). true = yes, share.
Future<bool> showTrainOnboardAsk(BuildContext context, String trainName) async {
  final t = AppLocalizations.of(context);
  final r = await showAppSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    sheetAnimationStyle: trainSheetsInstant ? AnimationStyle.noAnimation : null,
    builder: (ctx) => SingleChildScrollView(
      key: const ValueKey('tr2_ask_sheet'),
      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Semantics(header: true, child: Text(t.tr2AskTitle(trainName), style: AType.titleLarge)),
        const SizedBox(height: Gap.sm),
        Text(t.tr2AskBody, style: AType.bodyMedium),
        const SizedBox(height: Gap.md),
        const TrainRiderBenefits(),
        const SizedBox(height: Gap.sm),
        DsButton(
          buttonKey: const ValueKey('tr2_ask_yes'),
          expand: true,
          icon: Icons.check_rounded,
          label: t.tr2AskYes,
          onPressed: () => Navigator.pop(ctx, true),
        ),
        const SizedBox(height: Gap.xs),
        DsButton.secondary(
          buttonKey: const ValueKey('tr2_ask_no'),
          expand: true,
          label: t.tr2AskNo,
          onPressed: () => Navigator.pop(ctx, false),
        ),
      ]),
    ),
  );
  return r == true;
}

/// The rider status under the toggle (sharing / saved offline / saver).
class TrainRiderStatus extends StatelessWidget {
  const TrainRiderStatus({super.key, required this.state});
  final TrainShareState state;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    String d(String s) => notifLocalizeDigits(context, s);
    final lines = <String>[
      state.offline ? d(t.sjtShareOffline('${state.queued}')) : d(t.trShareCounts('${state.accepted}', '${state.rejected}')),
      if (state.saver) t.tr2Saver,
      t.tr2AutoStop,
    ];
    return Padding(
      padding: const EdgeInsets.only(top: Gap.xs),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (var i = 0; i < lines.length; i++)
          Text(lines[i],
              key: i == 0 ? const ValueKey('sjt_share_state') : null,
              style: AType.bodySmall.copyWith(color: i == 0 && state.offline ? Brand.warnInk(context) : null)),
      ]),
    );
  }
}

/// Station tap: one-tap check-in (reached / left) + the get-off alarm.
/// Returns 'reached' | 'left' | 'alarm' | null.
Future<String?> showTrainStationSheet(BuildContext context, String name, {required bool alarm}) {
  final t = AppLocalizations.of(context);
  return showAppSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    sheetAnimationStyle: trainSheetsInstant ? AnimationStyle.noAnimation : null,
    builder: (ctx) => SingleChildScrollView(
      key: const ValueKey('tr2_station_sheet'),
      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Semantics(header: true, child: Text(name, style: AType.titleLarge)),
        const SizedBox(height: Gap.xs),
        Text(t.tr2CheckinWhy, style: AType.bodySmall.copyWith(color: Theme.of(ctx).colorScheme.ds.muted)),
        const SizedBox(height: Gap.md),
        DsButton(
          buttonKey: const ValueKey('tr2_ci_reached'),
          expand: true,
          icon: Icons.login_rounded,
          label: t.tr2CheckinReached,
          onPressed: () => Navigator.pop(ctx, 'reached'),
        ),
        const SizedBox(height: Gap.sm),
        DsButton(
          buttonKey: const ValueKey('tr2_ci_left'),
          expand: true,
          icon: Icons.logout_rounded,
          label: t.tr2CheckinLeft,
          onPressed: () => Navigator.pop(ctx, 'left'),
        ),
        if (alarm) ...[
          const SizedBox(height: Gap.sm),
          DsButton.secondary(
            buttonKey: const ValueKey('tr2_ci_alarm'),
            expand: true,
            icon: Icons.alarm_add_rounded,
            label: t.sjtGetOffAlarm,
            onPressed: () => Navigator.pop(ctx, 'alarm'),
          ),
        ],
      ]),
    ),
  );
}

/// "Use without internet": every timetable + the tower map on the phone.
class TrainOfflineCard extends StatelessWidget {
  const TrainOfflineCard(
      {super.key,
      required this.store,
      required this.sizeBytes,
      required this.onDownload,
      this.failed = false});
  final TrainOfflineStore store;

  /// the server's size of the current pack (null = not known yet)
  final int? sizeBytes;
  final VoidCallback onDownload;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final ds = Theme.of(context).colorScheme.ds;
    String d(String s) => notifLocalizeDigits(context, s);
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final p = store.pack;
        final saved = p?.savedAt;
        final size = sizeBytes == null ? '' : d(trainSizeLabel(sizeBytes!));
        return DsCard(
          key: const ValueKey('tr2_offline_card'),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(p == null ? Icons.download_for_offline_rounded : Icons.offline_pin_rounded,
                  color: p == null ? ds.primaryInk : ds.successInk),
              const SizedBox(width: Gap.sm),
              Expanded(child: Text(t.tr2OffTitle, style: AType.titleMedium)),
            ]),
            const SizedBox(height: Gap.xs),
            Text(t.tr2OffBody, style: AType.bodyMedium.copyWith(color: ds.muted)),
            if (p != null && saved != null) ...[
              const SizedBox(height: Gap.xs),
              Text(
                  d(t.tr2OffReady('${p.trains.length}',
                      '${saved.day.toString().padLeft(2, '0')}/${saved.month.toString().padLeft(2, '0')}')),
                  key: const ValueKey('tr2_offline_ready'),
                  style: AType.bodySmall.copyWith(color: ds.successInk, fontWeight: FontWeight.w700)),
            ],
            if (failed)
              Padding(
                padding: const EdgeInsets.only(top: Gap.xs),
                child: Text(t.tr2OffFailed, style: AType.bodySmall.copyWith(color: ds.dangerInk)),
              ),
            const SizedBox(height: Gap.sm),
            if (p == null || p.stale)
              DsButton(
                buttonKey: const ValueKey('tr2_offline_get'),
                expand: true,
                busy: store.busy,
                icon: Icons.download_rounded,
                label: store.busy
                    ? t.tr2OffDownloading
                    : (p == null
                        ? (size.isEmpty ? t.tr2OffDownloadNoSize : t.tr2OffDownload(size))
                        : (size.isEmpty ? t.tr2OffUpdateNoSize : t.tr2OffUpdate(size))),
                onPressed: store.busy ? null : onDownload,
              )
            else
              Text(t.tr2OffWeekly, style: AType.bodySmall.copyWith(color: ds.muted)),
          ]),
        );
      },
    );
  }
}

// ------------------------------------------------- destination alarm link

String _alarmAskKey(String no, String date) => 'train_alarm_share_asked_${no}_$date';

Future<bool> trainAlarmShareAsked(String no, String date) async {
  try {
    return (await SharedPreferences.getInstance()).getBool(_alarmAskKey(no, date)) ?? false;
  } catch (_) {
    return true; // can't remember -> never nag
  }
}

Future<void> trainAlarmShareMarkAsked(String no, String date) async {
  try {
    await (await SharedPreferences.getInstance()).setBool(_alarmAskKey(no, date), true);
  } catch (_) {
    // best-effort
  }
}

/// Asked ONCE when a train get-off alarm starts. true = share.
Future<bool> showTrainAlarmShareAsk(BuildContext context) async {
  final t = AppLocalizations.of(context);
  final r = await showAppSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    sheetAnimationStyle: trainSheetsInstant ? AnimationStyle.noAnimation : null,
    builder: (ctx) => SingleChildScrollView(
      key: const ValueKey('tr2_alarm_ask'),
      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Semantics(header: true, child: Text(t.tr2AlarmAskTitle, style: AType.titleLarge)),
        const SizedBox(height: Gap.sm),
        Text(t.tr2AlarmAskBody, style: AType.bodyMedium),
        const SizedBox(height: Gap.md),
        DsButton(
          buttonKey: const ValueKey('tr2_alarm_yes'),
          expand: true,
          icon: Icons.my_location_rounded,
          label: t.tr2AlarmAskYes,
          onPressed: () => Navigator.pop(ctx, true),
        ),
        const SizedBox(height: Gap.xs),
        DsButton.secondary(
          buttonKey: const ValueKey('tr2_alarm_no'),
          expand: true,
          label: t.tr2AlarmAskNo,
          onPressed: () => Navigator.pop(ctx, false),
        ),
      ]),
    ),
  );
  return r == true;
}

/// A share started from the alarm prompt stops when the alarm ends.
class TrainAlarmShareLink {
  TrainAlarmShareLink._();
  static final TrainAlarmShareLink I = TrainAlarmShareLink._();
  bool _on = false;

  void watch() {
    if (_on) return;
    _on = true;
    DestAlarmController.I.addListener(_check);
  }

  void _check() {
    if (DestAlarmController.I.on) return;
    DestAlarmController.I.removeListener(_check);
    _on = false;
    final sh = TrainShareController.I;
    if (sh.sharing && sh.value.by == 'alarm') unawaited(sh.stop());
  }
}
