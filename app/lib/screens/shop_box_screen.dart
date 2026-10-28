import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/ladder_common.dart' show fmtInt;
import '../widgets/skeleton.dart';
import 'credits_screen.dart';
import 'plans_screen.dart';
import 'shop_box_mode_screen.dart';
import 'shop_camera_settings.dart';
import 'shop_eod_screen.dart';
import 'package:assisto/widgets/app_sheet.dart';
import '../services/error_kind.dart' show honestFailText; // qa2

/// SHOP BOX — CCTV loss-prevention (Part 4, Business tier). APP UI ONLY; the
/// Django backend is already built + deployed (core/shop_views.py).
///
/// PRIVACY-FIRST, SIGNALS-ONLY. There is NO video anywhere in this screen and
/// never will be here: the edge "Shop Box" detects on-device and only sends
/// SIGNALS plus at most one small snapshot; no video leaves the shop. Alerts
/// are always worded "please check camera X" (never the word for theft), and
/// always show the confidence %. The owner marks each alert checked or false
/// alarm.
///
/// Business-plan gated: a non-Business user sees an honest upsell card instead
/// of the management UI. If the plan state can't be determined we DEGRADE
/// gracefully and still show the UI (the backend re-gates server-side anyway).
///
/// Four tabs: Sites · Cameras · Alerts · Report. All strings are ARB keys
/// (en + bn parity); no Bangla literal lives in this file.
class ShopBoxScreen extends StatefulWidget {
  /// 0 Sites · 1 Cameras · 2 Alerts · 3 Report (gallery / deep links).
  final int initialTab;
  const ShopBoxScreen({super.key, this.initialTab = 0});
  @override
  State<ShopBoxScreen> createState() => _ShopBoxScreenState();
}

class _ShopBoxScreenState extends State<ShopBoxScreen> {
  bool _planLoading = true;
  bool _isBusiness = false;
  // Null = we couldn't determine the plan -> degrade gracefully (show UI).
  bool _planKnown = false;

  bool _sitesLoading = true;
  bool _sitesError = false;
  List<Map<String, dynamic>> _sites = [];
  int? _siteId; // currently selected site

  @override
  void initState() {
    super.initState();
    _loadPlan();
    _loadSites();
  }

  Future<void> _loadPlan() async {
    final api = context.read<AppState>().api;
    try {
      final p = await api.plan();
      final slug = (p['plan'] ?? '').toString().toLowerCase();
      _isBusiness = slug == 'business';
      _planKnown = slug.isNotEmpty;
    } catch (_) {
      // Unknown plan -> do NOT hard-block; degrade gracefully.
      _planKnown = false;
      _isBusiness = false;
    }
    if (mounted) setState(() => _planLoading = false);
  }

  Future<void> _loadSites() async {
    setState(() {
      _sitesLoading = true;
      _sitesError = false;
    });
    final api = context.read<AppState>().api;
    try {
      final r = await api.shopSites();
      _sites = ((r['sites'] ?? []) as List).cast<Map<String, dynamic>>();
      if (_siteId == null && _sites.isNotEmpty) {
        _siteId = _sites.first['id'] as int?;
      } else if (_siteId != null && !_sites.any((s) => s['id'] == _siteId)) {
        _siteId = _sites.isNotEmpty ? _sites.first['id'] as int? : null;
      }
    } catch (_) {
      _sitesError = true;
    }
    if (mounted) setState(() => _sitesLoading = false);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Map<String, dynamic>? get _selectedSite {
    for (final s in _sites) {
      if (s['id'] == _siteId) return s;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    // Gate on Business; show the upsell only when we KNOW the plan is not it.
    final gated = _planKnown && !_isBusiness;
    if (gated) {
      return Scaffold(
        appBar: AppBar(title: Text(t.shopBoxTitle)),
        body: _UpsellBody(onSeePlans: () {
          Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const PlansScreen()));
        }),
      );
    }

    return DefaultTabController(
      length: 4,
      initialIndex: widget.initialTab.clamp(0, 3),
      child: Scaffold(
        appBar: AppBar(
          title: Text(t.shopBoxTitle),
          bottom: TabBar(isScrollable: true, tabs: [
            Tab(text: t.shopBoxTabSites),
            Tab(text: t.shopBoxTabCameras),
            Tab(text: t.shopBoxTabAlerts),
            Tab(text: t.shopBoxTabReport),
          ]),
        ),
        body: _planLoading
            ? const SkeletonList()
            : TabBarView(children: [
                _SitesTab(
                  loading: _sitesLoading,
                  error: _sitesError,
                  sites: _sites,
                  selectedId: _siteId,
                  onReload: _loadSites,
                  onSelect: (id) => setState(() => _siteId = id),
                  onToast: _toast,
                ),
                _CamerasTab(
                  site: _selectedSite,
                  onToast: _toast,
                ),
                _AlertsTab(
                  site: _selectedSite,
                  onToast: _toast,
                ),
                _ReportTab(
                  site: _selectedSite,
                ),
              ]),
      ),
    );
  }
}

// ======================= UPSELL (non-Business) =======================
class _UpsellBody extends StatelessWidget {
  final VoidCallback onSeePlans;
  const _UpsellBody({required this.onSeePlans});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.xxl),
      children: [
        Icon(Icons.storefront_rounded, size: 56, color: scheme.primary),
        const SizedBox(height: Gap.md),
        Text(t.shopBoxUpsellTitle,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.sm),
        Text(t.shopBoxUpsellBody,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
        const SizedBox(height: Gap.lg),
        _bullet(context, Icons.privacy_tip_rounded, t.shopBoxWhatSignals),
        _bullet(context, Icons.notifications_active_rounded,
            t.shopBoxWhatAlerts),
        _bullet(context, Icons.assessment_rounded, t.shopBoxWhatReport),
        const SizedBox(height: Gap.lg),
        Card(
          color: scheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Row(children: [
              Icon(Icons.verified_rounded, size: 20, color: scheme.primary),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(t.shopBoxUpsellPlanNote,
                    style: AType.bodyMedium.copyWith(color: scheme.onSurface, height: 1.4)),
              ),
            ]),
          ),
        ),
        const SizedBox(height: Gap.lg),
        FilledButton.icon(
          onPressed: onSeePlans,
          icon: const Icon(Icons.workspace_premium_rounded),
          label: Text(t.shopBoxSeePlans),
        ),
      ],
    );
  }

  Widget _bullet(BuildContext context, IconData icon, String text) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 18, color: scheme.primary),
        const SizedBox(width: Gap.sm),
        Expanded(
            child: Text(text,
                style: AType.bodyMedium.copyWith(color: scheme.onSurface))),
      ]),
    );
  }
}

// ======================= SHARED =======================
String _fmtDateTime(BuildContext context, dynamic iso) {
  final d = iso == null ? null : DateTime.tryParse(iso.toString());
  if (d == null) return '';
  final lang = Localizations.localeOf(context).languageCode;
  return DateFormat('d MMM, h:mm a', lang).format(d.toLocal());
}

String _confidencePct(BuildContext context, dynamic confidence) {
  final c = confidence is num ? confidence.toDouble() : 0.0;
  final pct = (c * 100).round().clamp(0, 100);
  return '${fmtInt(context, pct)}%';
}

/// Localized label for an event type. Always honest, never the word for theft.
String _eventTypeLabel(AppLocalizations t, String type) {
  switch (type) {
    case 'hand_in_cash_zone':
      return t.shopEvtHandCashZone;
    case 'drawer_open':
      return t.shopEvtDrawerOpen;
    case 'void_spike':
      return t.shopEvtVoidSpike;
    case 'refund_spike':
      return t.shopEvtRefundSpike;
    case 'discount_spike':
      return t.shopEvtDiscountSpike;
    case 'eod_mismatch':
      return t.shopEvtEodMismatch;
    case 'motion':
      return t.shopEvtMotion;
    case 'after_hours':
      return t.shopEvtAfterHours;
    case 'pose_possible':
      return t.shopEvtPosePossible;
    default:
      return type;
  }
}

Widget _sitePickerBanner(BuildContext context, Map<String, dynamic>? site) {
  final t = AppLocalizations.of(context);
  final scheme = Theme.of(context).colorScheme;
  final name = (site?['name'] ?? '').toString().trim();
  return Container(
    width: double.infinity,
    color: scheme.surfaceContainerHighest,
    padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
    child: Row(children: [
      Icon(Icons.store_rounded, size: 16, color: scheme.onSurfaceVariant),
      const SizedBox(width: Gap.sm),
      Expanded(
        child: Text(
          name.isEmpty ? t.shopBoxUnnamedSite : name,
          style: AType.labelMedium.copyWith(fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ]),
  );
}

Widget _noSiteState(BuildContext context) {
  final t = AppLocalizations.of(context);
  return StateMessage(
    icon: Icons.store_mall_directory_rounded,
    title: t.shopBoxNoSiteTitle,
    message: t.shopBoxNoSiteBody,
  );
}

// ======================= SITES TAB =======================
class _SitesTab extends StatelessWidget {
  final bool loading;
  final bool error;
  final List<Map<String, dynamic>> sites;
  final int? selectedId;
  final Future<void> Function() onReload;
  final ValueChanged<int> onSelect;
  final void Function(String) onToast;

  const _SitesTab({
    required this.loading,
    required this.error,
    required this.sites,
    required this.selectedId,
    required this.onReload,
    required this.onSelect,
    required this.onToast,
  });

  Future<void> _createSite(BuildContext context) async {
    final t = AppLocalizations.of(context);
    final result = await showAppSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _SiteForm(),
    );
    if (result == null) return;
    final api = context.read<AppState>().api;
    try {
      final created = await api.shopCreateSite(
          (result['name'] ?? '').toString(),
          (result['retention'] ?? 7) as int);
      onToast(t.shopBoxSiteCreated);
      await onReload();
      if (context.mounted) {
        onSelect(created['id'] as int);
        // Reveal the enrollment token so the owner can enrol their device.
        if (context.mounted) {
          await _showSiteDetail(context, created);
        }
      }
    } catch (_) {
      onToast(t.shopBoxSiteCreateFailed);
    }
  }

  Future<void> _editSite(
      BuildContext context, Map<String, dynamic> site) async {
    final t = AppLocalizations.of(context);
    final result = await showAppSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _SiteForm(
        initialName: (site['name'] ?? '').toString(),
        initialRetention:
            (site['snapshot_retention_days'] ?? 7) as int,
      ),
    );
    if (result == null) return;
    final api = context.read<AppState>().api;
    try {
      final updated = await api.shopUpdateSite(
        site['id'] as int,
        name: (result['name'] ?? '').toString(),
        retentionDays: (result['retention'] ?? 7) as int,
      );
      onToast(t.shopBoxSiteSaved);
      await onReload();
      if (context.mounted) await _showSiteDetail(context, updated);
    } catch (_) {
      onToast(t.shopBoxSiteSaveFailed);
    }
  }

  /// Shows the enrollment token (revealed only on create / patch) + the
  /// paste-into-device explanation + a copy button.
  Future<void> _showSiteDetail(
      BuildContext context, Map<String, dynamic> site) async {
    final token = (site['enrollment_token'] ?? '').toString();
    if (token.isEmpty) return;
    await showAppSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _EnrollmentSheet(
        token: token,
        onToast: onToast,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (loading) return const SkeletonList();
    if (error) {
      return StateMessage(
        icon: Icons.cloud_off_rounded,
        tint: scheme.error,
        title: t.loadFailed,
        message: t.shopBoxSitesLoadError,
        action: FilledButton.tonalIcon(
            onPressed: onReload,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(t.retry)),
      );
    }
    if (sites.isEmpty) {
      return Scaffold(
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _createSite(context),
          icon: const Icon(Icons.add_rounded),
          label: Text(t.shopBoxAddSite),
        ),
        body: StateMessage(
          icon: Icons.storefront_rounded,
          title: t.shopBoxSitesEmptyTitle,
          message: t.shopBoxSitesEmptyBody,
          action: FilledButton.icon(
            onPressed: () => _createSite(context),
            icon: const Icon(Icons.add_rounded),
            label: Text(t.shopBoxAddSite),
          ),
        ),
      );
    }
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _createSite(context),
        icon: const Icon(Icons.add_rounded),
        label: Text(t.shopBoxAddSite),
      ),
      body: RefreshIndicator(
        onRefresh: onReload,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
          children: [
            // Honest, signals-only explainer at the top.
            _privacyNote(context),
            const SizedBox(height: Gap.md),
            _shopModeEntry(context),
            const SizedBox(height: Gap.md),
            for (final s in sites) ...[
              _siteCard(context, t, scheme, s),
              const SizedBox(height: Gap.sm),
            ],
          ],
        ),
      ),
    );
  }

  Widget _shopModeEntry(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: Icon(Icons.phone_android_rounded, color: scheme.primary),
        title: Text(t.shopModeEntryTitle,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(t.shopModeEntrySub, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const ShopBoxModeScreen())),
      ),
    );
  }

  Future<void> _editHours(BuildContext context, Map<String, dynamic> s) async {
    final ok = await showAppSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ShopSiteHoursSheet(site: s),
    );
    if (ok == true) await onReload();
  }

  Widget _privacyNote(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.surfaceContainerHighest,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.privacy_tip_rounded, size: 18, color: scheme.primary),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(t.shopBoxPrivacyNote,
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant,
                    height: 1.4)),
          ),
        ]),
      ),
    );
  }

  Widget _siteCard(BuildContext context, AppLocalizations t, ColorScheme scheme,
      Map<String, dynamic> s) {
    final id = s['id'] as int?;
    final name = (s['name'] ?? '').toString().trim();
    final cameras = (s['cameras'] ?? 0) is int ? s['cameras'] as int : 0;
    final retention =
        (s['snapshot_retention_days'] ?? 0) is int ? s['snapshot_retention_days'] as int : 0;
    final selected = id != null && id == selectedId;
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        side: selected
            ? BorderSide(color: scheme.primary, width: 1.5)
            : BorderSide.none,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: id == null ? null : () => onSelect(id),
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  CircleAvatar(
                    backgroundColor: scheme.primaryContainer,
                    child: Icon(Icons.storefront_rounded,
                        color: scheme.onPrimaryContainer),
                  ),
                  const SizedBox(width: Gap.md),
                  Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(name.isEmpty ? t.shopBoxUnnamedSite : name,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          Text(
                            t.shopBoxSiteSubtitle(
                                fmtInt(context, cameras),
                                fmtInt(context, retention)),
                            style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ]),
                  ),
                  if (selected)
                    Icon(Icons.check_circle_rounded, color: scheme.primary, size: 20),
                ]),
                const SizedBox(height: Gap.xs),
                ShopSeenPill(row: s),
                const SizedBox(height: Gap.xs),
                Wrap(spacing: Gap.xs, children: [
                  TextButton.icon(
                    onPressed: () => _editSite(context, s),
                    icon: const Icon(Icons.vpn_key_rounded, size: 18),
                    label: Text(t.shopBoxEditAndToken),
                  ),
                  TextButton.icon(
                    onPressed: () => _editHours(context, s),
                    icon: const Icon(Icons.schedule_rounded, size: 18),
                    label: Text(t.shopSiteHoursButton),
                  ),
                ]),
              ]),
        ),
      ),
    );
  }
}

// ======================= ENROLLMENT TOKEN SHEET =======================
class _EnrollmentSheet extends StatelessWidget {
  final String token;
  final void Function(String) onToast;
  const _EnrollmentSheet({required this.token, required this.onToast});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xl),
      child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.shopBoxEnrollTitle,
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Gap.sm),
            Text(t.shopBoxEnrollExplain,
                style: TextStyle(
                    color: scheme.onSurfaceVariant, height: 1.4)),
            const SizedBox(height: Gap.lg),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(Gap.md),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: SelectableText(
                token,
                style: AType.titleSmall.copyWith(fontFamily: 'monospace',
                    fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: Gap.md),
            Row(children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: token));
                    onToast(t.shopBoxTokenCopied);
                  },
                  icon: const Icon(Icons.copy_rounded),
                  label: Text(t.copy),
                ),
              ),
              const SizedBox(width: Gap.md),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(t.close),
                ),
              ),
            ]),
          ]),
    );
  }
}

// ======================= SITE FORM =======================
class _SiteForm extends StatefulWidget {
  final String initialName;
  final int initialRetention;
  const _SiteForm({this.initialName = '', this.initialRetention = 7});
  @override
  State<_SiteForm> createState() => _SiteFormState();
}

class _SiteFormState extends State<_SiteForm> {
  late final TextEditingController _name;
  late double _retention;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initialName);
    _retention = widget.initialRetention.clamp(0, 30).toDouble();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final insets = MediaQuery.of(context).viewInsets.bottom;
    final days = _retention.round();
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
      child: SingleChildScrollView(
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.shopBoxSiteFormTitle,
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: Gap.lg),
              TextField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                    labelText: t.shopBoxSiteName,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.lg),
              Text(t.shopBoxRetentionLabel(fmtInt(context, days)),
                  style: Theme.of(context).textTheme.titleSmall),
              Text(
                days == 0
                    ? t.shopBoxRetentionZero
                    : t.shopBoxRetentionHint,
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant),
              ),
              Slider(
                value: _retention,
                min: 0,
                max: 30,
                divisions: 30,
                label: days.toString(),
                onChanged: (v) => setState(() => _retention = v),
              ),
              const SizedBox(height: Gap.sm),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(t.cancel)),
                ),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.pop(context, {
                      'name': _name.text.trim(),
                      'retention': days,
                    }),
                    child: Text(t.save),
                  ),
                ),
              ]),
            ]),
      ),
    );
  }
}

// ======================= CAMERAS TAB =======================
class _CamerasTab extends StatefulWidget {
  final Map<String, dynamic>? site;
  final void Function(String) onToast;
  const _CamerasTab({required this.site, required this.onToast});
  @override
  State<_CamerasTab> createState() => _CamerasTabState();
}

class _CamerasTabState extends State<_CamerasTab> {
  bool _loading = true;
  bool _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)
  List<Map<String, dynamic>> _cameras = [];
  int _included = 0;
  int _used = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_CamerasTab old) {
    super.didUpdateWidget(old);
    if (old.site?['id'] != widget.site?['id']) _load();
  }

  Future<void> _load() async {
    final site = widget.site;
    if (site == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    setState(() {
      _loading = true;
      _error = false;
    });
    final api = context.read<AppState>().api;
    try {
      final r = await api.shopCameras(site['id'] as int);
      _cameras = ((r['cameras'] ?? []) as List).cast<Map<String, dynamic>>();
      _included = (r['included'] ?? 0) is int ? r['included'] as int : 0;
      _used = (r['used'] ?? 0) is int ? r['used'] as int : _cameras.length;
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _addCamera() async {
    final t = AppLocalizations.of(context);
    final site = widget.site;
    if (site == null) return;
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => _NameDialog(
        title: t.shopBoxAddCamera,
        label: t.shopBoxCameraName,
      ),
    );
    if (name == null) return;
    final api = context.read<AppState>().api;
    try {
      final r = await api.shopAddCamera(site['id'] as int, name: name);
      if (r['_ok'] == true) {
        widget.onToast(t.shopBoxCameraAdded);
        await _load();
      } else {
        // 402 camera_cap — show the honest detail + credits needed. No crash.
        if (mounted) await _showCapDialog(r);
      }
    } on ApiException catch (e) {
      widget.onToast(e.message);
    } catch (_) {
      widget.onToast(t.shopBoxCameraAddFailed);
    }
  }

  Future<void> _openSettings(Map<String, dynamic> c) async {
    await showAppSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ShopCameraSettingsSheet(camera: c),
    );
    if (mounted) await _load();
  }

  Future<void> _showCapDialog(Map<String, dynamic> r) async {
    final t = AppLocalizations.of(context);
    final detail = (r['detail'] ?? '').toString();
    final needed = (r['credits_needed'] ?? 0) is int ? r['credits_needed'] as int : 0;
    final balance = (r['balance'] ?? 0) is int ? r['balance'] as int : 0;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        title: Text(t.shopBoxCapTitle),
        content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (detail.isNotEmpty) Text(detail),
              const SizedBox(height: Gap.md),
              Text(t.shopBoxCapNeeded(fmtInt(ctx, needed))),
              Text(t.shopBoxCapBalance(fmtInt(ctx, balance)),
                  style: TextStyle(
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
            ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(t.close)),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const CreditsScreen()));
            },
            child: Text(t.shopBoxCapTopup),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (widget.site == null) return _noSiteState(context);
    if (_loading) return const SkeletonList();
    if (_error) {
      return StateMessage(
        icon: Icons.cloud_off_rounded,
        tint: scheme.error,
        title: t.loadFailed,
        message: honestFailText(t, _failCause, otherwise: t.shopBoxCamerasLoadError),
        action: FilledButton.tonalIcon(
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(t.retry)),
      );
    }
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addCamera,
        icon: const Icon(Icons.add_a_photo_rounded),
        label: Text(t.shopBoxAddCamera),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, 96),
          children: [
            _sitePickerBanner(context, widget.site),
            const SizedBox(height: Gap.md),
            // used / included meter
            Card(
              margin: EdgeInsets.zero,
              color: scheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(Gap.md),
                child: Row(children: [
                  Icon(Icons.videocam_rounded,
                      size: 20, color: scheme.primary),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: Text(
                      t.shopBoxUsedIncluded(
                          fmtInt(context, _used), fmtInt(context, _included)),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: Gap.md),
            if (_cameras.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: Gap.xl),
                child: StateMessage(
                  icon: Icons.videocam_off_rounded,
                  title: t.shopBoxCamerasEmptyTitle,
                  message: t.shopBoxCamerasEmptyBody,
                ),
              )
            else
              for (final c in _cameras) ...[
                _cameraCard(context, t, scheme, c),
                const SizedBox(height: Gap.sm),
              ],
          ],
        ),
      ),
    );
  }

  Widget _cameraCard(BuildContext context, AppLocalizations t,
      ColorScheme scheme, Map<String, dynamic> c) {
    final name = (c['name'] ?? '').toString().trim();
    final enabled = c['enabled'] == true;
    final kind = (c['kind'] ?? '').toString();
    final kindLabel = kind == 'shopbox'
        ? t.shopBoxCameraKindShopbox
        : t.shopBoxCameraKindEdge;
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        onTap: () => _openSettings(c),
        leading: CircleAvatar(
          backgroundColor: scheme.primaryContainer,
          child: Icon(Icons.videocam_rounded,
              color: scheme.onPrimaryContainer),
        ),
        title: Text(name.isEmpty ? t.shopBoxUnnamedCamera : name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('$kindLabel  ·  '
                  '${enabled ? t.shopBoxCameraEnabled : t.shopBoxCameraDisabled}',
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: Gap.xxs),
              ShopSeenPill(row: c),
            ]),
        trailing: Icon(
          enabled ? Icons.tune_rounded : Icons.pause_circle_outline_rounded,
          color: enabled ? scheme.primary : scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

// ======================= NAME DIALOG (small helper) =======================
class _NameDialog extends StatefulWidget {
  final String title;
  final String label;
  const _NameDialog({required this.title, required this.label});
  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  final _c = TextEditingController();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return AlertDialog(
      scrollable: true, // insets: 200% text / keyboard
      title: Text(widget.title),
      content: TextField(
        controller: _c,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        decoration: InputDecoration(
            labelText: widget.label, border: const OutlineInputBorder()),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: Text(t.cancel)),
        FilledButton(
            onPressed: () => Navigator.pop(context, _c.text.trim()),
            child: Text(t.save)),
      ],
    );
  }
}

// ======================= ALERTS TAB =======================
class _AlertsTab extends StatefulWidget {
  final Map<String, dynamic>? site;
  final void Function(String) onToast;
  const _AlertsTab({required this.site, required this.onToast});
  @override
  State<_AlertsTab> createState() => _AlertsTabState();
}

class _AlertsTabState extends State<_AlertsTab> {
  bool _loading = true;
  bool _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)
  List<Map<String, dynamic>> _events = [];
  String? _statusFilter; // null = all

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_AlertsTab old) {
    super.didUpdateWidget(old);
    if (old.site?['id'] != widget.site?['id']) _load();
  }

  Future<void> _load() async {
    final site = widget.site;
    if (site == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    setState(() {
      _loading = true;
      _error = false;
    });
    final api = context.read<AppState>().api;
    try {
      final r = await api.shopEvents(site['id'] as int, status: _statusFilter);
      _events = ((r['events'] ?? []) as List).cast<Map<String, dynamic>>();
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _mark(Map<String, dynamic> e, String status) async {
    final t = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    try {
      await api.shopMarkEvent(e['id'] as int, status);
      widget.onToast(status == 'checked'
          ? t.shopBoxMarkedChecked
          : t.shopBoxMarkedFalseAlarm);
      await _load();
    } catch (_) {
      widget.onToast(t.shopBoxMarkFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (widget.site == null) return _noSiteState(context);
    return Column(children: [
      _sitePickerBanner(context, widget.site),
      // status filter
      Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: Gap.md, vertical: Gap.sm),
        child: Wrap(spacing: Gap.sm, children: [
          _filterChip(t.shopBoxFilterAll, null),
          _filterChip(t.shopBoxFilterOpen, 'open'),
          _filterChip(t.shopBoxFilterChecked, 'checked'),
          _filterChip(t.shopBoxFilterFalseAlarm, 'false_alarm'),
        ]),
      ),
      Expanded(
        child: _loading
            ? const SkeletonList()
            : _error
                ? StateMessage(
                    icon: Icons.cloud_off_rounded,
                    tint: scheme.error,
                    title: t.loadFailed,
                    message: honestFailText(t, _failCause, otherwise: t.shopBoxAlertsLoadError),
                    action: FilledButton.tonalIcon(
                        onPressed: _load,
                        icon: const Icon(Icons.refresh_rounded),
                        label: Text(t.retry)),
                  )
                : RefreshIndicator(
                    onRefresh: _load,
                    child: _events.isEmpty
                        ? ListView(children: [
                            const SizedBox(height: Gap.xxl),
                            StateMessage(
                              icon: Icons.notifications_none_rounded,
                              tint: AssistoTokens.of(context).success,
                              title: t.shopBoxAlertsEmptyTitle,
                              message: t.shopBoxAlertsEmptyBody,
                            ),
                          ])
                        : ListView.separated(
                            padding: const EdgeInsets.fromLTRB(
                                Gap.md, Gap.md, Gap.md, Gap.xxl),
                            itemCount: _events.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: Gap.sm),
                            itemBuilder: (_, i) =>
                                _eventCard(context, t, scheme, _events[i]),
                          ),
                  ),
      ),
    ]);
  }

  Widget _filterChip(String label, String? value) {
    final selected = _statusFilter == value;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) {
        setState(() => _statusFilter = value);
        _load();
      },
    );
  }

  Widget _eventCard(BuildContext context, AppLocalizations t,
      ColorScheme scheme, Map<String, dynamic> e) {
    final type = (e['type'] ?? '').toString();
    final status = (e['status'] ?? 'open').toString();
    final possible = e['possible'] == true;
    final snapshotUrl = (e['snapshot_url'] ?? '').toString();
    final posMatched = e['pos_matched'] == true;
    final confidence = _confidencePct(context, e['confidence']);
    final isOpen = status == 'open';

    Color statusColor;
    String statusLabel;
    switch (status) {
      case 'checked':
        statusColor = AssistoTokens.of(context).success;
        statusLabel = t.shopBoxStatusChecked;
        break;
      case 'false_alarm':
        statusColor = scheme.onSurfaceVariant;
        statusLabel = t.shopBoxStatusFalseAlarm;
        break;
      default:
        statusColor = AssistoTokens.of(context).warning;
        statusLabel = t.shopBoxStatusOpen;
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.photo_camera_rounded,
                    color: scheme.primary, size: 22),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // ALWAYS "please check camera X" wording, never theft.
                        Text((e['camera'] == null ? t.shopQaPleaseCheck : t.shopBoxAlertHeadline),
                            style: AType.titleSmall.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(height: Gap.xxs),
                        Text(_eventTypeLabel(t, type),
                            style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
                      ]),
                ),
                _pill(statusLabel, statusColor),
              ]),
              const SizedBox(height: Gap.sm),
              Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
                _pill(t.shopBoxConfidence(confidence), scheme.primary),
                if (possible) _pill(t.shopBoxPossible, AssistoTokens.of(context).warning),
                if (posMatched) _pill(t.shopBoxPosMatched, scheme.tertiary),
              ]),
              const SizedBox(height: Gap.xs),
              Text(_fmtDateTime(context, e['created']),
                  style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
              if (snapshotUrl.isNotEmpty) ...[
                const SizedBox(height: Gap.sm),
                ClipRRect(
                  borderRadius: BorderRadius.circular(Radii.sm),
                  child: Image.network(
                    snapshotUrl,
                    height: 160,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      height: 160,
                      color: scheme.surfaceContainerHighest,
                      alignment: Alignment.center,
                      child: Icon(Icons.image_not_supported_rounded,
                          color: scheme.onSurfaceVariant),
                    ),
                    loadingBuilder: (c, child, p) => p == null
                        ? child
                        : Container(
                            height: 160,
                            color: scheme.surfaceContainerHighest,
                            alignment: Alignment.center,
                            child: const CircularProgressIndicator(),
                          ),
                  ),
                ),
              ],
              if (isOpen) ...[
                const SizedBox(height: Gap.md),
                Builder(builder: (context) {
                  final checked = FilledButton.tonalIcon(
                    onPressed: () => _mark(e, 'checked'),
                    icon: const Icon(Icons.check_rounded, size: 18),
                    label: Text(t.shopBoxMarkChecked),
                  );
                  final falseAlarm = OutlinedButton.icon(
                    onPressed: () => _mark(e, 'false_alarm'),
                    icon: const Icon(Icons.not_interested_rounded, size: 18),
                    label: Text(t.shopBoxMarkFalseAlarm),
                  );
                  // large font: stack full-width so labels stay on one line
                  if (MediaQuery.textScalerOf(context).scale(10) > 11.5) {
                    return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [checked, const SizedBox(height: Gap.sm), falseAlarm]);
                  }
                  return Row(children: [
                    Expanded(child: checked),
                    const SizedBox(width: Gap.sm),
                    Expanded(child: falseAlarm),
                  ]);
                }),
              ],
            ]),
      ),
    );
  }

  Widget _pill(String text, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xs),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(Radii.pill),
        ),
        child: Text(text,
            style: AType.labelMedium.copyWith(color: c, fontWeight: FontWeight.w600)),
      );
}

// ======================= REPORT TAB =======================
class _ReportTab extends StatefulWidget {
  final Map<String, dynamic>? site;
  const _ReportTab({required this.site});
  @override
  State<_ReportTab> createState() => _ReportTabState();
}

class _ReportTabState extends State<_ReportTab> {
  bool _loading = true;
  bool _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)
  Map<String, dynamic> _summary = {};
  int _days = 7;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_ReportTab old) {
    super.didUpdateWidget(old);
    if (old.site?['id'] != widget.site?['id']) _load();
  }

  Future<void> _load() async {
    final site = widget.site;
    if (site == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    setState(() {
      _loading = true;
      _error = false;
    });
    final api = context.read<AppState>().api;
    try {
      _summary = await api.shopSummary(site['id'] as int, days: _days);
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  int _int(dynamic v) => v is int ? v : (v is num ? v.toInt() : 0);

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (widget.site == null) return _noSiteState(context);
    if (_loading) return const SkeletonList();
    if (_error) {
      return StateMessage(
        icon: Icons.cloud_off_rounded,
        tint: scheme.error,
        title: t.loadFailed,
        message: honestFailText(t, _failCause, otherwise: t.shopBoxReportLoadError),
        action: FilledButton.tonalIcon(
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(t.retry)),
      );
    }

    final total = _int(_summary['total_events']);
    final open = _int(_summary['open']);
    final falseAlarms = _int(_summary['false_alarms']);
    final afterHours = _int(_summary['after_hours']);
    final cameraOnly = _summary['camera_only'] == true;
    final exceptions =
        (_summary['exceptions'] ?? {}) is Map ? _summary['exceptions'] as Map : {};
    final byType =
        (_summary['by_type'] ?? {}) is Map ? _summary['by_type'] as Map : {};

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.xxl),
        children: [
          _sitePickerBanner(context, widget.site),
          const SizedBox(height: Gap.md),
          // a2-cctv: end-of-day cash vs Assisto POS sales
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: Icon(Icons.point_of_sale_rounded, color: scheme.primary),
              title: Text(t.shopEodTitle,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(t.shopEodEntrySub, maxLines: 2,
                  overflow: TextOverflow.ellipsis),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ShopEodScreen(
                      siteId: widget.site!['id'] as int,
                      siteName: (widget.site!['name'] ?? '').toString()))),
            ),
          ),
          const SizedBox(height: Gap.md),
          // days selector
          Wrap(spacing: Gap.sm, children: [
            for (final d in [1, 7, 30, 90])
              ChoiceChip(
                label: Text(d == 1 ? t.shopQaOneDay : t.shopBoxReportDays(fmtInt(context, d))),
                selected: _days == d,
                onSelected: (_) {
                  setState(() => _days = d);
                  _load();
                },
              ),
          ]),
          const SizedBox(height: Gap.md),
          // headline counts
          Row(children: [
            Expanded(
                child: _stat(context, t.shopBoxStatTotal,
                    fmtInt(context, total), scheme.primary)),
            const SizedBox(width: Gap.sm),
            Expanded(
                child: _stat(context, t.shopBoxStatOpen,
                    fmtInt(context, open), AssistoTokens.of(context).warning)),
          ]),
          const SizedBox(height: Gap.sm),
          Row(children: [
            Expanded(
                child: _stat(context, t.shopBoxStatFalseAlarms,
                    fmtInt(context, falseAlarms), scheme.onSurfaceVariant)),
            const SizedBox(width: Gap.sm),
            Expanded(
                child: _stat(context, t.shopBoxStatAfterHours,
                    fmtInt(context, afterHours), scheme.tertiary)),
          ]),
          const SizedBox(height: Gap.lg),

          // Exception report (POS side).
          Text(t.shopBoxExceptionTitle,
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Gap.xs),
          if (cameraOnly)
            Card(
              margin: EdgeInsets.zero,
              color: scheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(Gap.md),
                child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline_rounded,
                          size: 18, color: scheme.onSurfaceVariant),
                      const SizedBox(width: Gap.sm),
                      Expanded(
                        child: Text(t.shopBoxCameraOnlyNote,
                            style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant,
                                height: 1.4)),
                      ),
                    ]),
              ),
            ),
          const SizedBox(height: Gap.sm),
          _exceptionRow(context, t, t.shopBoxExcVoids,
              _int(exceptions['voids']), cameraOnly),
          _exceptionRow(context, t, t.shopBoxExcRefunds,
              _int(exceptions['refunds']), cameraOnly),
          _exceptionRow(context, t, t.shopBoxExcDiscounts,
              _int(exceptions['discounts']), cameraOnly),
          _exceptionRow(context, t, t.shopBoxExcDrawerOpens,
              _int(exceptions['drawer_opens']), cameraOnly),

          if (byType.isNotEmpty) ...[
            const SizedBox(height: Gap.lg),
            Text(t.shopBoxByTypeTitle,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Gap.sm),
            for (final entry in byType.entries)
              _exceptionRow(
                context,
                t,
                _eventTypeLabel(t, entry.key.toString()),
                _int(entry.value),
                false,
              ),
          ],
        ],
      ),
    );
  }

  Widget _stat(
      BuildContext context, String label, String value, Color color) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value,
              style: AType.headlineSmall.copyWith(fontWeight: FontWeight.w800, color: color)),
          const SizedBox(height: Gap.xxs),
          Text(label,
              style:
                  AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
        ]),
      ),
    );
  }

  Widget _exceptionRow(BuildContext context, AppLocalizations t, String label,
      int count, bool greyed) {
    final scheme = Theme.of(context).colorScheme;
    final color = greyed ? scheme.onSurfaceVariant : scheme.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Row(children: [
        Expanded(
          child: Text(label,
              style: TextStyle(
                  color: color,
                  fontStyle:
                      greyed ? FontStyle.italic : FontStyle.normal)),
        ),
        Text(
          greyed ? t.shopBoxNoPos : fmtInt(context, count),
          style: TextStyle(
              fontWeight: FontWeight.w700,
              color: greyed ? scheme.onSurfaceVariant : scheme.primary),
        ),
      ]),
    );
  }
}
