import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../shop_camera_settings.dart' show ShopWebhookCard, shopSeenLabel;
import '../../cashguard/cashguard_source.dart';
import '../../cctvx/cctvx_source.dart';
import 'cash_guard_screen.dart';
import 'cctvx_inbox.dart';
import 'watchman_add_camera.dart';
import 'watchman_alerts.dart';
import 'watchman_setup.dart';
import 'watchman_source.dart';
import 'watchman_viewers.dart';
import 'watchman_widgets.dart';
import 'watchman_zones.dart';
import 'package:assisto/widgets/app_sheet.dart';

/// cctv1 — HOME & SHOP WATCHMAN: the entry for business AND personal users
/// (not tied to the POS). Behind the server flag `cctv_watchman`; the server
/// answers 403 feature_off while hidden and this screen says so honestly.
///
/// What it shows: every place I own or was invited to view, the gateway's
/// honest state ("offline since …"), the cameras with their last check, and
/// the way to alerts / zones / family viewers / the staff notice. First run:
/// a 3-step explainer and the setup wizard.
class WatchmanScreen extends StatefulWidget {
  final WatchmanSource? source;

  /// Tests / gallery: force the first-run guide on (true) or off (false).
  final bool? guide;
  const WatchmanScreen({super.key, this.source, this.guide});

  @override
  State<WatchmanScreen> createState() => _WatchmanScreenState();
}

const _kGuideSeen = 'wm_guide_seen_v1';

class _WatchmanScreenState extends State<WatchmanScreen> {
  late final WatchmanSource _src =
      widget.source ?? ApiWatchmanSource(context.read<AppState>().api);
  bool _loading = true;
  String? _error;
  bool _featureOff = false;
  Map<String, dynamic> _data = const {};
  bool _showGuide = false;

  @override
  void initState() {
    super.initState();
    _initGuide();
    _load();
  }

  Future<void> _initGuide() async {
    if (widget.guide != null) {
      _showGuide = widget.guide!;
      return;
    }
    try {
      final p = await SharedPreferences.getInstance();
      if (mounted) setState(() => _showGuide = !(p.getBool(_kGuideSeen) ?? false));
    } catch (_) {}
  }

  Future<void> _closeGuide() async {
    setState(() => _showGuide = false);
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kGuideSeen, true);
    } catch (_) {}
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await _src.overview();
      _data = d;
      _featureOff = false;
    } catch (e) {
      if (wmStatus(e) == 403) {
        _featureOff = true;
      } else {
        _error = wmError(e) ?? '';
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _startSetup() async {
    final site = await Navigator.of(context).push<Map<String, dynamic>>(MaterialPageRoute(
        builder: (_) => WatchmanSetupScreen(
            source: _src, canShop: _data['can_shop'] == true)));
    await _load();
    if (site != null && mounted) await showWatchmanPairSheet(context, site);
  }

  Future<void> _addCamera(Map<String, dynamic> site) async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => WatchmanAddCameraScreen(
            source: _src,
            site: site,
            limits: wmMap(_data['limits']),
            credits: (_data['credits'] as num?)?.toInt() ?? 0,
            imouCloud: _data['imou_cloud'] == true)));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(t.wmTitle),
        actions: [
          // cctvx: alerts other owners passed to me / clips shared with me
          IconButton(
            tooltip: t.cxInboxTitle,
            icon: const Icon(Icons.forward_to_inbox_rounded),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const GuardInboxScreen())),
          ),
          IconButton(
            tooltip: t.wmHowItWorks,
            icon: const Icon(Icons.help_outline_rounded),
            onPressed: () => setState(() => _showGuide = !_showGuide),
          ),
        ],
      ),
      body: _body(t),
    );
  }

  Widget _body(AppLocalizations t) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_featureOff) {
      return _Message(icon: Icons.lock_clock_outlined, title: t.wmFeatureOffTitle, body: t.wmFeatureOffBody);
    }
    if (_error != null) {
      return _Message(
        icon: Icons.cloud_off_rounded,
        title: t.wmLoadErrorTitle,
        body: _error!.isNotEmpty ? _error! : t.wmLoadErrorBody,
        action: FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
            onPressed: _load,
            child: Text(t.wmRetry)),
      );
    }
    final sites = wmList(_data['sites']);
    final owned = sites.where((s) => s['role'] == 'owner').toList();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          if (_showGuide || sites.isEmpty)
            WatchmanGuideCard(onClose: sites.isEmpty ? null : _closeGuide),
          if (sites.isEmpty) _Welcome(onStart: _startSetup),
          for (final s in sites)
            _SiteCard(
              site: s,
              notice: wmMap(_data['notice']),
              onChanged: _load,
              onAddCamera: () => _addCamera(s),
              source: _src,
            ),
          if (owned.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.add_home_work_outlined),
                label: Text(t.wmAddPlace),
                onPressed: _startSetup,
              ),
            ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  final IconData icon;
  final String title, body;
  final Widget? action;
  const _Message({required this.icon, required this.title, required this.body, this.action});

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.all(32), children: [
      const SizedBox(height: 40),
      Icon(icon, size: 56, color: Theme.of(context).colorScheme.primary),
      const SizedBox(height: 16),
      Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      Text(body, textAlign: TextAlign.center),
      if (action != null) ...[const SizedBox(height: 20), Center(child: action!)],
    ]);
  }
}

class _Welcome extends StatelessWidget {
  final VoidCallback onStart;
  const _Welcome({required this.onStart});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.wmWelcomeTitle, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 6),
        Text(t.wmWelcomeBody),
        const SizedBox(height: 16),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
          icon: const Icon(Icons.play_arrow_rounded),
          label: Text(t.wmStartSetup),
          onPressed: onStart,
        ),
      ]),
    );
  }
}

class _SiteCard extends StatelessWidget {
  final Map<String, dynamic> site;
  final Map<String, dynamic> notice;
  final Future<void> Function() onChanged;
  final VoidCallback onAddCamera;
  final WatchmanSource source;
  const _SiteCard({
    required this.site,
    required this.notice,
    required this.onChanged,
    required this.onAddCamera,
    required this.source,
  });

  bool get _owner => site['role'] == 'owner';

  Future<void> _cameraAction(BuildContext context, String action, Map<String, dynamic> cam) async {
    final t = AppLocalizations.of(context);
    final nav = Navigator.of(context);
    switch (action) {
      case 'zones':
        await nav.push(MaterialPageRoute(
            builder: (_) => WatchmanZonesScreen(source: source, camera: cam)));
      case 'check':
        await nav.push(MaterialPageRoute(
            builder: (_) => WatchmanAddCameraScreen(
                source: source, site: site, recheck: cam, limits: const {}, credits: 0)));
      case 'push':
        // Hikvision HTTP Listening / Dahua event push: the camera posts its
        // OWN alarms (+ one still) straight to the server — needs this
        // camera's private link (owner-only token).
        String token = '';
        try {
          token = ((await source.camera((cam['id'] as num).toInt()))['camera_token'] ?? '')
              .toString();
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(wmError(e) ?? t.wmGenericError)));
          }
          return;
        }
        if (!context.mounted) return;
        await showAppSheet<void>(
          context: context,
          isScrollControlled: true,
          showDragHandle: true,
          builder: (ctx) => SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: ShopWebhookCard(token: token),
            ),
          ),
        );
        return;
      case 'ezviz':
        await showEzvizLinkSheet(context, cam);
      case 'remove':
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            scrollable: true, // insets: 200% text / keyboard
            title: Text(t.wmRemoveCamTitle),
            content: Text(t.wmRemoveCamBody((cam['name'] ?? '').toString())),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.wmCancel)),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.wmRemove)),
            ],
          ),
        );
        if (ok != true) return;
        try {
          await source.deleteCamera((cam['id'] as num).toInt());
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(wmError(e) ?? t.wmGenericError)));
          }
        }
    }
    await onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    final gw = wmMap(site['gateway_state']);
    final cams = wmList(site['cameras_list']);
    final online = gw['online'] == true;
    final open = (site['open_alerts'] as num?)?.toInt() ?? 0;
    final held = (site['held_today'] as num?)?.toInt() ?? 0;
    final home = site['kind'] == 'home';
    final siteId = (site['id'] as num).toInt();
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(home ? Icons.home_rounded : Icons.storefront_rounded),
            const SizedBox(width: 8),
            Expanded(
              child: Text((site['name'] ?? '').toString(),
                  style: Theme.of(context).textTheme.titleMedium),
            ),
          ]),
          if (!_owner)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(t.wmSharedBy((site['owner_name'] ?? '').toString())),
            ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 6, children: [
            WmPill(
              label: '${wmGatewayName(t, (site['gateway'] ?? '').toString())}: '
                  '${wmGatewayLine(t, context, gw)}',
              icon: online ? Icons.check_circle_rounded : Icons.portable_wifi_off_rounded,
              color: online ? wmOk() : wmWarn(),
            ),
          ]),
          if (!online && _owner)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(gw['never_seen'] == true ? t.wmGatewayNeverHelp : t.wmGatewayOfflineHelp,
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          if (held > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(t.wmHeldToday(wmDigits(lang, held)),
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          const SizedBox(height: 8),
          if (cams.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(_owner ? t.wmNoCamerasOwner : t.wmNoCamerasViewer),
            ),
          for (final c in cams) _CameraRow(cam: c, owner: _owner, onAction: (a) => _cameraAction(context, a, c)),
          const Divider(height: 20),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.tonalIcon(
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              icon: const Icon(Icons.notifications_rounded),
              label: Text(open > 0 ? t.wmAlertsOpen(wmDigits(lang, open)) : t.wmAlerts),
              onPressed: () async {
                await Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => WatchmanAlertsScreen(source: source, siteId: siteId, owner: _owner)));
                await onChanged();
              },
            ),
            if (_owner) ...[
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.point_of_sale_rounded),
                label: Text(t.cgTitle),
                onPressed: () async {
                  final api = context.read<AppState>().api;
                  await Navigator.of(context).push(MaterialPageRoute(
                      builder: (ctx) => CashGuardScreen(
                            source: ApiCashGuardSource(api),
                            siteId: siteId,
                            // cctvx: guard settings, report, placement, privacy kit
                            extras: ApiCctvxSource(api),
                            watchman: source,
                            cameras: cams,
                            hours: wmMap(site['hours']),
                            onDrawZone: cams.isEmpty
                                ? null
                                : () => Navigator.of(ctx).push(MaterialPageRoute(
                                    builder: (_) => WatchmanZonesScreen(source: source, camera: cams.first))),
                          )));
                  await onChanged();
                },
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.add_a_photo_outlined),
                label: Text(t.wmAddCamera),
                onPressed: onAddCamera,
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.link_rounded),
                label: Text(t.wmConnectGateway),
                onPressed: () => showWatchmanPairSheet(context, site),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.family_restroom_rounded),
                label: Text(t.wmFamily),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => WatchmanViewersScreen(source: source, siteId: siteId))),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.campaign_outlined),
                label: Text(t.wmNotice),
                onPressed: () => showWatchmanNoticeSheet(context, notice),
              ),
            ],
          ]),
        ]),
      ),
    );
  }
}

class _CameraRow extends StatelessWidget {
  final Map<String, dynamic> cam;
  final bool owner;
  final ValueChanged<String> onAction;
  const _CameraRow({required this.cam, required this.owner, required this.onAction});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final compat = wmMap(cam['compat']);
    final vendor = (cam['vendor'] ?? '').toString();
    final checked = compat.isNotEmpty;
    final works = compat['ok'] == true;
    final String checkLabel;
    final Color checkColor;
    final IconData checkIcon;
    if (vendor == 'phone') {
      checkLabel = t.wmCamPhoneOwn;
      checkColor = wmOk();
      checkIcon = Icons.phone_android_rounded;
    } else if (!checked) {
      checkLabel = cam['cloud_alarms'] == true ? t.wmCamCloudOnly : t.wmCamNotChecked;
      checkColor = wmWarn();
      checkIcon = Icons.help_outline_rounded;
    } else if (works) {
      checkLabel = t.wmCamWorks;
      checkColor = wmOk();
      checkIcon = Icons.check_circle_rounded;
    } else {
      checkLabel = t.wmCamCheckFailed;
      checkColor = wmBad();
      checkIcon = Icons.error_outline_rounded;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Padding(
          padding: EdgeInsets.only(top: 12),
          child: Icon(Icons.videocam_rounded),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const SizedBox(height: 10),
            Text((cam['name'] ?? '').toString().isEmpty ? t.wmUnnamedCamera : cam['name'].toString(),
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text('${wmVendorName(t, vendor)} · ${shopSeenLabel(t, context, cam)}',
                style: Theme.of(context).textTheme.bodySmall),
            if (owner) ...[
              const SizedBox(height: 4),
              WmPill(label: checkLabel, icon: checkIcon, color: checkColor),
            ],
          ]),
        ),
        if (owner)
          PopupMenuButton<String>(
            tooltip: t.wmCameraMenu,
            onSelected: onAction,
            itemBuilder: (_) => [
              PopupMenuItem(value: 'zones', child: Text(t.wmZonesSchedule)),
              if (vendor != 'phone') PopupMenuItem(value: 'check', child: Text(t.wmCheckAgain)),
              if (vendor == 'hikvision' || vendor == 'dahua')
                PopupMenuItem(value: 'push', child: Text(t.shopHookTitle)),
              if (vendor == 'ezviz') PopupMenuItem(value: 'ezviz', child: Text(t.cgEzvizLink)),
              PopupMenuItem(value: 'remove', child: Text(t.wmRemove)),
            ],
          ),
      ]),
    );
  }
}


/// cashguard: link an EZVIZ camera's OWN alarms (serial + the label's
/// Verification Code — used once, never stored).
Future<void> showEzvizLinkSheet(BuildContext context, Map<String, dynamic> cam) async {
  final api = context.read<AppState>().api;
  final src = ApiCashGuardSource(api);
  await showAppSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _EzvizSheet(source: src, cameraId: (cam['id'] as num).toInt()),
  );
}

class _EzvizSheet extends StatefulWidget {
  final CashGuardSource source;
  final int cameraId;
  const _EzvizSheet({required this.source, required this.cameraId});

  @override
  State<_EzvizSheet> createState() => _EzvizSheetState();
}

class _EzvizSheetState extends State<_EzvizSheet> {
  final _serial = TextEditingController();
  final _code = TextEditingController();
  bool _busy = false;
  String _msg = '';
  bool _ok = false;

  @override
  void dispose() {
    _serial.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _link() async {
    final t = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _msg = '';
    });
    try {
      await widget.source.linkEzviz(widget.cameraId, _serial.text.trim(), _code.text.trim());
      _ok = true;
      _msg = t.cgEzvizLinked;
    } catch (e) {
      _msg = wmError(e) ?? t.wmGenericError;
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.cgEzvizLink, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        Text(t.cgEzvizHelp),
        const SizedBox(height: 10),
        TextField(
          controller: _serial,
          decoration: InputDecoration(labelText: t.cgEzvizSerial, border: const OutlineInputBorder()),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _code,
          decoration: InputDecoration(labelText: t.cgEzvizCode, border: const OutlineInputBorder()),
        ),
        const SizedBox(height: 10),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _busy || _ok ? null : _link,
          child: Text(t.cgEzvizLinkButton),
        ),
        if (_msg.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_msg,
                style: TextStyle(color: _ok ? null : Theme.of(context).colorScheme.error)),
          ),
      ]),
    );
  }
}
