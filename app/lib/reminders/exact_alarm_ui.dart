import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_localizations.dart';
import '../notifications.dart';
import '../push/push_payload.dart' show PushPayload;
import '../screens/battery_guidance_screen.dart';
import '../services/oem_guide.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/notif_models.dart' show notifLocalizeDigits;
import 'alarm_plan.dart';
import 'reminder_alarms.dart';
import 'package:assisto/widgets/app_sheet.dart';

/// remmeter — the honest UI around exact reminder alarms.
///
///  * [maybeAskExactAlarms] — after a TIMED reminder is saved: if Android
///    is not letting Assisto set exact alarms, explain why it matters and
///    offer the system "Alarms & reminders" page (at most every 3 days).
///  * [ExactAlarmBanner] — on the Reminders screen while exact alarms are
///    off: "may ring a few minutes late", Turn on + Battery guide.
///  * [ReminderDeliverySheet] — "Delivery check": notifications, exact
///    alarms, battery, measured lateness on THIS phone, and a 1-minute test.

/// Test seams (widget tests / gallery replace these).
class ExactAlarmHooks {
  ExactAlarmHooks._();
  static Future<bool> Function() canExact = Notifications.canScheduleExact;
  static Future<bool> Function() requestExact = Notifications.requestExact;
  static Future<bool> Function() notifEnabled = Notifications.isEnabled;
  static Future<bool> Function() shouldExplain =
      () => ReminderAlarms.shouldExplainExact();
  static OemGuideNative oem = const ChannelOemGuideNative();
}

Future<void> maybeAskExactAlarms(BuildContext context) async {
  bool ask;
  try {
    ask = await ExactAlarmHooks.shouldExplain();
  } catch (_) {
    ask = false;
  }
  if (!ask || !context.mounted) return;
  await ReminderAlarms.markExplained();
  if (!context.mounted) return;
  final allow = await showAppSheet<bool>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => const _ExactExplainSheet(),
  );
  if (allow == true) {
    await ExactAlarmHooks.requestExact();
    if (context.mounted) {
      try {
        context.read<AppState>().syncReminderAlarms();
      } catch (_) {} // best-effort: a status read / re-sync; the sheet shows "unknown" or retries on resume
    }
  }
}

class _ExactExplainSheet extends StatelessWidget {
  const _ExactExplainSheet();

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.alarm_on_rounded, color: scheme.primary),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(t.rmxExactTitle,
                      style: Theme.of(context).textTheme.titleLarge),
                ),
              ),
            ]),
            const SizedBox(height: Gap.md),
            Text(t.rmxExactBody, style: AType.bodyMedium),
            const SizedBox(height: Gap.sm),
            Text(t.rmxExactHow,
                style: AType.bodySmall
                    .copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: Gap.lg),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48)),
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(t.rmxLater),
                ),
              ),
              const SizedBox(width: Gap.md),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48)),
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(t.rmxAllow),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

/// Shown on the Reminders screen while exact alarms are OFF (Android 12+).
/// Hidden when on, or when we can't tell (never a banner we can't justify).
class ExactAlarmBanner extends StatefulWidget {
  const ExactAlarmBanner({super.key});

  @override
  State<ExactAlarmBanner> createState() => _ExactAlarmBannerState();
}

class _ExactAlarmBannerState extends State<ExactAlarmBanner>
    with WidgetsBindingObserver {
  bool _off = false;
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    bool on;
    try {
      // only meaningful once local notifications are up
      on = !Notifications.ready || await ExactAlarmHooks.canExact();
    } catch (_) {
      on = true;
    }
    if (mounted && _off == on) setState(() => _off = !on);
  }

  Future<void> _allow() async {
    await ExactAlarmHooks.requestExact();
    if (mounted) {
      try {
        context.read<AppState>().syncReminderAlarms();
      } catch (_) {} // best-effort: a status read / re-sync; the sheet shows "unknown" or retries on resume
    }
    await _check();
  }

  @override
  Widget build(BuildContext context) {
    if (!_off || _dismissed) return const SizedBox.shrink();
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final fg = scheme.onTertiaryContainer;
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, 0),
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.xs, Gap.sm),
        decoration: BoxDecoration(
          color: scheme.tertiaryContainer,
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: Gap.xxs),
              child: Icon(Icons.timer_off_rounded, size: 18, color: fg),
            ),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t.rmxBannerTitle,
                      style: AType.titleSmall
                          .copyWith(fontWeight: FontWeight.w700, color: fg)),
                  const SizedBox(height: Gap.xxs),
                  Text(t.rmxBannerBody,
                      style: AType.bodySmall.copyWith(color: fg)),
                  const SizedBox(height: Gap.xs),
                  Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
                    FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(
                          minimumSize: const Size(48, 48)),
                      onPressed: _allow,
                      icon: const Icon(Icons.alarm_on_rounded, size: 18),
                      label: Text(t.rmxBannerAllow),
                    ),
                    TextButton.icon(
                      style: TextButton.styleFrom(
                          foregroundColor: fg,
                          minimumSize: const Size(48, 48)),
                      onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const BatteryGuidanceScreen())),
                      icon: const Icon(Icons.battery_saver_rounded, size: 18),
                      label: Text(t.rmxBatteryGuide),
                    ),
                  ]),
                ],
              ),
            ),
            IconButton(
              tooltip: t.close,
              color: fg,
              onPressed: () => setState(() => _dismissed = true),
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Delivery check" — everything that decides whether a reminder rings on
/// time on THIS phone, plus real measured lateness and a 1-minute test.
class ReminderDeliverySheet extends StatefulWidget {
  const ReminderDeliverySheet({super.key});

  static Future<void> open(BuildContext context) => showAppSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => const ReminderDeliverySheet(),
      );

  @override
  State<ReminderDeliverySheet> createState() => _ReminderDeliverySheetState();
}

class _ReminderDeliverySheetState extends State<ReminderDeliverySheet> {
  bool? _notif;
  bool? _exact;
  bool? _battery; // true = not optimised (good)
  DeliveryStats? _stats;
  bool _testSet = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    bool? n, e, b;
    try {
      n = await ExactAlarmHooks.notifEnabled();
    } catch (_) {} // best-effort: a status read / re-sync; the sheet shows "unknown" or retries on resume
    try {
      e = await ExactAlarmHooks.canExact();
    } catch (_) {} // best-effort: a status read / re-sync; the sheet shows "unknown" or retries on resume
    try {
      b = (await ExactAlarmHooks.oem.info())?.batteryOptIgnored;
    } catch (_) {} // best-effort: a status read / re-sync; the sheet shows "unknown" or retries on resume
    DeliveryStats s = DeliveryStats.of(const []);
    try {
      await ReminderAlarms.measure();
      s = DeliveryStats.of(
          ReminderAlarms.loadLog(await SharedPreferences.getInstance()));
    } catch (_) {} // best-effort: a status read / re-sync; the sheet shows "unknown" or retries on resume
    if (!mounted) return;
    setState(() {
      _notif = n;
      _exact = e;
      _battery = b;
      _stats = s;
    });
  }

  Future<void> _test() async {
    final t = AppLocalizations.of(context);
    final exact = _exact ?? false;
    final at = DateTime.now().add(const Duration(minutes: 1));
    final key = 'remtest-${at.millisecondsSinceEpoch}';
    final used = await Notifications.scheduleAlarm(
        PushPayload.stableHash('remtest'), t.rmxTestTitle, t.rmxTestBody, at,
        mode: exact ? AlarmMode.exact : AlarmMode.inexact,
        payload: '${ReminderAlarms.payloadPrefix}$key');
    await ReminderAlarms.rememberTest(at, used ?? AlarmMode.inexact);
    if (mounted) setState(() => _testSet = used != null);
  }

  String _d(String s) => notifLocalizeDigits(context, s);

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final tokens = AssistoTokens.of(context);
    Widget row(IconData icon, Color c, String text) => Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.xs),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, size: 20, color: c),
            const SizedBox(width: Gap.sm),
            Expanded(child: Text(text, style: AType.bodyMedium)),
          ]),
        );
    final s = _stats;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text(t.rmxCheckTitle,
                  style: Theme.of(context).textTheme.titleLarge),
            ),
            const SizedBox(height: Gap.md),
            if (s == null)
              const Padding(
                padding: EdgeInsets.all(Gap.lg),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              _notif == false
                  ? row(Icons.notifications_off_rounded, scheme.error,
                      t.rmxCheckNotifOff)
                  : row(Icons.notifications_active_rounded, tokens.success,
                      t.rmxCheckNotifOn),
              _exact == true
                  ? row(Icons.alarm_on_rounded, tokens.success,
                      t.rmxCheckExactOn)
                  : row(Icons.timer_off_rounded, scheme.error,
                      t.rmxCheckExactOff),
              switch (_battery) {
                true => row(Icons.battery_full_rounded, tokens.success,
                    t.rmxCheckBatteryOk),
                false => row(Icons.battery_alert_rounded, scheme.error,
                    t.rmxCheckBatteryOpt),
                null => row(Icons.battery_unknown_rounded,
                    scheme.onSurfaceVariant, t.rmxCheckBatteryUnknown),
              },
              row(Icons.cloud_done_rounded, scheme.onSurfaceVariant,
                  t.rmxCheckServerBackup),
              const Divider(height: Gap.xl),
              if (s.count == 0)
                Text(t.rmxCheckNone, style: AType.bodyMedium)
              else ...[
                Text(
                    t.rmxCheckMeasured(_d('${s.count}'), _d('${s.onTime}'),
                        _d('${s.medianSeconds}')),
                    style: AType.bodyMedium
                        .copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: Gap.xxs),
                Text(t.rmxCheckWorst(_d('${s.worstSeconds}')),
                    style: AType.bodySmall
                        .copyWith(color: scheme.onSurfaceVariant)),
              ],
              const SizedBox(height: Gap.xs),
              Text(t.rmxCheckPrivacy,
                  style:
                      AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
              const SizedBox(height: Gap.lg),
              if (_exact != true) ...[
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48)),
                  onPressed: () async {
                    await ExactAlarmHooks.requestExact();
                    if (context.mounted) {
                      try {
                        context.read<AppState>().syncReminderAlarms();
                      } catch (_) {} // best-effort: a status read / re-sync; the sheet shows "unknown" or retries on resume
                    }
                    await _load();
                  },
                  icon: const Icon(Icons.alarm_on_rounded),
                  label: Text(t.rmxBannerAllow),
                ),
                const SizedBox(height: Gap.sm),
              ],
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48)),
                onPressed: _testSet ? null : _test,
                icon: const Icon(Icons.timer_rounded),
                label: Text(_testSet ? t.rmxCheckTestSet : t.rmxCheckTest),
              ),
              const SizedBox(height: Gap.sm),
              TextButton.icon(
                style: TextButton.styleFrom(
                    minimumSize: const Size.fromHeight(48)),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const BatteryGuidanceScreen())),
                icon: const Icon(Icons.battery_saver_rounded),
                label: Text(t.rmxBatteryGuide),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
