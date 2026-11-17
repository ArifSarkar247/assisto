// cctvact (CCTV GUARD V3 D) — "ACT, NOT ONLY WATCH" rows inside the alert
// actions sheet: Live, siren / the owner's own warning on the Guard Box or
// phone camera, the nearest thana (from real map data; 999 always stays),
// Wrong alert (teaches THIS shop), the lock question (only on the owner's
// Yes) and what the automations already did. Every row is honest: when
// something cannot be done here it says why, never a dead button.
import 'package:flutter/material.dart';
import '../../ds/ds.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode;

import '../../cctvact/cctvact_source.dart';
import '../../cctvguard/vendor_live_screen.dart';
import '../../l10n/app_localizations.dart';
import '../../services/action_feedback.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/permission_reason.dart';
import '../shop_live_screen.dart';
import 'watchman_source.dart';
import '../../cctvx/escalate_source.dart' show EscalateSource; // gap-cctv
import 'cctv_escalate.dart' show WarnClipSheet; // gap-cctv
import 'watchman_widgets.dart';

const kWrongReasons = ['animal', 'shadow', 'staff', 'family', 'vehicle', 'weather', 'other'];

String wrongReasonLabel(AppLocalizations t, String r) => switch (r) {
      'animal' => t.cv3WrongAnimal,
      'shadow' => t.cv3WrongShadow,
      'staff' => t.cv3WrongStaff,
      'family' => t.cv3WrongFamily,
      'vehicle' => t.cv3WrongVehicle,
      'weather' => t.cv3WrongWeather,
      _ => t.cv3WrongOther,
    };

class ActTiles extends StatefulWidget {
  final CctvActSource? source;
  final int eventId;
  final Map<String, dynamic> act;

  /// gap-cctv: opens the own-voice warning recorder when none is saved yet.
  final EscalateSource? escalate;

  /// Tests: the current location instead of the phone's GPS.
  final Future<(double, double)?> Function()? locate;
  const ActTiles(
      {super.key,
      required this.source,
      required this.eventId,
      required this.act,
      this.locate,
      this.escalate});

  @override
  State<ActTiles> createState() => _ActTilesState();
}

class _ActTilesState extends State<ActTiles> {
  late Map<String, dynamic> _act = Map<String, dynamic>.from(widget.act);
  bool _busy = false;
  bool _wrongDone = false;

  int get _siteId => (_act['site_id'] as num?)?.toInt() ?? 0;
  bool get _owner => _act['role'] == 'owner';

  void _snack(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  Future<bool> _confirm(String title, String body, String yes) async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.cxCancel)),
          FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(yes)),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _run(Future<void> Function() f) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await f();
    } catch (e) {
      _snack(wmError(e) ?? AppLocalizations.of(context).wmGenericError);
    }
    if (mounted) setState(() => _busy = false);
  }

  // ------------------------------------------------------------ live
  void _live() {
    final l = wmMap(_act['live']);
    final id = (l['camera_id'] as num?)?.toInt();
    if (id == null) return;
    final name = (l['name'] ?? '').toString();
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => l['path'] == 'vendor'
            ? VendorLiveScreen(cameraId: id, cameraName: name)
            : ShopLiveScreen(cameraId: id, cameraName: name)));
  }

  // ------------------------------------------------------------ box play
  /// gap-cctv: no own-voice warning yet → record it (owner), then the tile
  /// plays it. Older servers send no `has_warn`: treated as recorded.
  bool get _hasWarn => _act['has_warn'] != false;

  Future<void> _recordWarn() async {
    final esc = widget.escalate;
    if (esc == null || _siteId == 0) return;
    final saved = await WarnClipSheet.show(context, esc, _siteId);
    if (saved == true && mounted) setState(() => _act['has_warn'] = true);
  }

  Future<void> _play(String sound) async {
    final t = AppLocalizations.of(context);
    final ok = await _confirm(sound == 'warn' ? t.cv3WarnConfirmTitle : t.cv3SirenConfirmTitle,
        t.cv3PlayConfirmBody, t.cv3PlayYes);
    if (!ok || !mounted) return;
    final lang = wmLang(context);
    await _run(() async {
      final r = await widget.source!.play(widget.eventId, sound);
      _snack(t.cv3PlayQueued(wmDigits(lang, r['queued'] ?? 1)));
    });
  }

  // ------------------------------------------------------------ thana
  Future<(double, double)?> _here() async {
    if (widget.locate != null) return widget.locate!();
    final t = AppLocalizations.of(context);
    if (!await Geolocator.isLocationServiceEnabled()) {
      _snack(t.locationOff);
      return null;
    }
    if (!mounted) return null;
    final perm = await askLocationWithReason(context);
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      _snack(t.locationNeeded);
      return null;
    }
    final p = await Geolocator.getCurrentPosition();
    return (p.latitude, p.longitude);
  }

  Future<void> _setLocation() async {
    final t = AppLocalizations.of(context);
    final ok = await _confirm(t.cv3LocTitle, t.cv3LocBody, t.cv3LocYes);
    if (!ok) return;
    await _run(() async {
      final ll = await _here();
      if (ll == null) return;
      final r = await widget.source!.setLocation(_siteId, ll.$1, ll.$2);
      if (!mounted) return;
      setState(() => _act['thana'] = {
            'has_location': true,
            'stations': r['stations'] ?? const [],
            'state': r['state'],
            'emergency': '999',
          });
      if ((r['stations'] as List?)?.isEmpty ?? true) {
        // gap-cctv: "could not look up" is not "no thana nearby"
        _snack(r['state'] == 'unavailable' ? t.gcvThanaUnavailable : t.cv3ThanaNone);
      }
    });
  }

  Future<void> _callThana(Map<String, dynamic> st) async {
    final t = AppLocalizations.of(context);
    final phone = (st['phone'] ?? '').toString();
    if (phone.isEmpty) {
      await openForUser(context,
          Uri.parse('https://maps.google.com/?daddr=${st['lat']},${st['lng']}'),
          where: 'cctvact.thanaMap', mode: LaunchMode.externalApplication);
      return;
    }
    final ok = await _confirm(t.cv3ThanaCallTitle((st['name'] ?? '').toString()),
        t.cv3ThanaCallBody, t.cx999Call);
    if (!ok || !mounted) return;
    await openForUser(context, Uri(scheme: 'tel', path: phone), where: 'cctvact.thanaCall');
  }

  // ------------------------------------------------------------ wrong
  Future<void> _wrong() async {
    final t = AppLocalizations.of(context);
    final reason = await showAppSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(t.cv3WrongTitle, style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(t.cv3WrongHint, style: Theme.of(ctx).textTheme.bodySmall),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final r in kWrongReasons)
                ActionChip(
                  key: ValueKey('cv3-wrong-$r'),
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                  label: Text(wrongReasonLabel(t, r)),
                  onPressed: () => Navigator.pop(ctx, r),
                ),
            ]),
          ]),
        ),
      ),
    );
    if (reason == null) return;
    await _run(() async {
      await widget.source!.markWrong(widget.eventId, reason);
      if (!mounted) return;
      setState(() => _wrongDone = true);
      _snack(t.cv3WrongThanks);
    });
  }

  // ------------------------------------------------------------ lock
  Future<void> _lock(Map<String, dynamic> p) async {
    final t = AppLocalizations.of(context);
    final ok = await _confirm(t.cv3LockTitle, t.cv3LockBody((p['name'] ?? '').toString()),
        t.cv3LockYes);
    if (!ok) return;
    await _run(() async {
      await widget.source!.lock(_siteId, (p['id'] ?? '').toString());
      if (!mounted) return;
      setState(() => _act['lock_pending'] =
          wmList(_act['lock_pending']).where((x) => x['id'] != p['id']).toList());
      _snack(t.cv3LockDone);
    });
  }

  Widget _tile(
      {required Key key,
      required IconData icon,
      required String label,
      required String sub,
      VoidCallback? onTap,
      bool danger = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(key: key, padding: const EdgeInsets.only(bottom: 8), child: DsCard(
        padding: EdgeInsets.zero,
        child: ListTile(
        minTileHeight: 56,
        enabled: onTap != null,
        leading: Icon(icon, color: danger ? scheme.error : null),
        title: Text(label),
        subtitle: Text(sub),
        onTap: onTap,
      ),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    final src = widget.source;
    final live = wmMap(_act['live']);
    final play = wmList(_act['play']);
    final thana = wmMap(_act['thana']);
    final stations = wmList(thana['stations']);
    final wrong = wmMap(_act['wrong']);
    final locks = wmList(_act['lock_pending']);
    final auto = wmList(_act['auto']);
    final canAct = _owner || _act['role'] == 'escalated';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (live['path'] != null)
        _tile(
            key: const ValueKey('cv3-live'),
            icon: Icons.live_tv_rounded,
            label: t.cv3Live,
            sub: (live['name'] ?? '').toString().isEmpty ? t.cv3LiveSub : live['name'].toString(),
            onTap: _live),
      for (final p in locks)
        _tile(
            key: ValueKey('cv3-lock-${p['id']}'),
            icon: Icons.lock_rounded,
            label: t.cv3LockTitle,
            sub: t.cv3LockSub((p['name'] ?? '').toString()),
            danger: true,
            onTap: (src == null || _busy) ? null : () => _lock(p)),
      if (canAct && play.isNotEmpty && src != null) ...[
        _tile(
            key: const ValueKey('cv3-box-siren'),
            icon: Icons.notifications_active_rounded,
            label: t.cv3BoxSiren,
            sub: t.cv3BoxSirenSub,
            onTap: _busy ? null : () => _play('siren')),
        _tile(
            key: const ValueKey('cv3-box-warn'),
            icon: Icons.record_voice_over_rounded,
            label: t.cv3BoxWarn,
            sub: _hasWarn ? t.cv3BoxWarnSub : t.gcvWarnRecordFirst,
            onTap: _busy
                ? null
                : _hasWarn
                    ? () => _play('warn')
                    : (_owner && widget.escalate != null ? _recordWarn : null)),
      ],
      if (_owner && src != null) ...[
        if (stations.isNotEmpty) ...[
          for (final st in stations.take(2))
            _tile(
                key: ValueKey('cv3-thana-${st['name']}'),
                icon: Icons.local_police_outlined,
                label: (st['name'] ?? '').toString(),
                sub: (st['phone'] ?? '').toString().isEmpty
                    ? t.cv3ThanaNoPhone(wmDigits(lang, st['distance_km'] ?? ''))
                    : t.cv3ThanaSub(wmDigits(lang, st['phone']),
                        wmDigits(lang, st['distance_km'] ?? '')),
                onTap: () => _callThana(st)),
        ] else
          _tile(
              key: const ValueKey('cv3-thana-set'),
              icon: Icons.add_location_alt_outlined,
              label: t.cv3ThanaFind,
              sub: thana['has_location'] != true
                  ? t.cv3ThanaFindSub
                  : thana['state'] == 'unavailable'
                      ? t.gcvThanaUnavailable
                      : t.cv3ThanaNone,
              onTap: _busy ? null : _setLocation),
        _tile(
            key: const ValueKey('cv3-wrong'),
            icon: Icons.thumb_down_alt_outlined,
            label: t.cv3Wrong,
            sub: _wrongDone
                ? t.cv3WrongThanks
                : ((lang == 'en' ? wrong['note_en'] : wrong['note_bn']) ?? t.cv3WrongSub).toString(),
            onTap: (_busy || _wrongDone) ? null : _wrong),
      ],
      if (auto.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            t.cv3AutoRan(auto
                .map((a) => '${a['device'] ?? ''}: ${_autoState(t, (a['state'] ?? '').toString())}')
                .join(' · ')),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
    ]);
  }
}

/// gap-cctv: the same plain words on the automations screen's log.
String cv3AutoStateLabel(AppLocalizations t, String s) => _autoState(t, s);

String _autoState(AppLocalizations t, String s) => switch (s) {
      'on' => t.cv3AutoOn,
      'asked' => t.cv3AutoAsked,
      'queued' => t.cv3AutoQueued,
      'locked' => t.cv3AutoLocked,
      'not_linked' => t.cv3AutoNotLinked,
      _ => t.cv3AutoError,
    };
