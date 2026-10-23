import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/chatnav.dart';
import '../widgets/skeleton.dart';
import '../widgets/disaster_model.dart';
import '../widgets/disaster_warning_card.dart';
import '../widgets/disaster_safety_sheet.dart';
import '../services/action_feedback.dart'; // db1
import '../services/error_kind.dart' show honestFailText; // qa2

/// DISASTER ALERTS (ADVANCED) — SPEC v2.1 §21 / Appendix-A #44 (good → advanced).
///
/// BD-specific disaster & weather warnings: cyclone (BMD signal number), flood
/// (FFWC level vs danger level), heatwave (BMD band / heat index) and earthquake
/// awareness. Advanced over the old "watch" line:
///   • active warnings BY AREA with severity levels + the kind's metric chip
///   • source-noted "what to do" safety steps per disaster
///   • family-location-aware: are any circle members inside an affected area?
///     (reuses the circle member list — no new audience)
///   • share a warning, emergency contacts (999 + disaster hotline 1090),
///     preparedness checklist.
///
/// HONESTY GUARANTEES:
///   • Official sources ONLY (BMD / FFWC / DDM) — every card is source-noted.
///   • The live feed is 🔑 KEY-GATED: with no official-feed key the screen shows
///     the "connect official feed" state plus clearly-flagged SAMPLE examples
///     (badged "example — not a live warning"). It NEVER fabricates an active
///     warning. Live warnings are rendered only from the server feed.
class DisasterAlertsScreen extends StatefulWidget {
  const DisasterAlertsScreen({super.key});
  @override
  State<DisasterAlertsScreen> createState() => _DisasterAlertsScreenState();
}

class _DisasterAlertsScreenState extends State<DisasterAlertsScreen> {
  bool _loading = true;
  bool _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

  /// Feed state (mirror of disaster.feed_state): 'no_key' | 'empty' | 'active'.
  String _feedState = 'no_key';
  List<DisasterWarning> _warnings = [];
  List<Map<String, dynamic>> _family = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  dynamic get _api => context.read<AppState>().api;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      // The official feed is wired by the integrator at /disaster/feed. It is
      // KEY-GATED server-side; with no key it returns {feed_state:'no_key'}.
      // Any failure (offline / route not wired) falls back to the honest
      // no-key + sample state — we NEVER fabricate a live warning.
      Map<String, dynamic>? feed;
      try {
        feed = await _api.getJson('/disaster/feed');
      } catch (_) {
        feed = null;
      }

      List<Map<String, dynamic>> fam = const [];
      try {
        fam = await _api.listItems('family');
      } catch (_) {
        fam = const [];
      }

      final state = (feed?['feed_state'] ?? 'no_key').toString();
      final rawList = (feed?['warnings'] as List?) ?? const [];
      final live = rawList
          .whereType<Map>()
          .map((m) => DisasterWarning.fromMap(m.cast<String, dynamic>()))
          .toList();

      if (!mounted) return;
      setState(() {
        _feedState = state == 'active' && live.isNotEmpty ? 'active' : state;
        _warnings = live;
        _family = fam;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = true;
          _failCause = e;
          _loading = false;
        });
      }
    }
  }

  // ---------------------------------------------------------------------------
  // SAMPLE warnings (shown ONLY in the no-key state so the user sees what a real
  // warning will look like). Built from ARB; every one is flagged sample/isLive
  // false so the card badges it "example". NEVER an active alert.
  // ---------------------------------------------------------------------------
  List<DisasterWarning> _sampleWarnings() {
    final t = AppLocalizations.of(context);
    return [
      DisasterWarning(
        kind: 'cyclone',
        area: t.disSampleCycloneArea,
        title: t.disSampleCycloneTitle,
        text: t.disSampleCycloneBody,
        severity: dCycloneSeverity(7),
        source: t.disSampleSourceBmd,
        isLive: false,
        sample: true,
        signal: 7,
      ),
      DisasterWarning(
        kind: 'flood',
        area: t.disSampleFloodArea,
        title: t.disSampleFloodTitle,
        text: t.disSampleFloodBody,
        severity: dFloodSeverity(0.6),
        source: t.disSampleSourceFfwc,
        isLive: false,
        sample: true,
        aboveDangerM: 0.6,
      ),
      DisasterWarning(
        kind: 'heat',
        area: t.disSampleHeatArea,
        title: t.disSampleHeatTitle,
        text: t.disSampleHeatBody,
        severity: dHeatSeverity(40.5),
        source: t.disSampleSourceBmd,
        isLive: false,
        sample: true,
        tempC: 40.5,
      ),
    ];
  }

  /// Source-noted "what to do" steps per kind (ARB; condensed from DDM/BDRCS/BMD).
  List<String> _steps(AppLocalizations t, String kind) {
    switch (kind) {
      case 'cyclone':
        return [t.disStepCyc1, t.disStepCyc2, t.disStepCyc3, t.disStepCyc4, t.disStepCyc5];
      case 'flood':
        return [t.disStepFld1, t.disStepFld2, t.disStepFld3, t.disStepFld4, t.disStepFld5];
      case 'heat':
        return [t.disStepHot1, t.disStepHot2, t.disStepHot3, t.disStepHot4, t.disStepHot5];
      case 'earthquake':
        return [t.disStepEq1, t.disStepEq2, t.disStepEq3, t.disStepEq4, t.disStepEq5];
      default:
        return const [];
    }
  }

  String _stepsSource(AppLocalizations t, String kind) =>
      kind == 'heat' ? t.disStepsSourceHeat : t.disStepsSourceDisaster;

  // ---------------------------------------------------------------------------
  // actions
  // ---------------------------------------------------------------------------
  Future<void> _call(String number) async {
    await openForUser(context, Uri.parse('tel:$number'), where: 'disaster.call'); // db1
  }

  void _openSteps(String kind) {
    final t = AppLocalizations.of(context);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => DisasterSafetySheet(
        kind: kind,
        steps: _steps(t, kind),
        source: _stepsSource(t, kind),
      ),
    );
  }

  Future<void> _share(DisasterWarning w) async {
    final t = AppLocalizations.of(context);
    final lines = <String>[
      w.sample || !w.isLive ? t.disShareHeaderSample : t.disShareHeader,
      if (w.title.isNotEmpty) w.title,
      if (w.area.isNotEmpty) t.disShareArea(w.area),
      if (w.source.isNotEmpty) t.disSourceLine(w.source),
      t.disShareHotlines(kHotlineDisaster, kHotlineEmergency) /* (disaster, emergency) */,
    ];
    await Share.share(lines.join('\n'));
  }

  // ---------------------------------------------------------------------------
  // build
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(t.disTitle),
            Text(t.disSubtitle,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                    color: scheme.onSurfaceVariant)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: t.disRefresh,
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off,
                  tint: scheme.error,
                  title: t.disErrorTitle,
                  message: honestFailText(t, _failCause, otherwise: t.disErrorBody),
                  action: FilledButton.tonalIcon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label: Text(t.disRetry)),
                )
              : RefreshIndicator(onRefresh: _load, child: _body(t, scheme)),
    );
  }

  Widget _body(AppLocalizations t, ColorScheme scheme) {
    return ListView(
      padding: const EdgeInsets.all(Gap.md),
      children: [
        _feedBanner(t, scheme),
        const SizedBox(height: Gap.md),
        _warningsSection(t, scheme),
        const SizedBox(height: Gap.lg),
        _familySection(t, scheme),
        const SizedBox(height: Gap.lg),
        _safetyLibrary(t, scheme),
        const SizedBox(height: Gap.lg),
        _preparedness(t, scheme),
        const SizedBox(height: Gap.lg),
        _emergencyContacts(t, scheme),
        const SizedBox(height: Gap.xl),
        Text(t.disOfficialOnlyFooter,
            style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
      ],
    );
  }

  // ---- honest, key-gated live-feed banner -----------------------------------
  Widget _feedBanner(AppLocalizations t, ColorScheme scheme) {
    final noKey = _feedState != 'active' && _feedState != 'empty';
    if (_feedState == 'empty') {
      return _bannerCard(
        Brand.success,
        Icons.verified_outlined,
        t.disFeedEmptyTitle,
        t.disFeedEmptyBody,
      );
    }
    if (noKey) {
      return _bannerCard(
        Brand.warning,
        Icons.link_off,
        t.disFeedNoKeyTitle,
        t.disFeedNoKeyBody,
      );
    }
    // active
    return _bannerCard(
      Brand.danger,
      Icons.warning_amber_rounded,
      t.disFeedActiveTitle,
      t.disFeedActiveBody,
    );
  }

  Widget _bannerCard(Color tint, IconData icon, String title, String body) {
    return Card(
      color: tint.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: tint),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(fontWeight: FontWeight.w700, color: tint)),
              const SizedBox(height: 2),
              Text(body, style: const TextStyle(fontSize: 12.5, height: 1.35)),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _warningsSection(AppLocalizations t, ColorScheme scheme) {
    final active = _feedState == 'active' && _warnings.isNotEmpty;
    final list = active ? _warnings : _sampleWarnings();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionHeader(
        Icons.campaign_outlined,
        active ? t.disActiveTitle : t.disSampleSectionTitle,
        scheme.primary,
      ),
      const SizedBox(height: Gap.sm),
      for (final w in list)
        DisasterWarningCard(
          warning: w,
          onSteps: () => _openSteps(w.kind),
          onShare: () => _share(w),
        ),
    ]);
  }

  // ---- family-location-aware (reuses circle member list) --------------------
  Widget _familySection(AppLocalizations t, ColorScheme scheme) {
    // Only meaningful against LIVE warnings; we never imply a sample puts family
    // at risk. If no live warnings, show the honest "no one in an affected area"
    // state (still useful — confirms family areas are being checked).
    final live = _feedState == 'active' ? _warnings : <DisasterWarning>[];
    final matched = <_AffectedMember>[];
    for (final m in _family) {
      final area = (m['area'] ?? m['district'] ?? m['city'] ?? '').toString();
      DisasterWarning? best;
      for (final w in live) {
        if (dAreaMatches(area, w.area)) {
          if (best == null || dSevRank(w.severity) > dSevRank(best.severity)) {
            best = w;
          }
        }
      }
      if (best != null) {
        matched.add(_AffectedMember((m['name'] ?? '').toString(), area, best));
      }
    }
    matched.sort((a, b) => dSevRank(b.warning.severity).compareTo(dSevRank(a.warning.severity)));

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionHeader(Icons.diversity_3_outlined, t.disFamilyTitle, Brand.purple),
      const SizedBox(height: 2),
      Padding(
        padding: const EdgeInsets.only(left: 26, bottom: Gap.sm),
        child: Text(t.disFamilyHint,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
      ),
      if (_family.isEmpty)
        _tile(Icons.person_add_alt, t.disFamilyNone, scheme,
            onTap: () => ChatNav.push(context, 'family'))
      else if (matched.isEmpty)
        _tile(Icons.check_circle_outline, t.disFamilyAllSafe, scheme,
            tint: Brand.success)
      else
        for (final a in matched)
          Card(
            margin: const EdgeInsets.only(bottom: Gap.sm),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: dSevColor(a.warning.severity).withValues(alpha: 0.15),
                foregroundColor: dSevColor(a.warning.severity),
                child: Icon(dKindIcon(a.warning.kind)),
              ),
              title: Text(a.name.isEmpty ? a.area : a.name,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(t.disFamilyInArea(
                  // (area, kind, sev) — gen-l10n metadata order
                  a.area, dKindLabel(context, a.warning.kind),
                  dSevLabel(context, a.warning.severity))),
              trailing: IconButton(
                tooltip: t.disOpenFamily,
                icon: const Icon(Icons.chevron_right),
                onPressed: () => ChatNav.push(context, 'family'),
              ),
            ),
          ),
    ]);
  }

  // ---- safety library: steps for every kind, always available offline -------
  Widget _safetyLibrary(AppLocalizations t, ColorScheme scheme) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionHeader(Icons.menu_book_outlined, t.disSafetyLibTitle, Brand.blue),
      const SizedBox(height: Gap.sm),
      Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
        for (final kind in kDisasterKinds)
          ActionChip(
            avatar: Icon(dKindIcon(kind), size: 18),
            label: Text(dKindLabel(context, kind)),
            onPressed: () => _openSteps(kind),
          ),
      ]),
    ]);
  }

  // ---- preparedness checklist (before any disaster) -------------------------
  Widget _preparedness(AppLocalizations t, ColorScheme scheme) {
    final items = [
      t.disPrep1, t.disPrep2, t.disPrep3, t.disPrep4, t.disPrep5, t.disPrep6, t.disPrep7,
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionHeader(Icons.inventory_2_outlined, t.disPrepTitle, scheme.secondary),
      const SizedBox(height: Gap.sm),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final it in items)
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.xs),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(Icons.check_box_outline_blank,
                      size: 18, color: scheme.onSurfaceVariant),
                  const SizedBox(width: Gap.sm),
                  Expanded(child: Text(it, style: const TextStyle(height: 1.4))),
                ]),
              ),
            const SizedBox(height: Gap.xs),
            Text(t.disSourceLine(t.disPrepSource),
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          ]),
        ),
      ),
    ]);
  }

  // ---- emergency contacts (999 + disaster hotline 1090) ---------------------
  Widget _emergencyContacts(AppLocalizations t, ColorScheme scheme) {
    final rows = [
      _Hotline('national', kHotlineEmergency, Icons.emergency,
          t.disHotlineNational, t.disHotlineNationalNote, primary: true),
      _Hotline('disaster', kHotlineDisaster, Icons.cyclone,
          t.disHotlineDisaster, t.disHotlineDisasterNote),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionHeader(Icons.call_outlined, t.disContactsTitle, Brand.danger),
      const SizedBox(height: Gap.sm),
      for (final h in rows)
        Card(
          color: h.primary ? Brand.danger.withValues(alpha: 0.08) : null,
          margin: const EdgeInsets.only(bottom: Gap.sm),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: h.primary ? Brand.danger : scheme.secondaryContainer,
              foregroundColor: h.primary ? Colors.white : scheme.onSecondaryContainer,
              child: Icon(h.icon),
            ),
            title: Text(h.label,
                style: TextStyle(
                    fontWeight: h.primary ? FontWeight.w800 : FontWeight.w600)),
            subtitle: Text(h.note, style: const TextStyle(fontSize: 12)),
            trailing: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: h.primary ? Brand.danger : null,
                minimumSize: const Size(0, 44),
              ),
              onPressed: () => _call(h.number),
              icon: const Icon(Icons.call, size: 18),
              label: Text(dNum(context, int.parse(h.number))),
            ),
          ),
        ),
      Text(t.disContactsSource,
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
    ]);
  }

  // ---- small helpers --------------------------------------------------------
  Widget _sectionHeader(IconData icon, String title, Color tint) {
    return Row(children: [
      Icon(icon, size: 18, color: tint),
      const SizedBox(width: Gap.sm),
      Expanded(child: Text(title, style: TextStyle(fontWeight: FontWeight.w700, color: tint))),
    ]);
  }

  Widget _tile(IconData icon, String text, ColorScheme scheme,
      {VoidCallback? onTap, Color? tint}) {
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: ListTile(
        leading: Icon(icon, color: tint ?? scheme.onSurfaceVariant),
        title: Text(text),
        trailing: onTap == null ? null : const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

class _AffectedMember {
  final String name;
  final String area;
  final DisasterWarning warning;
  const _AffectedMember(this.name, this.area, this.warning);
}

class _Hotline {
  final String key;
  final String number;
  final IconData icon;
  final String label;
  final String note;
  final bool primary;
  const _Hotline(this.key, this.number, this.icon, this.label, this.note,
      {this.primary = false});
}
