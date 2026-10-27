import 'package:flutter/material.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../widgets/ride_deeplink.dart';
import '../widgets/ride_store.dart';
import '../widgets/ride_widgets.dart';
import '../services/action_feedback.dart'; // db1

/// Ride & food (module-5 "Life") — ADVANCED (SPEC v2.1 §21).
///
/// This screen is a DEEP-LINK LAUNCHER. For each provider (Uber, Pathao,
/// foodpanda, Pathao Food…) we open the provider's OWN app with the trip /
/// food search prefilled where their universal link allows, and we show a
/// best-effort "installed?" chip. If the app isn't installed, the https link
/// opens the provider's site in a browser (graceful fallback).
///
/// We NEVER:
///  • book a trip or place an order (in-app booking = 🤝 "not now", shown as a
///    clearly-marked deferred note — opening the provider app is the path),
///  • take payment,
///  • invent a fare (any fare note is honestly marked "approx / in their app").
///
/// Advanced adds: saved places (home/work/custom) to prefill a drop-off,
/// recent trips, and saved restaurants/cravings for one-tap reorder — all
/// stored locally (SharedPreferences via [RideStore]); no backend endpoint.
class RideFoodScreen extends StatefulWidget {
  const RideFoodScreen({super.key});
  @override
  State<RideFoodScreen> createState() => _RideFoodScreenState();
}

class _RideFoodScreenState extends State<RideFoodScreen> {
  final _store = RideStore();
  final _dest = TextEditingController();
  final _food = TextEditingController();

  bool _loading = true;
  String? _error; // shown in RideError when a launch could not be handed off

  List<SavedPlace> _places = const [];
  List<String> _trips = const [];
  List<SavedCraving> _cravings = const [];
  final Map<String, InstallState> _install = {}; // providerId -> state

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _dest.dispose();
    _food.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final places = await _store.places();
    final trips = await _store.recentTrips();
    final cravings = await _store.cravings();
    if (!mounted) return;
    // Show the user's own places/trips right away — the install probes below
    // are best-effort and must never hold the screen on skeletons.
    setState(() {
      _places = places;
      _trips = trips;
      _cravings = cravings;
      _loading = false;
    });
    final providers = [
      ...RideDeepLink.rideProviders,
      ...RideDeepLink.foodProviders,
    ];
    final states = await Future.wait(providers.map((p) => RideDeepLink
        .installState(p)
        .timeout(const Duration(seconds: 2),
            onTimeout: () => InstallState.unknown)));
    if (!mounted) return;
    setState(() {
      for (var i = 0; i < providers.length; i++) {
        _install[providers[i].id] = states[i];
      }
    });
  }

  // ---- actions -----------------------------------------------------------
  Future<void> _openRide(RideProvider p) async {
    final drop = _dest.text.trim();
    final ok = await RideDeepLink.open(RideDeepLink.urlFor(p, drop: drop));
    if (!mounted) return;
    if (ok) {
      if (drop.isNotEmpty) {
        final trips = await _store.pushTrip(drop);
        if (mounted) setState(() => _trips = trips);
      }
      setState(() => _error = null);
    } else {
      setState(() => _error = AppLocalizations.of(context).rideFoodOpenFailed);
    }
  }

  Future<void> _openFood(RideProvider p) async {
    final q = _food.text.trim();
    final ok = await RideDeepLink.open(RideDeepLink.urlFor(p, drop: q));
    if (!mounted) return;
    setState(() => _error = ok ? null : AppLocalizations.of(context).rideFoodOpenFailed);
  }

  Future<void> _saveDest(String kind) async {
    final addr = _dest.text.trim();
    final t = AppLocalizations.of(context);
    if (addr.isEmpty) {
      showNeedInput(context); // db1: was a dead tap
      return;
    }
    final label = kind == SavedPlace.home
        ? t.rideFoodPlaceHome
        : kind == SavedPlace.work
            ? t.rideFoodPlaceWork
            : addr;
    final places = await _store.savePlace(
        SavedPlace(kind: kind, label: label, address: addr));
    if (mounted) setState(() => _places = places);
  }

  Future<void> _removePlace(SavedPlace p) async {
    final places = await _store.removePlace(p);
    if (mounted) setState(() => _places = places);
  }

  Future<void> _saveCraving() async {
    final q = _food.text.trim();
    if (q.isEmpty) {
      showNeedInput(context); // db1: was a dead tap
      return;
    }
    final list = await _store.saveCraving(q);
    if (mounted) setState(() => _cravings = list);
  }

  Future<void> _removeCraving(SavedCraving c) async {
    final list = await _store.removeCraving(c);
    if (mounted) setState(() => _cravings = list);
  }

  Future<void> _clearTrips() async {
    final list = await _store.clearTrips();
    if (mounted) setState(() => _trips = list);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.rideFoodTitle)),
      body: ListView(
        padding: const EdgeInsets.all(Gap.md),
        children: [
          const RideHonestNote(),
          if (_error != null) ...[
            const SizedBox(height: Gap.sm),
            RideError(message: _error!, onRetry: () => setState(() => _error = null)),
          ],
          const SizedBox(height: Gap.md),

          // ======================= RIDE =======================
          RideSectionHeader(icon: Icons.local_taxi_rounded, label: t.rideFoodRideSection),
          TextField(
            controller: _dest,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: t.rideFoodDestLabel,
              helperText: t.rideFoodDestHelper,
              helperMaxLines: 2,
              prefixIcon: const Icon(Icons.place_rounded),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: Gap.xs),
          // save current destination as home/work/custom
          Wrap(spacing: Gap.xs, children: [
            ActionChip(
              avatar: const Icon(Icons.home_rounded, size: 18),
              label: Text(t.rideFoodSaveAsHome),
              onPressed: () => _saveDest(SavedPlace.home),
            ),
            ActionChip(
              avatar: const Icon(Icons.work_outline_rounded, size: 18),
              label: Text(t.rideFoodSaveAsWork),
              onPressed: () => _saveDest(SavedPlace.work),
            ),
            ActionChip(
              avatar: const Icon(Icons.bookmark_add_rounded, size: 18),
              label: Text(t.rideFoodSavePlace),
              onPressed: () => _saveDest(SavedPlace.other),
            ),
          ]),

          // saved places
          const SizedBox(height: Gap.sm),
          _subLabel(context, t.rideFoodSavedPlaces),
          if (_loading)
            const RideLoading()
          else if (_places.isEmpty)
            RideEmpty(icon: Icons.bookmark_border_rounded, message: t.rideFoodNoPlaces)
          else
            Wrap(
              spacing: Gap.xs,
              runSpacing: Gap.xs,
              children: [
                for (final p in _places)
                  RidePlaceChip(
                    place: p,
                    onUse: () => setState(() => _dest.text = p.address),
                    onRemove: () => _removePlace(p),
                  ),
              ],
            ),

          // recent trips
          const SizedBox(height: Gap.sm),
          _subLabel(context, t.rideFoodRecentTrips, onClear: _trips.isEmpty ? null : _clearTrips),
          if (_loading)
            const RideLoading()
          else if (_trips.isEmpty)
            RideEmpty(icon: Icons.history_rounded, message: t.rideFoodNoTrips)
          else
            Wrap(
              spacing: Gap.xs,
              runSpacing: Gap.xs,
              children: [
                for (final trip in _trips)
                  RideQuickChip(
                    label: trip,
                    icon: Icons.history_rounded,
                    onUse: () => setState(() => _dest.text = trip),
                  ),
              ],
            ),

          // fare honesty + providers
          const SizedBox(height: Gap.sm),
          const RideFareNote(),
          if (_loading)
            const RideLoading()
          else
            for (final p in RideDeepLink.rideProviders)
              RideProviderTile(
                provider: p,
                install: _install[p.id] ?? InstallState.unknown,
                onOpen: () => _openRide(p),
              ),

          const SizedBox(height: Gap.lg),

          // ======================= FOOD =======================
          RideSectionHeader(icon: Icons.fastfood_rounded, label: t.rideFoodFoodSection),
          TextField(
            controller: _food,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: t.rideFoodFoodLabel,
              helperText: t.rideFoodFoodHelper,
              helperMaxLines: 2,
              prefixIcon: const Icon(Icons.restaurant_rounded),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: Gap.xs),
          Align(
            alignment: Alignment.centerLeft,
            child: ActionChip(
              avatar: const Icon(Icons.favorite_border_rounded, size: 18),
              label: Text(t.rideFoodSaveCraving),
              onPressed: _saveCraving,
            ),
          ),

          // saved restaurants / cravings (reorder shortcut)
          const SizedBox(height: Gap.sm),
          _subLabel(context, t.rideFoodSavedCravings),
          if (_loading)
            const RideLoading()
          else if (_cravings.isEmpty)
            RideEmpty(icon: Icons.favorite_border_rounded, message: t.rideFoodNoCravings)
          else
            Wrap(
              spacing: Gap.xs,
              runSpacing: Gap.xs,
              children: [
                for (final c in _cravings)
                  RideQuickChip(
                    label: c.query,
                    icon: Icons.restaurant_rounded,
                    onUse: () => setState(() => _food.text = c.query),
                    onRemove: () => _removeCraving(c),
                  ),
              ],
            ),

          const SizedBox(height: Gap.sm),
          if (_loading)
            const RideLoading()
          else
            for (final p in RideDeepLink.foodProviders)
              RideProviderTile(
                provider: p,
                install: _install[p.id] ?? InstallState.unknown,
                onOpen: () => _openFood(p),
              ),

          // truth: no "in-app booking when a partner is connected" promise —
          // the screen opens the provider's own app, nothing more.
        ],
      ),
    );
  }

  Widget _subLabel(BuildContext context, String text, {VoidCallback? onClear}) {
    final t = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.xs, top: Gap.xs),
      child: Row(children: [
        Expanded(
          child: Text(text,
              style: AType.bodySmall.copyWith(fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
        if (onClear != null)
          TextButton(onPressed: onClear, child: Text(t.rideFoodClear)),
      ]),
    );
  }
}
