import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/cv_empty.dart';
import '../shop_live_screen.dart';
import 'cctv_team_source.dart';
import 'cctv_watch_screen.dart';
import 'watchman_source.dart';
import 'watchman_widgets.dart';

/// cctvteam (W11, audit F1) — ALL my places and cameras on one screen: each
/// camera a tile with its newest still photo, a status pill (online /
/// offline / never connected / off), open alerts, and one tap to a bigger
/// photo, a fresh photo from the camera cloud, live view (when allowed) or
/// sharing that one photo with a private neighbourhood group.
///
/// Light on a 2 GB phone: still photos decoded at tile size, refreshed every
/// minute while visible — never several live streams (the server allows at
/// most 2 live views per account anyway). A guard sees only the cameras the
/// owner gave them; the server decides, the screen only shows what came back.
class CctvGridScreen extends StatefulWidget {
  final CctvTeamSource source;

  /// First-run: no place yet → go back to the watchman set-up.
  final VoidCallback? onSetup;
  const CctvGridScreen({super.key, required this.source, this.onSetup});

  @override
  State<CctvGridScreen> createState() => _CctvGridScreenState();
}

class _CctvGridScreenState extends State<CctvGridScreen> {
  bool _loading = true;
  String? _error;
  bool _featureOff = false;
  Map<String, dynamic> _data = const {};
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    if (!quiet) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      _data = await widget.source.grid();
      _featureOff = false;
      _error = null;
    } catch (e) {
      if (wmStatus(e) == 403) {
        _featureOff = true;
      } else if (!quiet) {
        _error = wmError(e) ?? '';
      }
    }
    if (!mounted) return;
    setState(() => _loading = false);
    _timer?.cancel();
    final s = (_data['refresh_s'] as num?)?.toInt() ?? 60;
    _timer = Timer(Duration(seconds: s < 30 ? 30 : s), () {
      if (mounted) _load(quiet: true);
    });
  }

  Future<void> _open(Map<String, dynamic> site, Map<String, dynamic> cam) async {
    await showAppSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => CctvCameraSheet(source: widget.source, site: site, camera: cam),
    );
    if (mounted) _load(quiet: true);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(t.ctmGridTitle),
        actions: [
          IconButton(
            key: const ValueKey('ctm-grid-watch'),
            tooltip: t.ctmWatchTitle,
            icon: const Icon(Icons.diversity_3_rounded),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => CctvWatchScreen(source: widget.source))),
          ),
        ],
      ),
      body: _body(t),
    );
  }

  Widget _body(AppLocalizations t) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_featureOff) {
      return _Msg(icon: Icons.lock_clock_outlined, title: t.wmFeatureOffTitle, body: t.wmFeatureOffBody);
    }
    if (_error != null) {
      return _Msg(
        icon: Icons.cloud_off_rounded,
        title: t.wmLoadErrorTitle,
        body: _error!.isNotEmpty ? _error! : t.wmLoadErrorBody,
        action: FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
            onPressed: _load,
            child: Text(t.wmRetry)),
      );
    }
    final lang = wmLang(context);
    final sites = wmList(_data['sites']);
    final liveMax = (_data['live_max'] as num?)?.toInt() ?? 2;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(12, 8, 12, 32)),
        children: [
          if (sites.isEmpty)
            CvEmptyBlock(
              icon: Icons.grid_view_rounded,
              title: t.ctmGridEmptyTitle,
              benefit: t.ctmGridEmptyBenefit,
              primaryIcon: Icons.add_home_work_outlined,
              primaryLabel: t.wmAddPlace,
              onPrimary: widget.onSetup ?? () => Navigator.of(context).maybePop(),
              steps: [t.ctmGridEmptyStep1, t.ctmGridEmptyStep2, t.ctmGridEmptyStep3],
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
              child: Text(t.ctmGridNote(wmDigits(lang, liveMax)),
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          for (final s in sites) _SiteBlock(site: s, source: widget.source, onOpen: (c) => _open(s, c)),
        ],
      ),
    );
  }
}

class _SiteBlock extends StatelessWidget {
  final Map<String, dynamic> site;
  final CctvTeamSource source;
  final ValueChanged<Map<String, dynamic>> onOpen;
  const _SiteBlock({required this.site, required this.source, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    final cams = wmList(site['cameras']);
    final role = (site['role'] ?? 'owner').toString();
    final open = (site['open_alerts'] as num?)?.toInt() ?? 0;
    final home = site['kind'] == 'home';
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Semantics(
          header: true,
          child: Row(children: [
            Icon(home ? Icons.home_rounded : Icons.storefront_rounded),
            const SizedBox(width: 8),
            Expanded(
              child: Text((site['name'] ?? '').toString(),
                  style: Theme.of(context).textTheme.titleMedium),
            ),
          ]),
        ),
        const SizedBox(height: 4),
        Wrap(spacing: 8, runSpacing: 6, children: [
          WmPill(label: ctmRoleName(t, role), icon: Icons.badge_outlined, color: Theme.of(context).colorScheme.primary),
          if (open > 0)
            WmPill(
                label: t.wmAlertsOpen(wmDigits(lang, open)),
                icon: Icons.notifications_active_rounded,
                color: wmWarn()),
          if (role != 'owner' && (site['owner_name'] ?? '').toString().isNotEmpty)
            WmPill(
                label: t.wmSharedBy((site['owner_name'] ?? '').toString()),
                icon: Icons.person_outline_rounded,
                color: wmOk()),
        ]),
        const SizedBox(height: 8),
        if (cams.isEmpty)
          Text(role == 'owner' ? t.cvvNoCamBenefit : t.cvvNoCamViewer)
        else
          LayoutBuilder(builder: (context, c) {
            // two tiles on a phone, more on a tablet; tall enough for 200 % text
            final cols = (c.maxWidth / 160).floor().clamp(1, 4);
            return GridView.count(
              crossAxisCount: cols,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              childAspectRatio: 0.82 / MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0),
              children: [for (final cam in cams) CctvTile(camera: cam, source: source, onTap: () => onOpen(cam))],
            );
          }),
      ]),
    );
  }
}

String ctmRoleName(AppLocalizations t, String role) => switch (role) {
      'owner' => t.ctmRoleOwner,
      'manager' => t.ctmRoleManager,
      'guard' => t.ctmRoleGuard,
      _ => t.ctmRoleFamily,
    };

/// The status pill text + colour of one camera.
(String, IconData, Color) ctmStatus(AppLocalizations t, String status) => switch (status) {
      'online' => (t.ctmStatusOnline, Icons.check_circle_rounded, wmOk()),
      'off' => (t.ctmStatusOff, Icons.power_settings_new_rounded, wmBad()),
      'never' => (t.ctmStatusNever, Icons.help_outline_rounded, wmWarn()),
      _ => (t.ctmStatusOffline, Icons.portable_wifi_off_rounded, wmWarn()),
    };

/// "photo 5 min ago" / "no photo yet".
String ctmPhotoAge(AppLocalizations t, String lang, String? iso, String? source) {
  if (source == null) return t.ctmNoPhoto;
  final m = ctmAgeMinutes(iso);
  if (m == null) return t.ctmPhotoFromCheck;
  if (m < 1) return t.ctmPhotoJustNow;
  if (m < 120) return t.ctmPhotoMinutes(wmDigits(lang, m));
  return t.ctmPhotoAt(ctmTime(lang, iso));
}

class CctvTile extends StatelessWidget {
  final Map<String, dynamic> camera;
  final CctvTeamSource source;
  final VoidCallback onTap;
  const CctvTile({super.key, required this.camera, required this.source, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    final url = (camera['still_url'] ?? '').toString();
    final (label, icon, color) = ctmStatus(t, (camera['status'] ?? '').toString());
    final open = (camera['open_alerts'] as num?)?.toInt() ?? 0;
    final name = (camera['name'] ?? '').toString();
    final age = ctmPhotoAge(t, lang, camera['still_at']?.toString(), camera['still_source']?.toString());
    return Semantics(
      button: true,
      label: '$name, $label, $age',
      onTap: onTap,
      excludeSemantics: true,
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('ctm-tile-${camera['id']}'),
          onTap: onTap,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(fit: StackFit.expand, children: [
                CctvStill(source: source, url: url),
                if (open > 0)
                  Positioned(
                    right: 6,
                    top: 6,
                    child: CircleAvatar(
                      radius: 13,
                      backgroundColor: wmBad(),
                      child: Text(wmDigits(lang, open),
                          style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
                    ),
                  ),
              ]),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 4),
                  WmPill(label: label, icon: icon, color: color),
                  const SizedBox(height: 2),
                  Flexible(
                    child: Text(age, maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall),
                  ),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// One still: network (decoded small) or a placeholder — never a broken box.
class CctvStill extends StatelessWidget {
  final CctvTeamSource source;
  final String url;
  final String? inlineJpeg;
  final int width;
  const CctvStill({super.key, required this.source, required this.url, this.inlineJpeg, this.width = 360});

  @override
  Widget build(BuildContext context) {
    final ph = ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(child: Icon(Icons.videocam_outlined, size: 36, color: Theme.of(context).colorScheme.onSurfaceVariant)),
    );
    if (inlineJpeg != null && inlineJpeg!.isNotEmpty) {
      try {
        return Image.memory(base64Decode(inlineJpeg!), fit: BoxFit.cover, cacheWidth: width, gaplessPlayback: true);
      } catch (_) {
        return ph;
      }
    }
    if (url.isEmpty) return ph;
    return Image(
      image: source.image(url, width: width),
      fit: BoxFit.cover,
      gaplessPlayback: true,
      // until the photo arrives: the camera placeholder, never an empty box
      frameBuilder: (_, child, frame, sync) => (frame == null && !sync) ? ph : child,
      errorBuilder: (_, __, ___) => ph,
    );
  }
}

/// Tap on a tile: the bigger photo + what can honestly be done from here.
class CctvCameraSheet extends StatefulWidget {
  final CctvTeamSource source;
  final Map<String, dynamic> site;
  final Map<String, dynamic> camera;
  const CctvCameraSheet({super.key, required this.source, required this.site, required this.camera});

  @override
  State<CctvCameraSheet> createState() => _CctvCameraSheetState();
}

class _CctvCameraSheetState extends State<CctvCameraSheet> {
  late Map<String, dynamic> _cam = Map.of(widget.camera);
  String? _inline;
  String? _note;
  bool _busy = false;

  int get _id => (widget.camera['id'] as num).toInt();

  Future<void> _fresh() async {
    final t = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _note = null;
    });
    try {
      final d = await widget.source.still(_id, fresh: true);
      _cam = {
        ..._cam,
        'still_url': d['still_url'] ?? _cam['still_url'],
        'still_at': d['still_at'] ?? _cam['still_at'],
        'still_source': d['source'] ?? _cam['still_source'],
      };
      _inline = d['inline_jpeg']?.toString();
      _note = d['fresh'] == true ? t.ctmFreshDone : (d['detail'] ?? '').toString();
    } catch (e) {
      _note = wmError(e) ?? t.wmGenericError;
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    final (label, icon, color) = ctmStatus(t, (_cam['status'] ?? '').toString());
    final name = (_cam['name'] ?? '').toString();
    final liveOk = _cam['live_ok'] == true;
    final fresh = _cam['fresh_supported'] == true && _cam['status'] != 'off';
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(name, style: Theme.of(context).textTheme.titleLarge),
        Text((widget.site['name'] ?? '').toString(), style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: CctvStill(
                source: widget.source,
                url: (_cam['still_url'] ?? '').toString(),
                inlineJpeg: _inline,
                width: 720),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 6, children: [
          WmPill(label: label, icon: icon, color: color),
          WmPill(
              label: ctmPhotoAge(t, lang, _cam['still_at']?.toString(), _cam['still_source']?.toString()),
              icon: Icons.photo_camera_outlined,
              color: Theme.of(context).colorScheme.primary),
        ]),
        if (_note != null && _note!.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(_note!, key: const ValueKey('ctm-sheet-note')),
        ],
        const SizedBox(height: 12),
        if (fresh)
          FilledButton.tonalIcon(
            key: const ValueKey('ctm-fresh'),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
            icon: _busy
                ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh_rounded),
            label: Text(t.ctmFreshPhoto),
            onPressed: _busy ? null : _fresh,
          )
        else
          Text(t.ctmFreshUnsupported, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
        if (liveOk)
          FilledButton.icon(
            key: const ValueKey('ctm-live'),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
            icon: const Icon(Icons.live_tv_rounded),
            label: Text(t.ctmOpenLive),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ShopLiveScreen(cameraId: _id, cameraName: name))),
          )
        else
          Text(_cam['live_capable'] == true ? t.ctmLiveNotAllowed : t.ctmLiveNotCapable,
              style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
        if ((_cam['still_url'] ?? '').toString().isNotEmpty)
          OutlinedButton.icon(
            key: const ValueKey('ctm-to-watch'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 52)),
            icon: const Icon(Icons.diversity_3_rounded),
            label: Text(t.ctmShareToWatch),
            onPressed: () => showCctvWatchShareSheet(context, widget.source, camera: _id),
          ),
      ]),
    );
  }
}

class _Msg extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final Widget? action;
  const _Msg({required this.icon, required this.title, required this.body, this.action});

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.all(24), children: [
      Icon(icon, size: 48),
      const SizedBox(height: 12),
      Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      Text(body, textAlign: TextAlign.center),
      if (action != null) ...[const SizedBox(height: 16), Center(child: action!)],
    ]);
  }
}
