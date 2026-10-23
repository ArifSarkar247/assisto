import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ads/sponsor_api.dart';
import '../ads/sponsor_models.dart';
import '../ads/sponsor_widgets.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/ladder_common.dart' show fmtInt;

/// p2-money: BRAND OFFERS BY INTEREST.
///  * Settings -> Offers & brands: favourite categories, offer notifications
///    on/off (server cap: max N a day, default 2), mute any brand, optional
///    division, and the current offers feed.
///  * The optional onboarding step (skippable) saves the same picks.
/// Premium users see no offers unless the owner allows it (server decides).

const offerCategories = [
  'mobile', 'electronics', 'fashion', 'grocery', 'food', 'health', 'beauty',
  'education', 'travel', 'home', 'kids', 'auto', 'telecom', 'banking',
];
const bdDivisions = [
  'dhaka', 'chattogram', 'rajshahi', 'khulna', 'barishal', 'sylhet', 'rangpur',
  'mymensingh',
];

String offerCategoryLabel(AppLocalizations t, String id) => switch (id) {
      'mobile' => t.p2CatMobile,
      'electronics' => t.p2CatElectronics,
      'fashion' => t.p2CatFashion,
      'grocery' => t.p2CatGrocery,
      'food' => t.p2CatFood,
      'health' => t.p2CatHealth,
      'beauty' => t.p2CatBeauty,
      'education' => t.p2CatEducation,
      'travel' => t.p2CatTravel,
      'home' => t.p2CatHome,
      'kids' => t.p2CatKids,
      'auto' => t.p2CatAuto,
      'telecom' => t.p2CatTelecom,
      'banking' => t.p2CatBanking,
      _ => id,
    };

String divisionLabel(AppLocalizations t, String id) => switch (id) {
      'dhaka' => t.p2DivDhaka,
      'chattogram' => t.p2DivChattogram,
      'rajshahi' => t.p2DivRajshahi,
      'khulna' => t.p2DivKhulna,
      'barishal' => t.p2DivBarishal,
      'sylhet' => t.p2DivSylhet,
      'rangpur' => t.p2DivRangpur,
      'mymensingh' => t.p2DivMymensingh,
      _ => t.p2OffersDivisionNone,
    };

/// Picks made before sign-in (onboarding) wait here and are sent once the
/// user is signed in ([syncPendingOfferPrefs]).
const _kPending = 'p2_offer_cats_pending';

Future<void> savePendingOfferCats(List<String> cats) async {
  try {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_kPending, cats);
  } catch (_) {}
}

Future<void> syncPendingOfferPrefs(SponsorBackend b) async {
  try {
    final p = await SharedPreferences.getInstance();
    final cats = p.getStringList(_kPending);
    if (cats == null) return;
    await b.saveOfferPrefs({'categories': cats, 'onboarding_done': true});
    await p.remove(_kPending);
  } catch (_) {}
}

class CategoryChips extends StatelessWidget {
  const CategoryChips({super.key, required this.selected, required this.onChanged});
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
      for (final c in offerCategories)
        FilterChip(
          label: Text(offerCategoryLabel(t, c)),
          selected: selected.contains(c),
          onSelected: (on) {
            final s = {...selected};
            on ? s.add(c) : s.remove(c);
            onChanged(s);
          },
        ),
    ]);
  }
}

// ------------------------------------------------------------ settings
class OffersSettingsScreen extends StatefulWidget {
  const OffersSettingsScreen({super.key, this.backend});
  final SponsorBackend? backend;

  @override
  State<OffersSettingsScreen> createState() => _OffersSettingsScreenState();
}

class _OffersSettingsScreenState extends State<OffersSettingsScreen> {
  bool _loading = true, _failed = false;
  Set<String> _cats = {};
  bool _notifs = true;
  String _division = '';
  int _cap = 2;
  bool _paid = false, _premiumGets = false;
  List<Map<String, dynamic>> _brands = [];

  late final SponsorBackend _b =
      widget.backend ?? ApiSponsorBackend(context.read<AppState>().api);

  @override
  void initState() {
    super.initState();
    _load();
  }

  int _i(dynamic v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      await syncPendingOfferPrefs(_b);
      final p = await _b.offerPrefs();
      final br = await _b.brands();
      if (!mounted) return;
      setState(() {
        _cats = ((p['categories'] as List?) ?? const []).map((e) => '$e').toSet();
        _notifs = p['notifs_on'] != false;
        _division = '${p['division'] ?? ''}';
        _cap = _i(p['notif_daily_cap']);
        _paid = p['paid'] == true;
        _premiumGets = p['premium_gets_offers'] == true;
        _brands = br;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  Future<void> _save(Map<String, dynamic> body) async {
    final t = AppLocalizations.of(context);
    try {
      await _b.saveOfferPrefs(body);
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
              content: Text(t.p2OffersSaved), duration: const Duration(seconds: 1)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t.loadFailed)));
      }
    }
  }

  Future<void> _mute(Map<String, dynamic> b, bool muted) async {
    final id = _i(b['id']);
    setState(() => b['muted'] = muted);
    try {
      await _b.muteBrand(id, muted);
    } catch (_) {
      if (mounted) setState(() => b['muted'] = !muted);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.p2OffersTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _failed
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(t.loadFailed),
                  const SizedBox(height: Gap.sm),
                  OutlinedButton(onPressed: _load, child: Text(t.retry)),
                ]))
              : ListView(padding: const EdgeInsets.all(Gap.lg), children: [
                  if (_paid && !_premiumGets)
                    Container(
                      margin: const EdgeInsets.only(bottom: Gap.lg),
                      padding: const EdgeInsets.all(Gap.md),
                      decoration: BoxDecoration(
                        color: scheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(Radii.md),
                      ),
                      child: Text(t.p2OffersPremiumOff,
                          style: TextStyle(color: scheme.onSecondaryContainer)),
                    ),
                  Text(t.p2OffersIntro,
                      style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
                  const SizedBox(height: Gap.lg),
                  Text(t.p2OffersCats, style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: Gap.sm),
                  CategoryChips(
                    selected: _cats,
                    onChanged: (s) {
                      setState(() => _cats = s);
                      _save({'categories': s.toList()});
                    },
                  ),
                  const SizedBox(height: Gap.lg),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(t.p2OffersNotifs),
                    subtitle: Text(t.p2OffersNotifsSub(fmtInt(context, _cap))),
                    value: _notifs,
                    onChanged: (v) {
                      setState(() => _notifs = v);
                      _save({'notifs_on': v});
                    },
                  ),
                  const SizedBox(height: Gap.sm),
                  Text(t.p2OffersDivision, style: Theme.of(context).textTheme.titleSmall),
                  DropdownButton<String>(
                    isExpanded: true,
                    value: _division,
                    items: [
                      DropdownMenuItem(value: '', child: Text(t.p2OffersDivisionNone)),
                      for (final d in bdDivisions)
                        DropdownMenuItem(value: d, child: Text(divisionLabel(t, d))),
                    ],
                    onChanged: (v) {
                      setState(() => _division = v ?? '');
                      _save({'division': v ?? ''});
                    },
                  ),
                  const SizedBox(height: Gap.lg),
                  Text(t.p2OffersBrands, style: Theme.of(context).textTheme.titleSmall),
                  if (_brands.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: Gap.sm),
                      child: Text(t.p2OffersBrandsEmpty,
                          style: TextStyle(color: scheme.onSurfaceVariant)),
                    ),
                  for (final b in _brands)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('${b['name'] ?? ''}'),
                      subtitle: Text(b['muted'] == true ? t.p2OffersMuted : t.p2OffersShown),
                      value: b['muted'] != true,
                      onChanged: (on) => _mute(b, !on),
                    ),
                  const SizedBox(height: Gap.lg),
                  FilledButton.tonalIcon(
                    onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => OffersFeedScreen(backend: widget.backend))),
                    icon: const Icon(Icons.local_offer_outlined),
                    label: Text(t.p2OffersFeedOpen),
                  ),
                ]),
    );
  }
}

// ------------------------------------------------------------ feed
class OffersFeedScreen extends StatefulWidget {
  const OffersFeedScreen({super.key, this.backend});
  final SponsorBackend? backend;

  @override
  State<OffersFeedScreen> createState() => _OffersFeedScreenState();
}

class _OffersFeedScreenState extends State<OffersFeedScreen> {
  List<SponsorCreative>? _offers;
  bool _failed = false;
  late final SponsorBackend _b =
      widget.backend ?? ApiSponsorBackend(context.read<AppState>().api);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final o = await _b.offersFeed();
      if (!mounted) return;
      setState(() => _offers = o);
      for (final c in o.take(10)) {
        unawaited(_b.event(c.token, 'impression'));
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final o = _offers;
    return Scaffold(
      appBar: AppBar(title: Text(t.p2OffersFeedTitle)),
      body: _failed
          ? Center(child: Text(t.loadFailed))
          : o == null
              ? const Center(child: CircularProgressIndicator())
              : o.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(Gap.xl),
                        child: Text(t.p2OffersFeedEmpty,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: scheme.onSurfaceVariant)),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.symmetric(vertical: Gap.sm),
                      children: [
                        for (final c in o)
                          SponsoredPostCard(
                            creative: c,
                            compactImage: true,
                            footer: c.endsAt.length >= 10
                                ? Text(t.p2OffersEnds(c.endsAt.substring(0, 10)),
                                    style: TextStyle(
                                        fontSize: 12, color: scheme.onSurfaceVariant))
                                : null,
                            onClick: () => unawaited(_b.event(c.token, 'click')),
                            onHide: () {
                              unawaited(_b.event(c.token, 'hide'));
                              setState(() => _offers = [...o]..remove(c));
                            },
                            onMute: () {
                              unawaited(_b.event(c.token, 'mute'));
                              setState(() => _offers =
                                  o.where((x) => x.sponsorId != c.sponsorId).toList());
                            },
                          ),
                      ],
                    ),
    );
  }
}

// ------------------------------------------------------------ onboarding
/// Optional onboarding step: pick a few categories or skip. Saved locally
/// and sent after sign-in (onboarding can run before the account exists).
class OnbOffersStep extends StatefulWidget {
  const OnbOffersStep({super.key});
  @override
  State<OnbOffersStep> createState() => _OnbOffersStepState();
}

class _OnbOffersStepState extends State<OnbOffersStep> {
  Set<String> _cats = {};

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.lg, Gap.xl, Gap.lg),
      children: [
        Icon(Icons.local_offer_outlined, size: 40, color: scheme.primary),
        const SizedBox(height: Gap.md),
        Text(t.p2OnbOffersTitle,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.sm),
        Text(t.p2OnbOffersSub,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
        const SizedBox(height: Gap.lg),
        CategoryChips(
          selected: _cats,
          onChanged: (s) {
            setState(() => _cats = s);
            unawaited(savePendingOfferCats(s.toList()));
          },
        ),
      ],
    );
  }
}
