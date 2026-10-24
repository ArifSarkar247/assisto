import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../antitheft_api.dart';
import '../api.dart';
import '../config.dart';
import '../l10n/app_localizations.dart';
import '../services/antitheft_service.dart';
import '../services/security_guard.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/false_alarm_button.dart';
import 'phone_safety_screen.dart';
import '../services/error_report.dart';
import '../services/error_kind.dart' show honestFailText; // qa2

/// b6-antitheft — "Always-on protection" (the native Lost/Stolen engine).
///
/// The user turns this ON themselves (Security PIN). While on, an opt-in
/// foreground service reports heartbeats + events to the server; alerts go
/// ONLY to the owner and the family members the owner approves here. Turning
/// it OFF needs the Security PIN again (Section 8), so a thief who grabbed an
/// unlocked phone cannot silently switch protection off.
///
/// HONESTY: the "is it really running?" truth is the native [isRunning] check,
/// not a stored flag. Capabilities reported by the phone drive a plain-spoken
/// limits card (SIM number usually unreadable, airplane/power-off cannot be
/// blocked, background camera restricted on modern Android).
class AlwaysOnProtectionScreen extends StatefulWidget {
  const AlwaysOnProtectionScreen({super.key});

  @override
  State<AlwaysOnProtectionScreen> createState() =>
      _AlwaysOnProtectionScreenState();
}

class _AlwaysOnProtectionScreenState extends State<AlwaysOnProtectionScreen>
    with WidgetsBindingObserver {
  bool _loading = true;
  bool _failed = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)
  bool _busy = false;
  bool _running = false; // native foreground-service truth
  Map<String, dynamic> _state = const {};
  Map<String, dynamic> _caps = const {};

  ApiClient get _api => context.read<AppState>().api;

  bool get _enabled => _state['enabled'] == true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // at-falsealarm: the owner is handling his own phone on this screen —
    // no snatch detection while it is visible.
    AntiTheftService.setQuiet(true);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AntiTheftService.setQuiet(false);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) {
      AntiTheftService.setQuiet(true);
      _refreshRunning();
    } else if (s == AppLifecycleState.paused ||
        s == AppLifecycleState.hidden ||
        s == AppLifecycleState.detached) {
      AntiTheftService.setQuiet(false);
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final st = await _api.engineState();
      Map<String, dynamic> caps = const {};
      try {
        caps = await AntiTheftService.capabilities();
      } catch (e) {
        // best-effort: unknown capabilities -> the screen shows the safe
        // defaults (camera option disabled with its reason).
        reportNonFatal('antitheft.capabilities', e);
      }
      var running = await AntiTheftService.isRunning();
      // After a restart (or if the OS stopped it) the native engine still has
      // its scoped token: resume it now that the owner is looking at this
      // screen in the foreground. Never at app launch, only here.
      if (st['enabled'] == true && !running) {
        await AntiTheftService.flushNow();
        running = await AntiTheftService.isRunning();
      }
      if (!mounted) return;
      setState(() {
        _state = st;
        _caps = caps;
        _running = running;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _failCause = e;
        _loading = false;
      });
    }
  }

  Future<void> _refreshRunning() async {
    final r = await AntiTheftService.isRunning();
    if (mounted) setState(() => _running = r);
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  // ---- enable / disable --------------------------------------------------

  Future<void> _enable() async {
    final tr = AppLocalizations.of(context);
    if ((_state['has_pin'] ?? false) != true) {
      _snack(tr.atNeedsPinFirst);
      return;
    }
    final pin = await const SecurityGuard().askPin(context, tr);
    if (pin == null || pin.isEmpty || !mounted) return;
    setState(() => _busy = true);
    try {
      final caps = _caps.isEmpty ? await AntiTheftService.capabilities() : _caps;
      final resp = await _api.engineEnable(pin: pin, capabilities: caps);
      final st = resp['_status'] as int?;
      if (resp['ok'] != true || (st != null && st >= 400)) {
        _snack(resp['locked'] == true ? tr.securityLockedOut : tr.securityBadPin);
        return;
      }
      final token = '${resp['engine_token'] ?? ''}';
      if (token.isNotEmpty) {
        // The engine reports the phone's LAST location, so it needs the
        // while-in-use location permission (Android 14 refuses a location
        // foreground service without it; the native side then honestly
        // reports "not running"). Asked here, from the open app, once.
        try {
          await Permission.locationWhenInUse.request();
        } catch (e) {
          // best-effort: a refused/absent permission is reported honestly by
          // the native side ("not running") on this same screen.
          reportNonFatal('antitheft.location_permission', e);
        }
        // Start the native foreground service (Android only; never throws).
        await AntiTheftService.start(
          engineToken: token,
          apiBase: AppConfig.apiBase + AppConfig.apiPrefix,
          config: (resp['config'] as Map?)?.cast<String, dynamic>() ?? const {},
          notif: {'title': tr.atNotifTitle, 'body': tr.atNotifBody,
              'off': tr.atNotifOff},
          // at-falsealarm: switched ON now -> today's SIM(s) are the owner's.
          rebaseline: true,
        );
        await AntiTheftService.flushNow();
      }
      _snack(tr.atEnabledSnack);
      await _load();
    } catch (_) {
      _snack(tr.securityActionError);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disable() async {
    final tr = AppLocalizations.of(context);
    // Confirm, then the Section-8 PIN gate (via SecurityGuard so biometric +
    // OTP are applied consistently with every other sensitive action).
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.atDisableTitle),
        content: Text(tr.atDisableConfirm),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: Text(tr.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr.atTurnOff)),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    final pin = await const SecurityGuard().askPin(context, tr);
    if (pin == null || pin.isEmpty || !mounted) return;
    setState(() => _busy = true);
    try {
      final resp = await _api.engineDisable(pin: pin);
      final st = resp['_status'] as int?;
      if (st == 423 || resp['state'] == 'blocked') {
        _snack(tr.securityBlockedFrozen);
        return;
      }
      if (resp['ok'] != true) {
        _snack(resp['locked'] == true ? tr.securityLockedOut : tr.securityBadPin);
        return;
      }
      await AntiTheftService.stop();
      _snack(tr.atDisabledSnack);
      await _load();
    } catch (_) {
      _snack(tr.securityActionError);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveSettings({
    bool? snatchLock,
    bool? intruderPhoto,
    List<int>? alertIds,
  }) async {
    final tr = AppLocalizations.of(context);
    final pin = await const SecurityGuard().askPin(context, tr);
    if (pin == null || pin.isEmpty || !mounted) return;
    setState(() => _busy = true);
    try {
      final resp = await _api.engineSettings(
        pin: pin,
        snatchLock: snatchLock,
        intruderPhoto: intruderPhoto,
        alertMemberIds: alertIds,
      );
      if (resp['ok'] == true) {
        // Hand the running engine its new settings (adds/removes the camera
        // foreground type for the intruder photo). Best-effort, never throws.
        final cfg = resp['config'];
        if (cfg is Map) {
          await AntiTheftService.configure(cfg.cast<String, dynamic>());
        }
        await _load();
      } else {
        _snack(tr.securityBadPin);
      }
    } catch (_) {
      _snack(tr.securityActionError);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Intruder photo is OPT-IN: turning it on shows a plain disclosure, asks
  /// for the camera permission and needs Assisto as device admin (the OS only
  /// tells a device admin about wrong unlock attempts). Then the Security PIN
  /// saves it and the engine re-declares its camera foreground type.
  Future<void> _toggleIntruder(bool on) async {
    if (!on) return _saveSettings(intruderPhoto: false);
    final tr = AppLocalizations.of(context);
    final agree = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.atIntruderDiscTitle),
        content: SingleChildScrollView(child: Text(tr.atIntruderDiscBody)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: Text(tr.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr.atIntruderDiscAgree)),
        ],
      ),
    );
    if (agree != true || !mounted) return;
    var camOk = false;
    try {
      camOk = (await Permission.camera.request()).isGranted;
    } catch (_) {
      camOk = false;
    }
    if (!mounted) return;
    if (!camOk) {
      _snack(tr.atIntruderNeedCamera);
      return;
    }
    const admin = MethodChannel('com.assisto/device_admin');
    var adminOk = false;
    try {
      adminOk = await admin.invokeMethod<bool>('isAdminActive') ?? false;
    } catch (_) {
      adminOk = false;
    }
    if (!mounted) return;
    if (!adminOk) {
      try {
        await admin.invokeMethod<bool>(
            'requestAdmin', {'explanation': tr.atIntruderAdminExplain});
      } catch (e) {
        // best-effort: the snack below tells the owner what to do next.
        reportNonFatal('antitheft.request_admin', e);
      }
      _snack(tr.atIntruderNeedAdmin);
      return;
    }
    await _saveSettings(intruderPhoto: true);
  }

  // ---- build -------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    if (Platform.isIOS) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.atTitle)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Text(tr.atAndroidOnly, textAlign: TextAlign.center),
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(tr.atTitle)),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _failed
                ? _errorState(tr)
                : _content(tr),
      ),
    );
  }

  Widget _errorState(AppLocalizations tr) => ListView(
        padding: const EdgeInsets.all(Gap.lg),
        children: [
          const SizedBox(height: Gap.xxl),
          const Icon(Icons.cloud_off_outlined, size: 48),
          const SizedBox(height: Gap.md),
          Text(honestFailText(tr, _failCause, otherwise: tr.mlpLoadFailed),
              textAlign: TextAlign.center),
          const SizedBox(height: Gap.md),
          Center(child: FilledButton(onPressed: _load, child: Text(tr.retry))),
        ],
      );

  Widget _content(AppLocalizations tr) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(Gap.md),
      children: [
        _statusCard(tr, scheme),
        const SizedBox(height: Gap.md),
        if (FalseAlarmButton.shouldShow(_state)) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: FalseAlarmButton(onCleared: _load),
            ),
          ),
          const SizedBox(height: Gap.md),
        ],
        _intro(tr),
        const SizedBox(height: Gap.md),
        if (_enabled) ...[
          _optionsCard(tr),
          const SizedBox(height: Gap.md),
          _alertMembersCard(tr),
          const SizedBox(height: Gap.md),
          _timelineLink(tr),
          const SizedBox(height: Gap.md),
        ],
        _limitsCard(tr, scheme),
        const SizedBox(height: Gap.md),
        _brandLockCard(tr, scheme),
        const SizedBox(height: Gap.xl),
      ],
    );
  }

  Widget _statusCard(AppLocalizations tr, ColorScheme scheme) {
    final on = _enabled;
    // When the server says ON but the native service is NOT running, say so
    // honestly (battery optimisation can kill it — guidance below).
    final degraded = on && !_running;
    final bg = !on
        ? Brand.warning.withValues(alpha: 0.14)
        : (degraded
            ? Brand.warning.withValues(alpha: 0.14)
            : Brand.success.withValues(alpha: 0.12));
    final fg = !on
        ? Brand.warnInk(context)
        : (degraded
            ? Brand.warnInk(context)
            : (Theme.of(context).brightness == Brightness.dark
                ? Brand.success
                : const Color(0xFF1E7E4E)));
    final title = !on
        ? tr.atStateOff
        : (degraded ? tr.atStateDegraded : tr.atStateOn);
    final body = !on
        ? tr.atStateOffBody
        : (degraded ? tr.atStateDegradedBody : tr.atStateOnBody);
    return Card(
      color: bg,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                    !on
                        ? Icons.gpp_maybe
                        : (degraded ? Icons.warning_amber : Icons.verified_user),
                    color: fg,
                    size: 32),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(color: fg, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(body,
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: Gap.sm),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: _busy
                  ? const Padding(
                      padding: EdgeInsets.all(Gap.sm),
                      child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  : (!on
                      ? FilledButton.icon(
                          onPressed: _enable,
                          icon: const Icon(Icons.shield_outlined),
                          label: Text(tr.atTurnOn))
                      : OutlinedButton.icon(
                          onPressed: _disable,
                          icon: const Icon(Icons.lock_open_outlined),
                          label: Text(tr.atTurnOff))),
            ),
          ],
        ),
      ),
    );
  }

  Widget _intro(AppLocalizations tr) => Card(
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr.atIntroTitle,
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: Gap.xs),
              Text(tr.atIntroBody,
                  style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: Gap.sm),
              _bullet(tr.atFeatHeartbeat),
              _bullet(tr.atFeatSnatch),
              _bullet(tr.atFeatSim),
              _bullet(tr.atFeatOffline),
              _bullet(tr.atFeatIntruder),
            ],
          ),
        ),
      );

  Widget _bullet(String t) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('•  '),
          Expanded(child: Text(t)),
        ]),
      );

  Widget _optionsCard(AppLocalizations tr) {
    final canCamera = _caps['canCamera'] != false; // null/true → allow attempt
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(Gap.sm),
              child: Text(tr.atOptionsTitle,
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            SwitchListTile(
              value: _state['snatch_lock'] == true,
              title: Text(tr.atOptSnatchLock),
              subtitle: Text(tr.atOptSnatchLockBody),
              onChanged: _busy
                  ? null
                  : (v) => _saveSettings(snatchLock: v),
            ),
            SwitchListTile(
              value: _state['intruder_photo'] == true && canCamera,
              title: Text(tr.atOptIntruder),
              subtitle: Text(canCamera
                  ? tr.atOptIntruderBody
                  : tr.atOptIntruderBlocked),
              onChanged: (_busy || !canCamera)
                  ? null
                  : (v) => _toggleIntruder(v),
            ),
          ],
        ),
      ),
    );
  }

  Widget _alertMembersCard(AppLocalizations tr) {
    final candidates = (_state['candidates'] as List?) ?? const [];
    final selected = ((_state['alert_member_ids'] as List?) ?? const [])
        .map((e) => int.tryParse('$e') ?? -1)
        .toSet();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr.atWhoAlertsTitle,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 2),
            Text(tr.atWhoAlertsBody,
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: Gap.sm),
            if (candidates.isEmpty)
              Text(tr.atNoCircle,
                  style: Theme.of(context).textTheme.bodyMedium)
            else
              ...candidates.whereType<Map>().map((m) {
                final id = int.tryParse('${m['id']}') ?? -1;
                return CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: selected.contains(id),
                  title: Text('${m['name'] ?? ''}'),
                  onChanged: _busy
                      ? null
                      : (v) {
                          final next = {...selected};
                          if (v == true) {
                            next.add(id);
                          } else {
                            next.remove(id);
                          }
                          _saveSettings(alertIds: next.toList());
                        },
                );
              }),
          ],
        ),
      ),
    );
  }

  Widget _timelineLink(AppLocalizations tr) => Card(
        child: ListTile(
          leading: const Icon(Icons.timeline_outlined),
          title: Text(tr.atTimelineTitle),
          subtitle: Text(tr.atTimelineBody),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => const AntiTheftTimelineScreen()),
          ),
        ),
      );

  Widget _limitsCard(AppLocalizations tr, ColorScheme scheme) {
    final sdk = int.tryParse('${_caps['sdk'] ?? ''}');
    final canReadSimNumber = _caps['canReadSimNumber'] == true;
    return Card(
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.info_outline, size: 18),
              const SizedBox(width: Gap.xs),
              Expanded(
                child: Text(tr.atLimitsTitle,
                    style: Theme.of(context).textTheme.titleSmall),
              ),
            ]),
            const SizedBox(height: Gap.xs),
            _bullet(tr.atLimitOffline),
            _bullet(canReadSimNumber ? tr.atLimitSimReadable : tr.atLimitSim),
            _bullet(tr.atLimitCamera),
            _bullet(tr.atLimitBattery),
            if (sdk != null)
              Padding(
                padding: const EdgeInsets.only(top: Gap.xs),
                child: Text(tr.atAndroidVersion('$sdk'),
                    style: Theme.of(context).textTheme.bodySmall),
              ),
          ],
        ),
      ),
    );
  }

  Widget _brandLockCard(AppLocalizations tr, ColorScheme scheme) => Card(
        child: ListTile(
          leading: const Icon(Icons.verified_user_outlined),
          title: Text(tr.atBrandLockTitle),
          subtitle: Text(tr.atBrandLockBody),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const PhoneSafetyScreen()),
          ),
        ),
      );
}

/// The engine event timeline (owner or approved family). Honest empty/late
/// states; intruder photos streamed through a short-lived scoped link.
class AntiTheftTimelineScreen extends StatefulWidget {
  final int? phoneId;
  const AntiTheftTimelineScreen({super.key, this.phoneId});

  @override
  State<AntiTheftTimelineScreen> createState() =>
      _AntiTheftTimelineScreenState();
}

class _AntiTheftTimelineScreenState extends State<AntiTheftTimelineScreen> {
  bool _loading = true;
  bool _failed = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)
  Map<String, dynamic> _data = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final d = await context
          .read<AppState>()
          .api
          .engineTimeline(phoneId: widget.phoneId);
      if (!mounted) return;
      setState(() {
        _data = d;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _failCause = e;
        _loading = false;
      });
    }
  }

  String _fmt(dynamic iso) {
    final dt = DateTime.tryParse('${iso ?? ''}')?.toLocal();
    if (dt == null) return '';
    final locale = Localizations.localeOf(context).languageCode;
    return DateFormat('EEE d MMM, h:mm a', locale).format(dt);
  }

  IconData _icon(String kind) {
    switch (kind) {
      case 'snatch':
        return Icons.pan_tool_outlined;
      case 'sim_change':
        return Icons.sim_card_outlined;
      case 'offline':
        return Icons.signal_wifi_off_outlined;
      case 'online':
        return Icons.wifi;
      case 'low_battery':
        return Icons.battery_alert_outlined;
      case 'shutdown':
        return Icons.power_settings_new;
      case 'boot':
        return Icons.restart_alt;
      case 'failed_unlock':
      case 'intruder_photo':
        return Icons.lock_outline;
      case 'went_dark':
        return Icons.visibility_off_outlined;
      default:
        return Icons.history;
    }
  }

  String _label(AppLocalizations tr, String kind) {
    switch (kind) {
      case 'snatch':
        return tr.atKindSnatch;
      case 'snatch_cleared':
        return tr.atKindSnatchCleared;
      case 'sim_change':
        return tr.atKindSim;
      case 'offline':
        return tr.atKindOffline;
      case 'online':
        return tr.atKindOnline;
      case 'low_battery':
        return tr.atKindLowBattery;
      case 'shutdown':
        return tr.atKindShutdown;
      case 'boot':
        return tr.atKindBoot;
      case 'failed_unlock':
        return tr.atKindFailedUnlock;
      case 'intruder_photo':
        return tr.atKindIntruder;
      case 'went_dark':
        return tr.atKindWentDark;
      default:
        return kind;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr.atTimelineTitle)),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _failed
                ? ListView(padding: const EdgeInsets.all(Gap.lg), children: [
                    const SizedBox(height: Gap.xxl),
                    Text(honestFailText(tr, _failCause, otherwise: tr.mlpLoadFailed), textAlign: TextAlign.center),
                    const SizedBox(height: Gap.md),
                    Center(
                        child: FilledButton(
                            onPressed: _load, child: Text(tr.retry))),
                  ])
                : _content(tr),
      ),
    );
  }

  Widget _content(AppLocalizations tr) {
    final events = (_data['events'] as List?) ?? const [];
    final dark = _data['went_dark_at'];
    return ListView(
      padding: const EdgeInsets.all(Gap.md),
      children: [
        if (dark != null)
          Card(
            color: Brand.warning.withValues(alpha: 0.14),
            child: Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Row(children: [
                Icon(Icons.visibility_off_outlined,
                    color: Brand.warnInk(context)),
                const SizedBox(width: Gap.sm),
                Expanded(child: Text(tr.atWentDarkBanner(_fmt(dark)))),
              ]),
            ),
          ),
        if (dark != null) const SizedBox(height: Gap.md),
        if (events.isEmpty)
          Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Text(tr.atNoEvents, textAlign: TextAlign.center),
          )
        else
          ...events.whereType<Map>().map((e) => _eventTile(tr, e)),
      ],
    );
  }

  Widget _eventTile(AppLocalizations tr, Map e) {
    final kind = '${e['kind'] ?? ''}';
    final when = _fmt(e['at']);
    final late = e['late'] == true;
    final hasPhoto = e['has_photo'] == true;
    final id = int.tryParse('${e['id']}');
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: Icon(_icon(kind)),
            title: Text(_label(tr, kind)),
            subtitle: Text(late ? tr.atLateAt(when) : when),
          ),
          if (hasPhoto && id != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.md),
              child: _IntruderThumb(eventId: id),
            ),
        ],
      ),
    );
  }
}

class _IntruderThumb extends StatefulWidget {
  final int eventId;
  const _IntruderThumb({required this.eventId});

  @override
  State<_IntruderThumb> createState() => _IntruderThumbState();
}

class _IntruderThumbState extends State<_IntruderThumb> {
  Uint8List? _bytes;
  bool _loading = true;
  bool _failed = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    try {
      final api = context.read<AppState>().api;
      final link = await api.enginePhotoLink(widget.eventId);
      final url = '${link['url'] ?? ''}';
      if (url.isEmpty) throw Exception('no url');
      final bytes = await api.getBytes(url);
      if (!mounted) return;
      setState(() {
        _bytes = Uint8List.fromList(bytes);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
        _failCause = e;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    if (_loading) {
      return const SizedBox(
          height: 120,
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
    }
    if (_failed || _bytes == null) {
      return SizedBox(
          height: 120, child: Center(child: Text(honestFailText(tr, _failCause, otherwise: tr.mlpPhotoFailed))));
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(Radii.sm),
      child: Image.memory(_bytes!, fit: BoxFit.cover, height: 180,
          width: double.infinity),
    );
  }
}
