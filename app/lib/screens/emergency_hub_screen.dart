import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../feature_flags.dart';
import '../l10n/app_localizations.dart';
import '../services/action_feedback.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart' show withNavBarInset;
import '../widgets/chatnav.dart';
import '../widgets/emergency_sos_panel.dart';
import '../widgets/fam_card_section.dart' show FamCardScreen, FamCardStore;
import 'emergency_screen.dart';
import 'journey_fake_call_screen.dart';
import 'nearby_screen.dart';

/// emhub (owner order 2 Nov 17:40) — ONE Emergency hub (Bangla title from the ARB), like Safe
/// Journey is a hub. Route `emergency_hub` (flag `emergency`).
///
/// Order = urgency: SOS send (the same sosat hold-to-send panel, biggest, at
/// the top) -> 999 (dialer only, never auto-dial) -> nearest hospital / police
/// station -> family card (offline) -> blood needed -> missing person ->
/// crisis help (owner-verified numbers only) -> lost / stolen phone -> fake
/// call. Every feature also stays on its own in All services.
///
/// HARD rules kept here:
/// * the SOS button is on the FIRST frame — nothing awaits the network or the
///   phone store before it is shown (the old Emergency screen showed a
///   spinner until GET /emergency answered); contacts / countdown fill in
///   when the phone store answers and the panel reads them only when it fires;
/// * no ads: `emergency_hub` is in AdPlacements.neverScreens and carries the
///   blocked token "emergency"; this screen places no ad widget;
/// * a flag-off feature is not shown at all (never a dead tile);
/// * no image assets (2 GB phones) — icons only.
class EmergencyHubScreen extends StatefulWidget {
  const EmergencyHubScreen({
    super.key,
    this.dial,
    this.sendSos,
    this.locate,
    this.ladderLoad,
    this.famCard,
  });

  /// Route name (ChatNav / feature_registry / ad never-list).
  static const route = 'emergency_hub';

  /// Test seam: open the dialer for [number] (default: tel: via the system
  /// dialer — the user presses call; Assisto never calls by itself).
  final Future<void> Function(BuildContext context, String number)? dial;

  /// Test seams passed straight to the SOS panel.
  final Future<Map<String, dynamic>> Function(double? lat, double? lng)? sendSos;
  final Future<(double, double)?> Function()? locate;
  final Future<Map<String, dynamic>> Function()? ladderLoad;

  /// Test seam: the family card as saved on this phone.
  final Future<Map<String, dynamic>> Function()? famCard;

  /// The offline copy of the owner-verified crisis numbers (per language).
  static String crisisCacheKey(String lang) => 'emh_crisis_v1_$lang';

  /// The same cache the Emergency card screen keeps (contacts for SOS steps).
  static const emergencyCardCacheKey = 'emergency_card_cache';

  @override
  State<EmergencyHubScreen> createState() => _EmergencyHubScreenState();
}

/// A dialable number: digits only, optional leading +, 3–15 long.
final _numRx = RegExp(r'^\+?[0-9]{3,15}$');

class _EmergencyHubScreenState extends State<EmergencyHubScreen> {
  List<Map<String, dynamic>> _contacts = const [];
  int _countdown = 5;
  Map<String, dynamic> _fam = const {};
  List<Map<String, String>> _crisis = const [];
  bool _crisisLoaded = false;
  String? _lang;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final lang = AppLocalizations.of(context).localeName.startsWith('bn') ? 'bn' : 'en';
    if (lang != _lang) {
      _lang = lang;
      // Fire and forget: the SOS panel is already on screen.
      _loadLocal();
      _refreshCrisis();
    }
  }

  // ---------------------------------------------------------------- local
  Future<void> _loadLocal() async {
    final cd = int.tryParse(await Settings.getString('safety_sos_cd') ?? '');
    final contacts = <Map<String, dynamic>>[];
    final seen = <String>{};
    void add(Object? name, Object? phone, [Object? relation]) {
      final p = '${phone ?? ''}'.trim();
      if (p.isEmpty || !seen.add(p)) return;
      contacts.add({'name': '${name ?? ''}', 'phone': p, 'relation': '${relation ?? ''}'});
    }

    try {
      final raw = await Settings.getString(EmergencyHubScreen.emergencyCardCacheKey);
      if (raw != null && raw.isNotEmpty) {
        final d = jsonDecode(raw);
        if (d is Map) {
          for (final c in (d['contacts'] as List? ?? const [])) {
            if (c is Map) add(c['name'], c['phone'], c['relation']);
          }
        }
      }
    } catch (_) {/* best-effort: a broken cache never blocks SOS */}
    Map<String, dynamic> fam = const {};
    try {
      fam = await (widget.famCard ?? FamCardStore.load)();
      for (final c in (fam['contacts'] as List? ?? const [])) {
        if (c is Map) add(c['name'], c['phone']);
      }
    } catch (_) {/* best-effort: the card tile just shows its empty line */}
    if (!mounted) return;
    setState(() {
      if (cd != null && cd >= 0) _countdown = cd;
      _contacts = contacts;
      _fam = fam;
    });
  }

  // --------------------------------------------------------------- crisis
  List<Map<String, String>> _parseCrisis(Object? list) {
    final out = <Map<String, String>>[];
    if (list is! List) return out;
    for (final e in list) {
      if (e is! Map) continue;
      final n = '${e['number'] ?? ''}'.trim();
      // Only a real dialable number the SERVER returned (the server sends
      // owner-verified entries only). Nothing is ever invented here.
      if (!_numRx.hasMatch(n)) continue;
      out.add({
        'key': '${e['key'] ?? ''}',
        'number': n,
        'label': '${e['label'] ?? ''}',
      });
    }
    return out;
  }

  Future<void> _refreshCrisis() async {
    final lang = _lang ?? 'en';
    final key = EmergencyHubScreen.crisisCacheKey(lang);
    try {
      final raw = await Settings.getString(key);
      if (raw != null && raw.isNotEmpty) {
        final cached = _parseCrisis(jsonDecode(raw));
        if (mounted && cached.isNotEmpty) {
          setState(() {
            _crisis = cached;
            _crisisLoaded = true;
          });
        }
      }
    } catch (_) {/* best-effort: corrupt cache ignored, the server copy comes next */}
    if (!mounted) return;
    final ApiClient api;
    try {
      api = context.read<AppState>().api;
    } catch (_) {
      setState(() => _crisisLoaded = true); // no app state (preview): 999 alone
      return;
    }
    try {
      final r = await api.getJson('/crisis/helplines');
      final fresh = _parseCrisis(r['helplines']);
      if (fresh.isNotEmpty) {
        await Settings.setString(key, jsonEncode(fresh));
      }
      if (!mounted) return;
      setState(() {
        if (fresh.isNotEmpty) _crisis = fresh;
        _crisisLoaded = true;
      });
    } catch (_) {
      // best-effort: offline keeps the phone copy (or the 999-only fallback)
      if (mounted) setState(() => _crisisLoaded = true);
    }
  }

  // ---------------------------------------------------------------- actions
  Future<void> _dial(String number) async {
    if (widget.dial != null) return widget.dial!(context, number);
    // tel: opens the DIALER with the number filled in — the user presses call.
    await openForUser(context, Uri(scheme: 'tel', path: number), where: 'emergency_hub.dial');
  }

  Future<void> _push(Widget w, String name) => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => w, settings: RouteSettings(name: name)));

  Future<void> _addNumbers() async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => const EmergencyScreen(startAddContact: true),
        settings: const RouteSettings(name: 'emergency')));
    if (mounted) await _loadLocal();
  }

  Future<void> _fakeCall() async {
    final t = AppLocalizations.of(context);
    final ctrl = TextEditingController(text: t.fakeCallDefaultName);
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // 200% text / keyboard
        title: Text(t.fakeCallSetup),
        content: TextField(
            controller: ctrl,
            decoration: InputDecoration(labelText: t.fakeCallCaller)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(
              key: const ValueKey('emh-fake-go'),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.fakeCallStart)),
        ],
      ),
    );
    // (not disposed here: the dialog's closing animation still reads it)
    final name = ctrl.text.trim();
    if (go == true && mounted) {
      await _push(
          JourneyFakeCallScreen(
              caller: name.isEmpty ? t.fakeCallDefaultName : name, delaySeconds: 15),
          'fake_call');
    }
  }

  // ---------------------------------------------------------------- helpers
  String _digits(String latin) {
    if (_lang != 'bn') return latin;
    final b = StringBuffer();
    for (final ch in latin.runes) {
      b.writeCharCode(ch >= 0x30 && ch <= 0x39 ? 0x09E6 + (ch - 0x30) : ch);
    }
    return b.toString();
  }

  String _famSubtitle(AppLocalizations t) {
    final blood = '${_fam['blood'] ?? ''}'.trim();
    final n = (_fam['contacts'] as List? ?? const [])
        .whereType<Map>()
        .where((c) => '${c['phone'] ?? ''}'.trim().isNotEmpty)
        .length;
    if (blood.isEmpty && n == 0) return t.emhFamCardEmpty;
    return [
      if (blood.isNotEmpty) t.emhFamBlood(blood),
      if (n > 0) t.emhFamNumbers(_digits('$n')),
      t.emhOfflineOk,
    ].join(' · ');
  }

  // ------------------------------------------------------------------- build
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final ff = FeatureFlags.instance;
    final scheme = Theme.of(context).colorScheme;
    final nearbyOn = ff.isOn('nearby');
    final tiles = <Widget>[
      if (nearbyOn) ...[
        _HubTile(
          id: 'hospital',
          icon: Icons.local_hospital_rounded,
          title: t.emhHospital,
          subtitle: t.emhNearbySub,
          onTap: () => _push(const NearbyScreen(placeType: 'hospital'), 'nearby'),
        ),
        _HubTile(
          id: 'police',
          icon: Icons.local_police_rounded,
          title: t.emhPolice,
          subtitle: t.emhNearbySub,
          onTap: () => _push(const NearbyScreen(placeType: 'police'), 'nearby'),
        ),
      ],
      _HubTile(
        id: 'famcard',
        icon: Icons.badge_rounded,
        title: t.emhFamCard,
        subtitle: _famSubtitle(t),
        onTap: () async {
          await _push(const FamCardScreen(), 'fam_card');
          if (mounted) await _loadLocal(); // show the card's new blood group / numbers
        },
      ),
      if (ff.routeAllowed('blood_panel'))
        _HubTile(
          id: 'blood',
          icon: Icons.bloodtype_rounded,
          title: t.emhBlood,
          subtitle: t.emhBloodSub,
          onTap: () => ChatNav.push(context, 'blood_panel'),
        ),
      if (ff.routeAllowed('missing_alert'))
        _HubTile(
          id: 'missing',
          icon: Icons.person_search_rounded,
          title: t.emhMissing,
          subtitle: t.emhMissingSub,
          onTap: () => ChatNav.push(context, 'missing_alert'),
        ),
    ];
    final later = <Widget>[
      if (ff.routeAllowed('lost_stolen'))
        _HubTile(
          id: 'lost',
          icon: Icons.phonelink_lock_rounded,
          title: t.emhLost,
          subtitle: t.emhLostSub,
          onTap: () => ChatNav.push(context, 'lost_stolen'),
        ),
      if (ff.isOn('safe_journey'))
        _HubTile(
          id: 'fake',
          icon: Icons.phone_callback_rounded,
          title: t.emhFake,
          subtitle: t.emhFakeSub,
          onTap: _fakeCall,
        ),
    ];

    return Scaffold(
      appBar: AppBar(title: Text(t.emhTitle)),
      body: ListView(
        key: const ValueKey('emh-list'),
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
        children: [
          // 1. SOS — biggest, first, on the first frame.
          EmergencySosPanel(
            contacts: _contacts,
            countdownSeconds: _countdown,
            onNoContact: _addNumbers,
            sendSos: widget.sendSos,
            locate: widget.locate,
            ladderLoad: widget.ladderLoad,
          ),
          const SizedBox(height: Gap.md),
          // 2. 999 — one tap opens the dialer; the user presses call.
          _Call999(
            label: t.emh999Button(_digits('999')),
            sub: t.emh999Sub,
            onTap: () => _dial('999'),
          ),
          const SizedBox(height: Gap.xl),
          Semantics(
            header: true,
            child: Text(t.emhMoreHelp,
                style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: Gap.sm),
          ...tiles,
          // 7. Crisis help — owner-verified numbers only.
          _CrisisCard(
            items: _crisis,
            loaded: _crisisLoaded,
            digits: _digits,
            onCall: _dial,
          ),
          ...later,
          const SizedBox(height: Gap.md),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.offline_bolt_rounded, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(t.emhOfflineNote,
                  key: const ValueKey('emh-offline-note'),
                  style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
            ),
          ]),
        ],
      ),
    );
  }
}

/// The 999 row: a full-width button (Brand.dangerFill, white text 5.6:1 in
/// both themes) that only OPENS the dialer.
class _Call999 extends StatelessWidget {
  const _Call999({required this.label, required this.sub, required this.onTap});
  final String label;
  final String sub;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      FilledButton.icon(
        key: const ValueKey('emh-999'),
        style: FilledButton.styleFrom(
          backgroundColor: Brand.dangerFill,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(56),
          padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.md),
          textStyle: AType.titleLarge.copyWith(fontWeight: FontWeight.w800),
        ),
        onPressed: onTap,
        icon: const Icon(Icons.call_rounded),
        label: Text(label, textAlign: TextAlign.center),
      ),
      const SizedBox(height: Gap.xs),
      Text(sub,
          textAlign: TextAlign.center,
          style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
    ]);
  }
}

/// One hub entry: icon, title, one-line benefit, whole row tappable (≥ 48 dp).
class _HubTile extends StatelessWidget {
  const _HubTile({
    required this.id,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final String id;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        key: ValueKey('emh-$id'),
        minVerticalPadding: Gap.sm,
        contentPadding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.xs),
        leading: CircleAvatar(
          backgroundColor: scheme.secondaryContainer,
          foregroundColor: scheme.onSecondaryContainer,
          child: Icon(icon),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: onTap,
      ),
    );
  }
}

/// Crisis help: ONLY what the server returned as owner-verified (cached on
/// the phone per language for offline). Never seen the server yet -> 999
/// alone, labelled from the app's own strings.
class _CrisisCard extends StatelessWidget {
  const _CrisisCard({
    required this.items,
    required this.loaded,
    required this.digits,
    required this.onCall,
  });
  final List<Map<String, String>> items;
  final bool loaded;
  final String Function(String) digits;
  final Future<void> Function(String number) onCall;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final rows = items.isNotEmpty
        ? items
        : [
            {'key': 'emergency', 'number': '999', 'label': t.emhCrisis999Label}
          ];
    final onlyEmergency = rows.every((r) => r['number'] == '999');
    return Card(
      key: const ValueKey('emh-crisis'),
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            CircleAvatar(
              backgroundColor: scheme.secondaryContainer,
              foregroundColor: scheme.onSecondaryContainer,
              child: const Icon(Icons.support_agent_rounded),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t.emhCrisis, style: const TextStyle(fontWeight: FontWeight.w700)),
                Text(t.emhCrisisSub,
                    style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
              ]),
            ),
          ]),
          const SizedBox(height: Gap.sm),
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: Row(children: [
                Expanded(child: Text(r['label']!.isEmpty ? r['number']! : r['label']!)),
                const SizedBox(width: Gap.sm),
                FilledButton.tonalIcon(
                  key: ValueKey('emh-crisis-${r['number']}'),
                  style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => onCall(r['number']!),
                  icon: const Icon(Icons.call_rounded, size: 18),
                  label: Text(digits(r['number']!),
                      semanticsLabel: t.crisisCallNumber(digits(r['number']!))),
                ),
              ]),
            ),
          if (loaded && onlyEmergency) ...[
            const SizedBox(height: Gap.sm),
            Text(t.emhCrisisOnly999,
                key: const ValueKey('emh-crisis-only999'),
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ]),
      ),
    );
  }
}
