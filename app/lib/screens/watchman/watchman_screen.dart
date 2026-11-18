import 'package:flutter/material.dart';
import '../../theme.dart' show AType;
import '../../ds/ds.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../phonecam/phonecam_timeline_screen.dart';
import '../../l10n/app_localizations.dart';
import '../../billing/cctv_plan_screen.dart'; // cctvprice
import '../../billing/cctv_plan_source.dart' show ApiCctvPlanApi;
import '../../plans_v2/buy_inside.dart';
import '../../state.dart';
import '../shop_camera_settings.dart' show ShopWebhookCard, shopSeenLabel;
import '../../cashguard/cashguard_source.dart';
import '../../cctvx/cctv_evidence_source.dart';
import '../../cctvx/cctvx_source.dart';
import 'camera_label.dart';
import 'cctv_recording_screen.dart';
import 'cash_guard_screen.dart';
import 'auto_guard_screen.dart'; // cctvarm
import 'cctvx_inbox.dart';
import 'activity_screen.dart'; // cctvactivity
import '../../cctvx/activity_source.dart'; // cctvactivity
import '../../cctvact/cctvact_source.dart'; // cctvact
import 'cctv_act_screens.dart'; // cctvact
import 'watchman_add_camera.dart';
import 'watchman_alerts.dart';
import 'watchman_setup.dart';
import 'watchman_source.dart';
import 'watchman_viewers.dart';
import 'watchman_widgets.dart';
import 'watchman_zones.dart';
import 'cctv_grid_screen.dart'; // cctvteam
import 'cctv_team_screens.dart'; // cctvteam
import 'cctv_team_source.dart'; // cctvteam
import 'package:assisto/widgets/app_sheet.dart';
import '../../widgets/cv_empty.dart';
import '../shop_box_screen.dart';
import '../../widgets/where_to_buy.dart'; // chipbuy
import '../../feature_flags.dart'; // cctvphone
import '../../phonecam/phonecam_api.dart'; // cctvphone
import '../shop_live_screen.dart'; // cctvphone: phone-camera live view
import '../../cctvguard/cctv_usage_card.dart'; // cctvguard: this month's use
import 'old_phone_hub.dart'; // gap-cctv D3
import 'cctv_clips_screen.dart'; // gap-cctv D4
import '../../cctvguard/vendor_live_screen.dart'; // cctvguard: Imou/EZVIZ live
import '../../cctvconnect/cctv_connect_screen.dart'; // cctvconnect: brand clouds
import '../../cctvconnect/dvr_health_card.dart'; // cctvconnect: daily DVR check
import 'cctv_installer_screens.dart'; // cctvroles: installer partners

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

  /// cctvteam: grid / roles / share links / access log seam (tests inject).
  final CctvTeamSource? team;

  /// Tests / gallery: force the first-run guide on (true) or off (false).
  final bool? guide;

  /// cctvguard: tests / gallery inject "this month's use".
  final Future<Map<String, dynamic>> Function()? usageLoader;
  const WatchmanScreen({super.key, this.source, this.team, this.guide, this.usageLoader});

  @override
  State<WatchmanScreen> createState() => _WatchmanScreenState();
}

const _kGuideSeen = 'wm_guide_seen_v1';

class _WatchmanScreenState extends State<WatchmanScreen> {
  late final WatchmanSource _src =
      widget.source ?? ApiWatchmanSource(context.read<AppState>().api);
  late final CctvTeamSource _team =
      widget.team ?? ApiCctvTeamSource(context.read<AppState>().api);
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

  /// buyinside: no active CCTV plan -> the locked CCTV screen (7 days free /
  /// 500 Tk for 2 cameras) right here, then back on this screen, unlocked;
  /// an active plan -> the full plan screen (cameras, yearly, manage).
  Future<void> _openPlan() async {
    var active = false;
    try {
      final d = await ApiCctvPlanApi(context.read<AppState>().api).load();
      final st = d['status'];
      active = st is Map && st['status'] == 'active';
    } catch (_) {
      active = true; // offline: the plan screen shows its own honest state
    }
    if (!mounted) return;
    if (active) {
      await Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const CctvPlanScreen()));
      return;
    }
    final ok = await BuyInside.open(context, 'cctv');
    if (ok && mounted) await _load();
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
    if (site == null || !mounted) return;
    // cctvveh: the pairing sheet ends in "Next: add a camera" (no dead end).
    var next = false;
    await showWatchmanPairSheet(context, site, onNext: () => next = true);
    if (!next || !mounted) return;
    final fresh = wmList(_data['sites']).firstWhere(
        (s) => s['id'] == site['id'], orElse: () => site);
    await _addCamera(fresh);
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
          // cctvteam: every place + camera on one screen (still photos)
          if (!_loading && !_featureOff && wmList(_data['sites']).isNotEmpty)
            IconButton(
              key: const ValueKey('wm-grid'),
              tooltip: AppLocalizations.of(context).ctmGridTitle,
              icon: const Icon(Icons.grid_view_rounded),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => CctvGridScreen(source: _team, onSetup: () => Navigator.of(context).pop()))),
            ),
          // cctvroles (V3 J): CCTV technicians — installer partner
          if (!_loading && !_featureOff)
            IconButton(
              key: const ValueKey('wm-partner'),
              tooltip: t.ctrPartTitle,
              icon: const Icon(Icons.handyman_outlined),
              onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => CctvPartnerScreen(source: _team))),
            ),
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
      // cctvveh: honest + never a dead end
      return _Message(
        icon: Icons.lock_clock_outlined,
        title: t.wmFeatureOffTitle,
        body: '${t.wmFeatureOffBody}\n${t.cvvFeatureOffHow}',
        action: Navigator.of(context).canPop()
            ? FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
                onPressed: () => Navigator.of(context).maybePop(),
                child: Text(t.cvvGoBack))
            : null,
      );
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
        padding: withNavBarInset(context, const EdgeInsets.only(bottom: 32)),
        children: [
          // design3 (page rule): first run = the welcome hero with the ONE
          // main action first; how it works comes after it
          if (sites.isEmpty) _Welcome(onStart: _startSetup),
          if (_showGuide || sites.isEmpty)
            WatchmanGuideCard(onClose: sites.isEmpty ? null : _closeGuide),
          if (sites.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: WhereToBuyLink(product: BuyProduct.cctv),
            ),
          for (final s in sites)
            _SiteCard(
              site: s,
              notice: wmMap(_data['notice']),
              onChanged: _load,
              onAddCamera: () => _addCamera(s),
              source: _src,
              team: _team,
            ),
          // cctvguard (order G): live traffic this month, per camera
          // (an injected test source never reaches the network: tests pass usageLoader)
          if (owned.isNotEmpty && (widget.usageLoader != null || widget.source == null))
            CctvUsageCard(load: widget.usageLoader),
          // design2 (page rule): live places first, the plan (a setting) after them
          // cctvprice: the CCTV plan (price per camera count, trial, add-on)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: DsCard(
              padding: EdgeInsets.zero,
              child: ListTile(
                minVerticalPadding: 12,
                leading: const Icon(Icons.workspace_premium_outlined),
                title: Text(t.cplEntryTitle),
                subtitle: Text(t.cplEntrySub),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: _openPlan,
              ),
            ),
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
          // cctvphone: on the OLD phone — become a camera (code / QR link)
          // gap-cctv D3: ONE entry for every old-phone / small-box way
          if (pcOn())
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: OutlinedButton.icon(
              key: const ValueKey('wm-phonecam-this'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              icon: const Icon(Icons.phone_android_rounded),
              label: Text(t.gcvHubTitle),
              onPressed: () => showOldPhoneHub(context),
            ),
          ),
          // gap-cctv D3: Shop Box is no longer a second tile — its POS,
          // day-end and reports live here as one section of CCTV
          if (pcOn() && (owned.isNotEmpty || sites.isEmpty))
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: DsCard(
                padding: EdgeInsets.zero,
                child: ListTile(
                  key: const ValueKey('wm-shop-tools'),
                  minVerticalPadding: 12,
                  leading: const Icon(Icons.storefront_rounded),
                  title: Text(t.gcvShopToolsTitle),
                  subtitle: Text(t.gcvShopToolsSub),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(context)
                      .push(MaterialPageRoute(builder: (_) => const ShopBoxScreen())),
                ),
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
    // design2: the DS message card (drawn illustration, title, body, action)
    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      DsCard(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(children: [
          DsIllustration(icon: icon),
          const SizedBox(height: Gap.lg),
          Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Gap.sm),
          Text(body,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: DsTokens.of(context).muted)),
          if (action != null) ...[const SizedBox(height: Gap.lg), Center(child: action!)],
        ]),
      ),
    ]);
  }
}

class _Welcome extends StatelessWidget {
  final VoidCallback onStart;
  const _Welcome({required this.onStart});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    // design3: a soft DS hero (illustration, title, short body, the one
    // glowing button)
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.sm),
      child: DsHeroCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Align(
            alignment: AlignmentDirectional.centerStart,
            child: DsIllustration(icon: Icons.videocam_rounded, size: 72),
          ),
          const SizedBox(height: Gap.md),
          Text(t.wmWelcomeTitle,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: Gap.xs),
          Text(t.cvvWelcomeBody,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: DsTokens.of(context).muted)),
          const SizedBox(height: Gap.lg),
          DsButton(
            expand: true,
            icon: Icons.play_arrow_rounded,
            label: t.wmStartSetup,
            onPressed: onStart,
          ),
        ]),
      ),
    );
  }
}

class _SiteCard extends StatelessWidget {
  final Map<String, dynamic> site;
  final Map<String, dynamic> notice;
  final Future<void> Function() onChanged;
  final VoidCallback onAddCamera;
  final WatchmanSource source;
  final CctvTeamSource team;
  const _SiteCard({
    required this.site,
    required this.notice,
    required this.onChanged,
    required this.onAddCamera,
    required this.source,
    required this.team,
  });

  bool get _owner => site['role'] == 'owner';

  Future<void> _cameraAction(BuildContext context, String action, Map<String, dynamic> cam) async {
    final t = AppLocalizations.of(context);
    final nav = Navigator.of(context);
    switch (action) {
      // cctvphone: live view of a phone camera (owner or an allowed viewer)
      case 'live':
        await nav.push(MaterialPageRoute(
            builder: (_) => ShopLiveScreen(
                cameraId: (cam['id'] as num).toInt(),
                cameraName: (cam['name'] ?? '').toString())));
      // cctvplay: the phone camera's recordings (timeline + on-demand minute)
      case 'pcrec':
        await nav.push(MaterialPageRoute(
            builder: (_) => PhoneCamTimelineScreen(
                cameraId: (cam['id'] as num).toInt(),
                cameraName: (cam['name'] ?? '').toString(),
                source: ApiPhoneCamRecSource(context.read<AppState>().api))));
      case 'viewers_live':
        // order I: OFF by default; turning it on says plainly who will see
        final turnOn = cam['viewers_live'] != true;
        if (turnOn) {
          final ok = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              scrollable: true,
              title: Text(t.pcViewersLive),
              content: Text(t.pcViewersLiveConfirm),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.wmCancel)),
                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.pcViewersLiveAllow)),
              ],
            ),
          );
          if (ok != true || !context.mounted) return;
        }
        try {
          await context.read<AppState>().api.phoneCamSettings(
              (cam['id'] as num).toInt(), {'viewers_live': turnOn});
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(wmError(e) ?? t.wmGenericError)));
          }
        }
      case 'zones':
        await nav.push(MaterialPageRoute(
            builder: (_) => WatchmanZonesScreen(source: source, camera: cam)));
      // cctvguard: Imou / EZVIZ cloud live — SD first, HD on tap, 5-min idle stop
      case 'vlive':
        await nav.push(MaterialPageRoute(
            builder: (_) => VendorLiveScreen(
                cameraId: (cam['id'] as num).toInt(),
                cameraName: (cam['name'] ?? '').toString())));
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
      case 'recording':
        // cctvevidence: SD card, video add-on, evidence-pack address
        final api = context.read<AppState>().api;
        await nav.push(MaterialPageRoute(
            builder: (_) => CctvRecordingScreen(
                source: ApiCctvEvidenceSource(api),
                cameraId: (cam['id'] as num).toInt(),
                cameraName: (cam['name'] ?? '').toString())));
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
    // design2: each place is an alive DS card; a gently pulsing dot shows the
    // recorder / gateway is live (static in lite mode)
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: DsCard(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: DsTokens.of(context).primarySoft,
                borderRadius: BorderRadius.circular(DsRadius.card),
              ),
              child: Icon(home ? Icons.home_rounded : Icons.storefront_rounded,
                  color: DsTokens.of(context).primaryInk),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text((site['name'] ?? '').toString(),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            ),
            if (online) DsStatusDot(color: DsTokens.of(context).success),
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
          // cctvveh: a real empty state — benefit + big button + how-to
          if (cams.isEmpty && _owner)
            CvEmptyBlock(
              compact: true,
              icon: Icons.videocam_outlined,
              title: t.cvvNoCamTitle,
              benefit: t.cvvNoCamBenefit,
              primaryIcon: Icons.add_a_photo_outlined,
              primaryLabel: t.wmAddCamera,
              onPrimary: onAddCamera,
              steps: [t.cvvNoCamStep1, t.cvvNoCamStep2, t.cvvNoCamStep3],
            ),
          // cctvphone: the cheapest start — an old phone in a drawer
          if (cams.isEmpty && _owner && pcOn())
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: OutlinedButton.icon(
                key: const ValueKey('wm-phonecam-pair-empty'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.phone_android_rounded),
                label: Text(t.gcvHubTitle), // gap-cctv D3: one old-phone entry
                onPressed: () => showOldPhoneHub(context, siteId: siteId, onChanged: onChanged),
              ),
            ),
          if (cams.isEmpty && _owner) const WhereToBuyLink(product: BuyProduct.cctv),
          if (cams.isEmpty && !_owner)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(t.cvvNoCamViewer),
            ),
          for (final c in cams) _CameraRow(cam: c, owner: _owner, onAction: (a) => _cameraAction(context, a, c)),
          // cctvconnect (Guard V3 B): the daily green check (hidden until a DVR reports)
          DvrHealthCard(key: ValueKey('dvr-health-$siteId'), siteId: siteId, owner: _owner),
          const Divider(height: 20),
          // design3 (flagship): the place card in two groups — WATCH first
          // (alerts full width, then clips / activity / reports / auto guard),
          // then the owner's CAMERAS & SETUP tools under a small header.
          SizedBox(
            width: double.infinity,
            child:
            FilledButton.tonalIcon(
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              icon: const Icon(Icons.notifications_rounded),
              label: Text(open > 0 ? t.wmAlertsOpen(wmDigits(lang, open)) : t.wmAlerts),
              onPressed: () async {
                await Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => WatchmanAlertsScreen(
                        source: source,
                        siteId: siteId,
                        owner: _owner,
                        hasCamera: cams.isNotEmpty,
                        // empty alerts: the first real step (zones / a camera)
                        onSetup: !_owner
                            ? null
                            : cams.isEmpty
                                ? onAddCamera
                                : () => Navigator.of(context).push(MaterialPageRoute(
                                    builder: (_) =>
                                        WatchmanZonesScreen(source: source, camera: cams.first))))));
                await onChanged();
              },
            ),
          ),
          const SizedBox(height: Gap.sm),
          // design3: tools as rows of ONE DS group (ragged button widths before)
          DsGroup(margin: EdgeInsets.zero, flat: true, children: [
            // gap-cctv D4: every clip the server still keeps, by camera + day
            if (cams.isNotEmpty)
              DsListRow(
                key: const ValueKey('wm-past-clips'),
                leading: Icon(Icons.video_library_outlined, color: DsTokens.of(context).primaryInk),
                title: t.gcvClipsEntry,
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => CctvClipsScreen(
                        siteId: siteId,
                        siteName: (site['name'] ?? '').toString(),
                        owner: _owner))),
              ),
            // cctvactivity (W10): the day in numbers, visitor log, time-lapse
            if (cams.isNotEmpty)
              DsListRow(
                key: const ValueKey('wm-activity'),
                leading: Icon(Icons.insights_rounded, color: DsTokens.of(context).primaryInk),
                title: t.cactEntry,
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (ctx) => ActivityScreen(
                        source: ApiActivitySource(ctx.read<AppState>().api),
                        siteId: siteId,
                        siteName: (site['name'] ?? '').toString(),
                        owner: _owner))),
              ),
            // cctvact (V3 E/G/F/D): closing report, ask, sales match, automations
            if (cams.isNotEmpty)
              DsListRow(
                key: const ValueKey('wm-cv3-hub'),
                leading: Icon(Icons.summarize_rounded, color: DsTokens.of(context).primaryInk),
                title: t.cv3HubEntry,
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (ctx) => CctvActHubScreen(
                        source: ApiCctvActSource(ctx.read<AppState>().api),
                        events: ApiCctvxSource(ctx.read<AppState>().api),
                        siteId: siteId,
                        siteName: (site['name'] ?? '').toString(),
                        owner: _owner))),
              ),
            // cctvarm: auto guard (owner settings / a member's own consent)
            DsListRow(
                key: const ValueKey('wm-auto-guard'),
                leading: Icon(Icons.shield_moon_outlined, color: DsTokens.of(context).primaryInk),
                title: t.carmTitle,
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => AutoGuardScreen(siteId: siteId, owner: _owner))),
              ),
          ]),
          if (_owner) ...[
            Padding(
              padding: const EdgeInsets.only(top: Gap.md, bottom: Gap.sm),
              child: Text(t.d3CctvSetupGroup,
                  style: AType.titleSmall.copyWith(
                      fontWeight: FontWeight.w700, color: DsTokens.of(context).muted)),
            ),
            DsGroup(margin: EdgeInsets.zero, flat: true, children: [
              DsListRow(
                leading: Icon(Icons.point_of_sale_rounded, color: DsTokens.of(context).primaryInk),
                title: t.cgTitle,
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () async {
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
                            // cctvveh: no camera yet → the checklist offers "Add camera"
                            onAddCamera: cams.isEmpty
                                ? () {
                                    Navigator.of(ctx).pop();
                                    onAddCamera();
                                  }
                                : null,
                          )));
                  await onChanged();
                },
              ),
              if (cams.isNotEmpty) // empty: the big button above
                DsListRow(
                leading: Icon(Icons.add_a_photo_outlined, color: DsTokens.of(context).primaryInk),
                title: t.wmAddCamera,
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: onAddCamera,
              ),
              if (cams.isNotEmpty && pcOn()) // cctvphone
                DsListRow(
                key: const ValueKey('wm-phonecam-pair'),
                leading: Icon(Icons.phone_android_rounded, color: DsTokens.of(context).primaryInk),
                title: t.gcvHubTitle,
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => showOldPhoneHub(context, siteId: siteId, onChanged: onChanged),
              ),
              DsListRow(
                leading: Icon(Icons.link_rounded, color: DsTokens.of(context).primaryInk),
                title: t.wmConnectGateway,
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => showWatchmanPairSheet(context, site),
              ),
              // cctvconnect (Guard V3 A1): existing DVR / camera through its brand cloud
              DsListRow(
                key: const ValueKey('wm-brand-cloud'),
                leading: Icon(Icons.cloud_sync_rounded, color: DsTokens.of(context).primaryInk),
                title: t.ccnEntry,
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () async {
                  await Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => CctvConnectScreen(
                          siteId: siteId,
                          siteName: (site['name'] ?? '').toString(),
                          lanGateway: (site['gateway'] ?? '').toString() != 'phone', // gap-cctv
                          onFindOnWifi: onAddCamera)));
                  await onChanged();
                },
              ),
            ]),
          ],
          // gap-cctv: people, sharing and the notice fold into one row —
          // the place card was a wall of 15 buttons (owner-only tools).
          if (_owner)
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                key: const ValueKey('wm-manage'),
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 8),
                expandedAlignment: AlignmentDirectional.centerStart,
                leading: const Icon(Icons.manage_accounts_rounded),
                title: Text(t.gcvManageTitle),
                subtitle: Text(t.gcvManageSub),
                children: [
                  Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.family_restroom_rounded),
                label: Text(t.wmFamily),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => WatchmanViewersScreen(source: source, siteId: siteId, team: team))),
              ),
              // cctvteam: a view-only, time-limited link for someone without the app
              if (cams.isNotEmpty)
                OutlinedButton.icon(
                  key: const ValueKey('wm-share-links'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                  icon: const Icon(Icons.add_link_rounded),
                  label: Text(t.ctmLinksTitle),
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => CctvShareLinksScreen(
                          source: team, siteId: siteId, siteName: (site['name'] ?? '').toString()))),
                ),
              // cctvteam: who looked at which camera, when
              OutlinedButton.icon(
                key: const ValueKey('wm-access-log'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.manage_search_rounded),
                label: Text(t.ctrLogTitle),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => CctvAccessLogScreen(source: team, siteId: siteId))),
              ),
              // cctvroles (V3 J): a local technician checks the setup — never video
              OutlinedButton.icon(
                key: const ValueKey('wm-installer'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.handyman_outlined),
                label: Text(t.ctrInstTitle),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => CctvInstallerScreen(source: team, siteId: siteId))),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.campaign_outlined),
                label: Text(t.wmNotice),
                onPressed: () => showWatchmanNoticeSheet(context, notice),
              ),
              // gap-cctv D3: Shop Box (POS, day-end, reports) is the "Shop tools"
              // section at the bottom of this screen — not repeated per place
                  ]),
                ],
              ),
            ),
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
                style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text('${wmVendorName(t, vendor)} · ${shopSeenLabel(t, context, cam)}',
                style: Theme.of(context).textTheme.bodySmall),
            if (vendor == 'phone' && wmMap(cam['health']).isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: PhoneCamHealthPill(health: wmMap(cam['health'])),
              ),
            if (owner) ...[
              const SizedBox(height: 4),
              WmPill(label: checkLabel, icon: checkIcon, color: checkColor),
            ],
            // cctvconnect: bound to Assisto's Imou developer account for the
            // owner's own test (owner 9 Nov 17:20) — always visible
            if (wmMap(cam['compat'])['owner_test'] == true)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: WmPill(
                    key: ValueKey('wm-owner-test-${cam['id']}'),
                    label: t.ccnOwnerTest,
                    icon: Icons.science_rounded,
                    color: wmWarn()),
              ),
          ]),
        ),
        // cctvphone: one-tap live view of a phone camera
        if (vendor == 'phone' && cam['online'] == true && cam['live_capable'] == true &&
            (owner || cam['viewers_live'] == true))
          IconButton(
            key: ValueKey('wm-live-${cam['id']}'),
            tooltip: t.pcLive,
            icon: const Icon(Icons.live_tv_rounded),
            onPressed: () => onAction('live'),
          ),
        // cctvplay: recordings of a phone camera (same rule as live)
        if (vendor == 'phone' && (owner || cam['viewers_live'] == true))
          IconButton(
            key: ValueKey('wm-pcrec-${cam['id']}'),
            tooltip: t.pcrTimelineTitle,
            icon: const Icon(Icons.video_library_outlined),
            onPressed: () => onAction('pcrec'),
          ),
        // cctvguard: one-tap cloud live of a linked Imou / EZVIZ camera;
        // camflows: also a Dahua / Hikvision camera added through its brand cloud
        if (owner &&
            const {'imou', 'ezviz', 'dahua', 'hikvision'}.contains(vendor) &&
            cam['cloud_alarms'] == true)
          IconButton(
            key: ValueKey('wm-vlive-${cam['id']}'),
            tooltip: t.cgVendorLiveTitle,
            icon: const Icon(Icons.live_tv_rounded),
            onPressed: () => onAction('vlive'),
          ),
        if (owner)
          PopupMenuButton<String>(
            tooltip: t.wmCameraMenu,
            onSelected: onAction,
            itemBuilder: (_) => [
              PopupMenuItem(value: 'zones', child: Text(t.wmZonesSchedule)),
              if (vendor == 'phone')
                CheckedPopupMenuItem(
                    value: 'viewers_live',
                    checked: cam['viewers_live'] == true,
                    child: Text(t.pcViewersLive)),
              if (vendor != 'phone') PopupMenuItem(value: 'check', child: Text(t.wmCheckAgain)),
              if (vendor == 'hikvision' || vendor == 'dahua')
                PopupMenuItem(value: 'push', child: Text(t.shopHookTitle)),
              if (vendor == 'ezviz') PopupMenuItem(value: 'ezviz', child: Text(t.cgEzvizLink)),
              if (vendor != 'phone') PopupMenuItem(value: 'recording', child: Text(t.cevTitle)),
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
  bool _info = false; // _msg is a neutral note (paste result), not an error

  @override
  void dispose() {
    _serial.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _pasteLabel() async {
    final t = AppLocalizations.of(context);
    ClipboardData? data;
    try {
      data = await Clipboard.getData(Clipboard.kTextPlain);
    } catch (_) {
      data = null;
    }
    final lab = parseCameraLabel(data?.text);
    if (!mounted) return;
    setState(() {
      if (lab == null) {
        _msg = t.wmPasteLabelNone;
        _info = true;
        return;
      }
      _info = true;
      _serial.text = lab.serial;
      if (lab.code.isNotEmpty) _code.text = lab.code;
      _msg = lab.code.isNotEmpty ? t.wmPasteLabelBoth : t.wmPasteLabelSerial;
    });
  }

  Future<void> _link() async {
    final t = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _msg = '';
      _info = false;
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
        // cctv100: the sticker's QR text (copied from the phone camera) fills both
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('ezPasteLabel'),
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: _busy || _ok ? null : _pasteLabel,
            icon: const Icon(Icons.qr_code_2_rounded),
            label: Text(t.wmPasteLabel),
          ),
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
                style: AType.bodyMedium.copyWith(color: _ok || _info ? null : Theme.of(context).colorScheme.error)),
          ),
      ]),
    );
  }
}


/// cctvphone: battery / charger / heat / dark of a phone camera, honest and
/// readable (icon + words, never colour alone).
class PhoneCamHealthPill extends StatelessWidget {
  final Map<String, dynamic> health;
  const PhoneCamHealthPill({super.key, required this.health});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    final lvl = health['level'];
    final charging = health['charging'];
    final temp = health['temp_c'];
    final parts = <String>[
      if (lvl is num) t.pcBattery(wmDigits(lang, lvl.round())),
      if (charging == true) t.pcCharging,
      if (charging == false) t.pcWarnUnplugged,
      if (temp is num && temp >= 45) t.pcWarnHot,
      if (health['dark'] == true) t.pcWarnDark,
    ];
    final bad = charging == false || (temp is num && temp >= 45) || health['dark'] == true;
    return WmPill(
      label: parts.join(' · '),
      icon: charging == true ? Icons.battery_charging_full_rounded : Icons.battery_alert_rounded,
      color: bad ? wmWarn() : wmOk(),
    );
  }
}

/// cctvphone: phone-as-camera sits behind the CCTV switch `cctv_watchman`.
bool pcOn() => FeatureFlags.instance.isOn('cctv_watchman');
