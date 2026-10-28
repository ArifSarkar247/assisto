import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../api.dart';
import '../config.dart';
import '../l10n/app_localizations.dart';
import '../services/action_feedback.dart'; // db1
import '../services/journey_tracker.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/adaptive_button_pair.dart';
import '../widgets/journey_api.dart';
import '../widgets/journey_dest_sheets.dart';
import '../widgets/journey_ride.dart';
import '../services/oem_guide.dart';
import 'battery_guidance_screen.dart';
import '../widgets/password_field.dart';
import '../widgets/sos_button.dart';
import 'journey_fake_call_screen.dart';
import 'journey_sos_screen.dart';
import 'package:assisto/widgets/app_sheet.dart';

/// journey100 — the LIVE journey screen.
///
/// Location is sent by [JourneyTracker] (a location-type foreground service
/// with a visible notification, so it keeps going with the screen off; it
/// starts here and stops on arrival / stop). Everything that must happen
/// without this phone — "Are you OK?" when late, alerting watchers, stop /
/// off-route / signal-lost checks — runs on the server every minute
/// (backend `journey_sweep`). This screen only shows honest state:
/// sharing / offline with N fixes saved / location off, plus the actions:
/// SOS, I've arrived, more time, fake call, ride photo, stop (safety PIN).
class JourneyLiveScreen extends StatefulWidget {
  final int journeyId;

  /// Tests inject a tracker without the foreground service.
  final JourneyTracker? tracker;

  /// Tests / gallery inject the OEM probe (battery optimisation etc.).
  final OemGuideNative? oem;
  const JourneyLiveScreen({super.key, required this.journeyId, this.tracker, this.oem});
  @override
  State<JourneyLiveScreen> createState() => _JourneyLiveScreenState();
}

class _JourneyLiveScreenState extends State<JourneyLiveScreen>
    with WidgetsBindingObserver {
  late final JourneyTracker _tr = widget.tracker ?? JourneyTracker.I;
  Map<String, dynamic> _journey = {};
  bool _asked = false; // "Are you OK?" showing
  bool _closing = false;
  bool _photoAdded = false;
  bool _pinRequired = false;
  // journey2: this phone's background rules may stop sharing with the
  // screen off (Realme/Xiaomi/Oppo/Vivo/Samsung battery savers). Shown
  // honestly with the 2-step fix; never claimed fixed unless Android says so.
  OemInfo? _oemInfo;

  ApiClient get _api => context.read<AppState>().api;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tr.addListener(_onTrack);
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  @override
  void dispose() {
    _tr.removeListener(_onTrack);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_tr.tick());
  }

  Future<void> _boot() async {
    if (!mounted) return;
    final t = AppLocalizations.of(context);
    final api = _api;
    try {
      final j = await api.journeyActive();
      if (!mounted) return;
      if ((j['id'] as num?)?.toInt() == widget.journeyId) {
        setState(() {
          _journey = j;
          _pinRequired = j['pin_required'] == true;
          _photoAdded = ((j['vehicle'] as Map?)?['photo_url'] ?? '') != '';
        });
      }
    } catch (_) {
      // best-effort: offline — the tracker's own state + queue still work
    }
    if (!mounted) return;
    unawaited(_probeBackground());
    await _tr.start(
      widget.journeyId,
      (id, points) => api.journeyLocationBatch(id, points),
      notifTitle: t.j100NotifTitle,
      notifText: t.j100NotifText,
      serviceSession: api.token == null
          ? null
          : {
              'url': AppConfig.api('/journey/${widget.journeyId}/location')
                  .toString(),
              'auth': 'Token ${api.token}',
              'lang': api.lang ?? 'bn',
            },
    );
  }

  Future<void> _probeBackground() async {
    try {
      final info = await (widget.oem ?? const ChannelOemGuideNative()).info();
      if (mounted) setState(() => _oemInfo = info);
    } catch (_) {
      // best-effort: unknown phone rules -> no card (the service line stays)
    }
  }

  /// True when Android reports a rule that can stop the trip's sharing with
  /// the screen off, or the phone family is known to need manual steps that
  /// Android cannot confirm (autostart / OEM battery saver).
  bool get _bgRisk {
    final i = _oemInfo;
    if (i == null) return false;
    if (i.bgRestricted == true) return true;
    if (i.family == OemFamily.nearStock) return false;
    return i.batteryOptIgnored != true;
  }

  Widget _bgCard(AppLocalizations t) {
    final warn = Brand.warnInk(context);
    return Container(
      key: const ValueKey('j2_bg_risk'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: warn.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(Radii.md)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.battery_alert_rounded, color: warn),
          const SizedBox(width: 10),
          Expanded(
              child: Text(t.j2BgRiskTitle,
                  style: AType.bodyLarge.copyWith(fontWeight: FontWeight.w700))),
        ]),
        const SizedBox(height: Gap.xs),
        Text(t.j2BgRiskBody, style: AType.bodyMedium),
        const SizedBox(height: Gap.sm),
        OutlinedButton.icon(
          key: const ValueKey('j2_bg_fix'),
          icon: const Icon(Icons.build_circle_rounded),
          label: Text(t.j2BgRiskFix),
          onPressed: () async {
            await Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => BatteryGuidanceScreen(native: widget.oem)));
            if (mounted) unawaited(_probeBackground());
          },
        ),
      ]),
    );
  }

  Map<String, dynamic> get _ride =>
      ((_journey['vehicle'] as Map?) ?? const {}).cast<String, dynamic>();

  Widget _rideCard(AppLocalizations t) {
    final cs = Theme.of(context).colorScheme;
    final v = _ride;
    final line = jRideLine(t, v);
    final driver = '${v['driver_name'] ?? ''}';
    final empty = line.isEmpty && driver.isEmpty;
    return Card(
      key: const ValueKey('j2_ride_card'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.local_taxi_rounded, color: cs.primary),
            const SizedBox(width: Gap.sm),
            Expanded(
                child: Text(t.j2RideCardTitle,
                    style: AType.bodyLarge.copyWith(fontWeight: FontWeight.w700))),
          ]),
          const SizedBox(height: Gap.xs),
          if (empty)
            Text(t.j2RideEmpty, style: AType.bodyMedium.copyWith(color: cs.onSurfaceVariant))
          else ...[
            if (line.isNotEmpty) Text(line, style: AType.bodyMedium),
            if (driver.isNotEmpty) Text(t.j2Driver(driver), style: AType.bodyMedium),
          ],
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            OutlinedButton.icon(
                key: const ValueKey('j2_ride_edit'),
                icon: Icon(empty ? Icons.add_rounded : Icons.edit_rounded),
                label: Text(empty ? t.j2RideAdd : t.j2RideChange),
                onPressed: _editRide),
            OutlinedButton.icon(
                key: const ValueKey('j100_photo'),
                icon: Icon(_photoAdded
                    ? Icons.check_circle_outline_rounded
                    : Icons.add_a_photo_rounded),
                label: Text(_photoAdded ? t.j100VehiclePhotoAdded : t.j100VehiclePhoto),
                onPressed: _vehiclePhoto),
          ]),
        ]),
      ),
    );
  }

  Future<void> _editRide() async {
    final t = AppLocalizations.of(context);
    final got = await showJourneyRideSheet(context, _ride);
    if (got == null || !mounted) return;
    try {
      final r = await _api.journeyRide(widget.journeyId, got);
      if (!mounted) return;
      final v = (r['vehicle'] as Map?)?.cast<String, dynamic>();
      setState(() => _journey = {
            ..._journey,
            'vehicle': {...?v, if (_ride['photo_url'] != null) 'photo_url': _ride['photo_url']},
          });
      _snack(t.j2RideSaved);
    } catch (e) {
      if (mounted) showActionFailed(context, 'journey.ride', e);
    }
  }

  /// Straight-line distance left to a pinned destination, from this phone's
  /// latest fix (null when either is unknown — nothing is guessed).
  double? _toGo(JourneyTrackState s) {
    final d = (_journey['destination'] as Map?) ?? const {};
    final lat = (d['lat'] as num?)?.toDouble(), lng = (d['lng'] as num?)?.toDouble();
    final f = s.lastFix;
    if (lat == null || lng == null || f == null) return null;
    return jDistanceM(f.lat, f.lng, lat, lng);
  }

  void _onTrack() {
    if (!mounted || _closing) return;
    final s = _tr.value;
    setState(() {});
    if (s.journeyId != widget.journeyId) return;
    if (s.status == 'arrived') {
      _closeWith(AppLocalizations.of(context).journeyArrivedSafely);
    } else if (s.status != 'active') {
      _closeWith(null);
    } else if ((s.overdue == 'ask' || s.overdue == 'alert') && !_asked) {
      _promptOk();
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _closeWith(String? msg) {
    if (_closing) return;
    _closing = true;
    if (msg != null) _snack(msg);
    if (Navigator.canPop(context)) Navigator.pop(context);
  }

  Future<void> _promptOk() async {
    setState(() => _asked = true);
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        title: Text(t.journeyAreYouOkTitle),
        content: Text(t.journeyAreYouOkBody),
        actions: [
          TextButton(
              key: const ValueKey('j100_need_help'),
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.journeyNeedHelp)),
          FilledButton(
              key: const ValueKey('j100_im_ok'),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.journeyImOk)),
        ],
      ),
    );
    if (!mounted) return;
    if (ok == true) {
      // q1-seams: a failed "I'm OK" must never look handled.
      try {
        await _api.journeyRespondOk(widget.journeyId);
      } catch (_) {
        _snack(AppLocalizations.of(context).grpActionFailed);
        if (mounted) setState(() => _asked = false);
        return;
      }
      if (mounted) setState(() => _asked = false);
      unawaited(_tr.tick());
    } else {
      _openSos();
    }
  }

  Future<void> _markArrived() async {
    try {
      await _api.journeyArrived(widget.journeyId);
    } catch (_) {
      // q1-seams: never a false "arrived safely" — the server did not hear it.
      if (mounted) _snack(AppLocalizations.of(context).realityArrivedNotSent);
      return;
    }
    await _tr.finished('arrived');
    if (mounted) _closeWith(AppLocalizations.of(context).journeyArrivedSafely);
  }

  Future<String?> _askPin(AppLocalizations t) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        title: Text(t.sosPinTitle),
        content: ObscureTextField(
          key: const ValueKey('j100_pin_field'),
          controller: ctrl,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(labelText: t.sosPinLabel),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, null), child: Text(t.cancel)),
          FilledButton(
              key: const ValueKey('j100_pin_ok'),
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: Text(t.ok)),
        ],
      ),
    );
  }

  Future<void> _stop() async {
    final t = AppLocalizations.of(context);
    String? pin;
    if (_pinRequired) {
      // safety PIN: the normal PIN stops; the duress PIN LOOKS the same while
      // the server silently alerts (the answer is identical).
      pin = await _askPin(t);
      if (pin == null || pin.isEmpty) return;
    } else {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          scrollable: true, // insets: 200% text / keyboard
          title: Text(t.journeyStopTitle),
          content: Text(t.journeyStopBody),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(t.cancel)),
            FilledButton(
                key: const ValueKey('j100_stop_confirm'),
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(t.journeyStopConfirm)),
          ],
        ),
      );
      if (confirm != true) return;
    }
    if (!mounted) return;
    try {
      await _api.journeyStop(widget.journeyId, pin: pin);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.status == 429) {
        _snack(t.j100PinLocked);
      } else if (e.status == 400) {
        // wrong / missing PIN: the journey keeps running
        _snack(t.sosPinWrong);
        if (!_pinRequired) setState(() => _pinRequired = true);
      } else {
        _snack(t.grpActionFailed);
      }
      return;
    } catch (_) {
      // q1-seams: still live on the server — say so, keep the screen.
      if (mounted) _snack(t.grpActionFailed);
      return;
    }
    await _tr.finished('stopped');
    if (mounted) _closeWith(null);
  }

  Future<void> _linkSheet() async {
    final t = AppLocalizations.of(context);
    final pick = await showAppSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
              title: Text(t.j2LinkSheetTitle,
                  style: AType.titleMedium.copyWith(fontWeight: FontWeight.bold)),
              subtitle: Text(t.j2LinkNote)),
          ListTile(
              key: const ValueKey('j2_link_share'),
              leading: const Icon(Icons.share_rounded),
              title: Text(t.j2LinkShare),
              onTap: () => Navigator.pop(ctx, 'share')),
          ListTile(
              key: const ValueKey('j2_link_off'),
              leading: const Icon(Icons.link_off_rounded),
              title: Text(t.j2LinkOff),
              onTap: () => Navigator.pop(ctx, 'off')),
        ]),
      ),
    );
    if (!mounted) return;
    if (pick == 'share') await _shareWebLink();
    if (pick == 'off') await _revokeLink();
  }

  Future<void> _revokeLink() async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(t.j2LinkOffTitle),
        content: Text(t.j2LinkOffBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(
              key: const ValueKey('j2_link_off_ok'),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.j2LinkOffConfirm)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _api.journeyRevokeLink(widget.journeyId);
      if (mounted) _snack(t.j2LinkOffDone);
    } catch (e) {
      // q1-seams: never say "turned off" when the server did not hear it
      if (mounted) showActionFailed(context, 'journey.revokeLink', e);
    }
  }

  Future<void> _shareWebLink() async {
    final t = AppLocalizations.of(context);
    try {
      final r = await _api.journeyWebLink(widget.journeyId);
      final url = (r['url'] ?? '').toString();
      if (url.isEmpty) throw StateError('no link');
      await Share.share(t.journeyShareLinkText(url));
    } catch (e) {
      if (mounted) showActionFailed(context, 'journey.shareLink', e, open: true);
    }
  }

  Future<void> _extend() async {
    final t = AppLocalizations.of(context);
    final mins = await showAppSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
              title: Text(t.j100ExtendTitle,
                  style: AType.titleMedium.copyWith(fontWeight: FontWeight.bold))),
          for (final m in const [10, 15, 30, 60])
            ListTile(
              key: ValueKey('j100_extend_$m'),
              leading: const Icon(Icons.more_time_rounded),
              title: Text(t.j100ExtendMin(m)),
              onTap: () => Navigator.pop(ctx, m),
            ),
        ]),
      ),
    );
    if (mins == null || !mounted) return;
    try {
      final r = await _api.journeyExtend(widget.journeyId, mins);
      if (!mounted) return;
      setState(() => _journey = {..._journey, ...r});
      _snack(t.j100Extended);
    } on ApiException catch (e) {
      if (mounted) _snack(e.status == 400 ? t.j100ExtendLimit : t.grpActionFailed);
    } catch (_) {
      if (mounted) _snack(t.grpActionFailed);
    }
  }

  Future<void> _vehiclePhoto() async {
    final t = AppLocalizations.of(context);
    final src = await showAppSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
              leading: const Icon(Icons.photo_camera_rounded),
              title: Text(t.j100VehiclePhotoCamera),
              onTap: () => Navigator.pop(ctx, ImageSource.camera)),
          ListTile(
              leading: const Icon(Icons.photo_library_rounded),
              title: Text(t.j100VehiclePhotoPick),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery)),
        ]),
      ),
    );
    if (src == null || !mounted) return;
    try {
      // camera intent / system photo picker: no storage permission
      final x = await ImagePicker()
          .pickImage(source: src, maxWidth: 1280, maxHeight: 1280, imageQuality: 70);
      if (x == null) return;
      final bytes = await x.readAsBytes();
      final plate = ((_journey['vehicle'] as Map?)?['plate'] ?? '').toString();
      await _api.journeyVehiclePhoto(widget.journeyId, base64Encode(bytes),
          plate: plate.isEmpty ? null : plate);
      if (!mounted) return;
      setState(() => _photoAdded = true);
      _snack(t.j100VehiclePhotoSent);
    } catch (e) {
      if (mounted) showActionFailed(context, 'journey.vehiclePhoto', e);
    }
  }

  Future<void> _sms() async {
    final t = AppLocalizations.of(context);
    final phones = (await Settings.getString(kPhonesKey) ?? '')
        .split(',')
        .where((p) => p.trim().isNotEmpty)
        .toList();
    if (!mounted) return;
    final f = _tr.value.lastFix;
    final dest = (_journey['destination'] as Map?)?['name']?.toString() ?? '';
    final body = f == null
        ? t.j100SmsBodyNoLoc
        : t.j100SmsBody(dest.isEmpty ? '-' : dest, journeyMapsLink(f.lat, f.lng),
            TimeOfDay.fromDateTime(f.at).format(context));
    await openForUser(context, journeySmsUri(phones, body), where: 'journey.sms');
  }

  void _openSos() {
    final f = _tr.value.lastFix;
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => JourneySosScreen(
            journeyId: widget.journeyId,
            countdownSeconds: 5,
            pinRequired: _pinRequired,
            lastLat: f?.lat,
            lastLng: f?.lng)));
  }

  Future<void> _fakeCall() async {
    final t = AppLocalizations.of(context);
    final ctrl = TextEditingController(text: t.fakeCallDefaultName);
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        title: Text(t.fakeCallSetup),
        content: TextField(
            controller: ctrl,
            decoration: InputDecoration(labelText: t.fakeCallCaller)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(
              key: const ValueKey('j100_fake_go'),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.fakeCallStart)),
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

  Widget _statusCard(AppLocalizations t, JourneyTrackState s) {
    final cs = Theme.of(context).colorScheme;
    late final IconData icon;
    late final Color color;
    late final String title;
    String? body;
    Widget? action;
    if (s.locationOff) {
      icon = Icons.location_off_rounded;
      color = Brand.warnInk(context);
      title = t.j100LocOffTitle;
      body = t.j100LocOffBody;
      action = OutlinedButton.icon(
        key: const ValueKey('j100_loc_on'),
        icon: const Icon(Icons.my_location_rounded),
        label: Text(t.j100LocOn),
        onPressed: () async {
          try {
            await Geolocator.openLocationSettings();
          } catch (e) {
            if (mounted) showActionFailed(context, 'journey.locSettings', e, open: true);
          }
        },
      );
    } else if (s.net == JourneyNet.offline) {
      icon = Icons.cloud_off_rounded;
      color = Brand.warnInk(context);
      title = t.j100OfflineTitle;
      body = t.j100OfflineBody(jDigits(context, s.queued));
      action = FilledButton.icon(
        key: const ValueKey('j100_sms'),
        icon: const Icon(Icons.sms_rounded),
        label: Text(t.j100SendSms),
        onPressed: _sms,
      );
    } else if (s.lastSentAt != null) {
      icon = Icons.navigation_rounded;
      color = Brand.successFill;
      title = t.j100Sharing;
      body = t.j100LastSent(TimeOfDay.fromDateTime(s.lastSentAt!).format(context));
    } else {
      icon = Icons.gps_not_fixed_rounded;
      color = cs.onSurfaceVariant;
      title = t.j100Locating;
    }
    final dest = (_journey['destination'] as Map?)?['name']?.toString();
    final eta = DateTime.tryParse('${_journey['eta'] ?? ''}')?.toLocal();
    final late = s.overdue == 'grace' || s.overdue == 'ask' || s.overdue == 'alert';
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        key: const ValueKey('j100_status'),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: color.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(Radii.md)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, color: color),
            const SizedBox(width: 10),
            Expanded(
                child: Text(title,
                    style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700))),
          ]),
          if (body != null) ...[
            const SizedBox(height: Gap.xs),
            Text(body, style: AType.bodyMedium),
          ],
          if (dest != null && dest.isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            Text(t.journeyToward(dest), style: AType.bodyMedium),
          ],
          if (eta != null)
            Text(t.journeyEtaBy(TimeOfDay.fromDateTime(eta).format(context)),
                style: AType.bodyMedium),
          if (_toGo(s) case final m?)
            Text(t.j2ToGo(jKm(context, m)),
                key: const ValueKey('j2_to_go'), style: AType.bodyMedium),
          if (late)
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: Text(t.j100Late,
                  style: AType.bodyMedium.copyWith(
                      color: cs.error, fontWeight: FontWeight.w700)),
            ),
          const SizedBox(height: Gap.xs),
          Text(s.serviceOn ? t.j100BackgroundOn : t.j100KeepOpen,
              style: AType.bodySmall.copyWith(color: cs.onSurfaceVariant)),
          if (action != null) ...[
            const SizedBox(height: Gap.sm),
            action,
          ],
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = _tr.value;
    final extendLeft = (_journey['extend_left'] as num?)?.toInt() ?? 1;
    return Scaffold(
      appBar: AppBar(title: Text(t.journeyLiveTitle), actions: [
        IconButton(
            key: const ValueKey('j100_share'),
            icon: const Icon(Icons.link_rounded),
            tooltip: t.journeyShareLink,
            onPressed: _linkSheet),
      ]),
      body: ListView(padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)), children: [
        _statusCard(t, s),
        if (_bgRisk) ...[
          const SizedBox(height: Gap.md),
          _bgCard(t),
        ],
        const SizedBox(height: Gap.lg),
        SosButton(label: t.emergencySosButton, onPressed: _openSos),
        const SizedBox(height: Gap.lg),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            key: const ValueKey('j100_arrived'),
            style: FilledButton.styleFrom(
                // QA a6: white on Colors.green was 2.8:1 — deeper green 5:1.
                backgroundColor: Brand.successFill,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(52),
                padding: const EdgeInsets.symmetric(vertical: Gap.md)),
            onPressed: _markArrived,
            icon: const Icon(Icons.check_circle_rounded),
            label: Text(t.journeyImSafe, style: AType.bodyLarge),
          ),
        ),
        const SizedBox(height: Gap.md),
        AdaptiveButtonPair(
          first: OutlinedButton.icon(
              key: const ValueKey('j100_extend'),
              icon: const Icon(Icons.more_time_rounded),
              label: Text(t.j100Extend),
              onPressed: extendLeft > 0 ? _extend : null),
          second: OutlinedButton.icon(
              key: const ValueKey('j100_fake_call'),
              icon: const Icon(Icons.phone_callback_rounded),
              label: Text(t.fakeCallTitle),
              onPressed: _fakeCall),
        ),
        const SizedBox(height: Gap.sm),
        AdaptiveButtonPair(
          first: OutlinedButton.icon(
              key: const ValueKey('j100_sms_any'),
              icon: const Icon(Icons.sms_rounded),
              label: Text(t.j100SendSms),
              onPressed: _sms),
          second: OutlinedButton.icon(
              key: const ValueKey('j100_stop'),
              icon: const Icon(Icons.stop_circle_rounded),
              label: Text(t.journeyStop),
              onPressed: _stop),
        ),
        const SizedBox(height: Gap.md),
        _rideCard(t),
        const SizedBox(height: 20),
        Text(t.j100Footer,
            style: AType.bodySmall
                .copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ]),
    );
  }
}
