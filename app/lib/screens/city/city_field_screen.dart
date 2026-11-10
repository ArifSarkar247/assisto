// citycov: "Map a stop" — field collection with one tap, at the phone's own
// location: "Add a stop here" (no bus named) or "This bus stops here" (one of
// the buses that pass close by), and "Yes, it stops here" on a waiting report
// nearby. No names and no free text are sent; the server counts different
// people with a keyed hash only. A stop goes on the map after 3 different
// people (shown as Reported by users); the owner reviews every report in
// Owner Admin -> City data -> Users' stops and can remove wrong ones.
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../city/city_api.dart';
import '../../city/city_models.dart';
import '../../city/city_widgets.dart';
import '../../l10n/app_localizations.dart';
import '../../maps/place_search.dart' show placeHereNow;
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart' show withNavBarInset;

class CityFieldScreen extends StatefulWidget {
  @visibleForTesting
  final ({double lat, double lon})? debugHere;
  const CityFieldScreen({super.key, this.debugHere});
  @override
  State<CityFieldScreen> createState() => _CityFieldScreenState();
}

class _CityFieldScreenState extends State<CityFieldScreen> {
  ({double lat, double lon})? _here;
  bool _loading = true, _failed = false, _busy = false;
  List<CityFieldStop> _items = const [];
  List<CityNearRoute> _routes = const [];
  int _need = 3;
  final Set<String> _sent = {}; // 'here', 'r:<route id>', 'c:<report id>'

  ApiClient get _api => context.read<AppState>().api;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    _here = widget.debugHere;
    if (_here == null) {
      final p = await placeHereNow(context);
      if (p != null) _here = (lat: p.lat, lon: p.lng);
    }
    await _load();
  }

  Future<void> _load() async {
    final h = _here;
    if (h == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final r = await _api.cityFieldStops(h.lat, h.lon);
      if (!mounted) return;
      final need = (r['need'] as num?)?.toInt() ?? 3;
      setState(() {
        _need = need;
        _items = [for (final e in (r['items'] as List? ?? const [])) CityFieldStop.from(e, need)];
        _routes = [for (final e in (r['routes'] as List? ?? const [])) CityNearRoute.from(e)];
        _failed = false;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _failed = true;
          _loading = false;
        });
      }
    }
  }

  Future<void> _send(String tag, {String routeId = '', int? id}) async {
    final t = AppLocalizations.of(context);
    final msg = ScaffoldMessenger.of(context);
    final h = _here;
    if (h == null) {
      msg.showSnackBar(SnackBar(content: Text(t.cityAroundNeedLocation)));
      return;
    }
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final r = await _api.cityFieldStopAdd(h.lat, h.lon, routeId: routeId, id: id);
      final st = '${r['status'] ?? ''}';
      if (!mounted) return;
      setState(() => _sent.add(tag));
      msg.showSnackBar(SnackBar(
          content: Text(switch (st) {
        'confirmed' => t.cityMapConfirmed,
        'known' => t.cityMapKnown,
        'already' => t.cityMapAlready,
        'rejected' => t.cityMapRejected,
        _ => t.cityMapThanks(cityD(context, '$_need')),
      })));
      await _load();
    } catch (e) {
      final reason = e is ApiException ? e.reason : null;
      msg.showSnackBar(SnackBar(
          content: Text(e is ApiException && e.status == 429
              ? t.cityMapLimit
              : reason == 'far'
                  ? t.cityMapFar
                  : t.citySendFailed)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A row that stays readable at 200 % font: title + subtitle, and the one
  /// action as its own 48 dp button underneath (never squeezed beside it).
  Widget _card(
      {required Key key,
      required Widget icon,
      required String title,
      required String subtitle,
      required bool done,
      required String action,
      required VoidCallback onTap}) {
    return Card(
      key: key,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            icon,
            const SizedBox(width: Gap.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title,
                    style: DefaultTextStyle.of(context).style.copyWith(fontWeight: FontWeight.w700)),
                if (subtitle.isNotEmpty) Text(subtitle, style: AType.bodySmall),
              ]),
            ),
            if (done) const Icon(Icons.check_rounded),
          ]),
          if (!done)
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton(
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: _busy ? null : onTap,
                child: Text(action),
              ),
            ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    final bn = cityBn(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.cityMapTitle)),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          key: const ValueKey('city_map_list'),
          padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
          children: [
            Card(
              color: s.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(Gap.lg),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(t.cityMapBenefit,
                      style: AType.titleMedium.copyWith(color: s.onSecondaryContainer, fontWeight: FontWeight.w800)),
                  const SizedBox(height: Gap.md),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      key: const ValueKey('city_map_add_here'),
                      style: FilledButton.styleFrom(minimumSize: const Size(48, 56)),
                      onPressed: _sent.contains('here') || _busy || _here == null ? null : () => _send('here'),
                      icon: Icon(_sent.contains('here') ? Icons.check_rounded : Icons.add_location_alt_rounded),
                      label: Text(t.cityMapAddHere),
                    ),
                  ),
                  const SizedBox(height: Gap.sm),
                  Text(cityD(context, t.cityMapHow('$_need')),
                      style: AType.bodySmall.copyWith(color: s.onSecondaryContainer)),
                ]),
              ),
            ),
            if (_loading)
              const Padding(padding: EdgeInsets.all(Gap.lg), child: Center(child: CircularProgressIndicator()))
            else if (_here == null)
              Padding(padding: const EdgeInsets.only(top: Gap.lg), child: Text(t.cityAroundNeedLocation))
            else if (_failed)
              Padding(padding: const EdgeInsets.only(top: Gap.lg), child: Text(t.cityMapFailed))
            else ...[
              CitySection(t.cityMapWhichBus, icon: Icons.directions_bus_rounded),
              if (_routes.isEmpty)
                Text(t.cityMapNoBuses)
              else
                for (final r in _routes)
                  _card(
                    key: ValueKey('city_map_route_${r.id}'),
                    icon: Icon(r.mode == 'leguna' ? Icons.airport_shuttle_rounded : Icons.directions_bus_rounded),
                    title: r.label(bn),
                    subtitle: r.ends(bn),
                    done: _sent.contains('r:${r.id}'),
                    action: t.cityMapThisBus,
                    onTap: () => _send('r:${r.id}', routeId: r.id),
                  ),
              CitySection(t.cityMapOthers, icon: Icons.how_to_vote_rounded),
              if (_items.isEmpty)
                Card(
                  child: Padding(padding: const EdgeInsets.all(Gap.lg), child: Text(t.cityMapNoneWaiting)),
                )
              else
                for (final f in _items)
                  _card(
                    key: ValueKey('city_map_item_${f.id}'),
                    icon: Icon(f.confirmed ? Icons.verified_rounded : Icons.pending_rounded,
                        color: f.confirmed ? Brand.success : s.onSurfaceVariant),
                    title: f.route.isEmpty ? t.cityMapAnyBus : f.routeLabel(bn),
                    subtitle: cityD(context, [
                      f.confirmed ? t.cityMapOnMap : t.cityMapPeople('${f.people}', '${f.need}'),
                      cityDistance(context, f.meters),
                    ].join(' · ')),
                    done: f.mine || f.confirmed || _sent.contains('c:${f.id}'),
                    action: t.cityMapYes,
                    onTap: () => _send('c:${f.id}', id: f.id),
                  ),
            ],
          ],
        ),
      ),
    );
  }
}
