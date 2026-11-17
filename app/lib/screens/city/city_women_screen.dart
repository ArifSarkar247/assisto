// cityapp B7: Women — BRTC women-only buses, reserved seats, the metro's
// women coach, and night route safety ratings from users (1-5 stars, feeds
// "Safer at night"). A safety screen: never any ads. Missing facts are said
// honestly ("not collected yet"), never invented.
import 'package:flutter/material.dart';
import '../../widgets/skeleton.dart';
import '../../ds/ds.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode;

import '../../api.dart';
import '../../city/city_api.dart';
import '../../city/city_models.dart';
import '../../city/city_widgets.dart';
import '../../l10n/app_localizations.dart';
import '../../services/action_feedback.dart' show openForUser;
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart' show showAppSheet, withNavBarInset;
import '../../widgets/chatnav.dart' show ChatNav;
import '../../widgets/local_counter.dart';

class CityWomenScreen extends StatefulWidget {
  final String city;
  const CityWomenScreen({super.key, this.city = 'dhaka'});
  @override
  State<CityWomenScreen> createState() => _CityWomenScreenState();
}

class _CityWomenScreenState extends State<CityWomenScreen> {
  CityWomen? _w;
  bool _loading = true, _failed = false;
  ApiClient get _api => context.read<AppState>().api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final m = await _api.cityWomen(widget.city);
      if (!mounted) return;
      setState(() {
        _w = CityWomen.from(m);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        // 404 = not built on this server yet -> "being collected", not an error
        _failed = !(e is ApiException && e.status == 404);
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final bn = cityBn(context);
    final w = _w;
    return Scaffold(
      appBar: AppBar(title: Text(t.cityWomen)),
      body: _loading
          ? const SkeletonList()
          : ListView(
              key: const ValueKey('city_women_list'),
              padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
              children: [
                if (_failed)
                  CityRetryCard(
                      key: const ValueKey('city_women_failed'),
                      text: t.cityGLoadFailed,
                      buttonText: t.cityTryAgain,
                      onPressed: () {
                        setState(() {
                          _loading = true;
                          _failed = false;
                        });
                        _load();
                      }),
                _fact(t, bn, Icons.subway_rounded, t.cityWomenCoach, w?.metroCoach ?? const {},
                    const ValueKey('city_women_coach')),
                _fact(t, bn, Icons.event_seat_rounded, t.cityWomenSeats, w?.reservedSeats ?? const {},
                    const ValueKey('city_women_seats')),
                CitySection(t.cityWomenBuses, icon: Icons.directions_bus_rounded),
                if ((w?.buses ?? const []).isEmpty)
                  DsCard(key: const ValueKey('city_women_buses_empty'),
                    padding: const EdgeInsets.all(Gap.lg),
                    child: Text(t.cityWomenBusesEmpty),
                  )
                else
                  for (final b in w!.buses) _bus(t, bn, b),
                CitySection(t.cityNightRatings, icon: Icons.nightlight_round),
                Text(t.cityNightRatingsSub),
                const SizedBox(height: Gap.sm),
                for (final n in (w?.night ?? const <Map<String, dynamic>>[]))
                  if ('${n['route'] ?? n['name'] ?? ''}'.isNotEmpty) _night(t, bn, n),
                FilledButton.tonalIcon(
                  key: const ValueKey('city_rate_night'),
                  style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
                  onPressed: () => showNightRating(context, api: _api, city: widget.city),
                  icon: const Icon(Icons.star_rate_rounded),
                  label: Text(t.cityRateNight),
                ),
                const SizedBox(height: Gap.lg),
                DsCard(
                  padding: EdgeInsets.zero,
                  child: ListTile(
                    minVerticalPadding: Gap.sm,
                    leading: const Icon(Icons.shield_rounded),
                    title: Text(t.cityWomenSafeJourney, style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700)),
                    subtitle: Text(t.cityWomenSafeJourneySub),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => ChatNav.push(context, 'journey'),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _fact(AppLocalizations t, bool bn, IconData icon, String title, Map<String, dynamic> m, Key key) {
    final text = '${(bn ? m['text_bn'] : m['text']) ?? m['text'] ?? m['text_en'] ?? ''}';
    final url = '${m['source_url'] ?? ''}';
    final checked = '${m['checked'] ?? ''}';
    return DsCard(key: key,
      padding: const EdgeInsets.all(Gap.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon),
            const SizedBox(width: Gap.sm),
            Expanded(child: Text(title, style: AType.titleMedium.copyWith(fontWeight: FontWeight.w800))),
          ]),
          const SizedBox(height: Gap.xs),
          Text(text.isEmpty ? t.cityNotCollectedYet : cityD(context, text)),
          if (text.isNotEmpty)
            Wrap(spacing: Gap.sm, runSpacing: Gap.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
              if ('${m['status'] ?? ''}'.isNotEmpty) CityStatusBadge('${m['status']}'),
              if (checked.isNotEmpty) Text(t.cityCheckedOn(cityDate(context, checked)), style: AType.bodySmall),
              if (url.isNotEmpty)
                TextButton(
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => openForUser(context, Uri.parse(url),
                      where: 'city.women_source', mode: LaunchMode.externalApplication),
                  child: Text(t.cityOpenSource),
                ),
            ]),
        ]),
    );
  }

  Widget _bus(AppLocalizations t, bool bn, Map<String, dynamic> b) => DsCard(
    padding: EdgeInsets.zero,
    child: ListTile(
          minVerticalPadding: Gap.sm,
          leading: const Icon(Icons.woman_rounded),
          title: Text(cityD(context, '${(bn ? b['route_bn'] : null) ?? b['route'] ?? ''}'),
              style: AType.bodyMedium.copyWith(fontWeight: FontWeight.w700)),
          subtitle: Text(cityD(context, [
            '${b['from'] ?? ''} → ${b['to'] ?? ''}',
            if ('${b['hours'] ?? ''}'.isNotEmpty) '${b['hours']}',
          ].join(' · '))),
          trailing: '${b['status'] ?? ''}'.isEmpty ? null : CityStatusBadge('${b['status']}'),
        ),
  );

  Widget _night(AppLocalizations t, bool bn, Map<String, dynamic> n) {
    final stars = (n['stars'] as num?)?.toDouble() ?? 0;
    return DsCard(
      padding: EdgeInsets.zero,
      child: ListTile(
        leading: const Icon(Icons.directions_bus_rounded),
        title: Text(cityD(context, '${n['route'] ?? n['name']}')),
        subtitle: Text(cityD(context, t.cityNightStars(stars.toStringAsFixed(1), '${n['count'] ?? 0}'))),
      ),
    );
  }
}

/// Rate a route for night safety: find the bus (our data), 1-5 stars.
Future<void> showNightRating(BuildContext context, {required ApiClient api, required String city}) async {
  final t = AppLocalizations.of(context);
  final q = TextEditingController();
  List<Map<String, dynamic>> routes = const [];
  Map<String, dynamic>? picked;
  int stars = 0;
  final done = await showAppSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      final bn = cityBn(ctx);
      return Padding(
        padding: EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.lg + MediaQuery.viewInsetsOf(ctx).bottom),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.cityRateNight, style: AType.titleLarge),
            const SizedBox(height: Gap.sm),
            TextField(
              key: const ValueKey('city_rate_search'),
              controller: q,
              maxLength: 60,
              buildCounter: localCounter,
              decoration: InputDecoration(labelText: t.cityRateWhichBus, prefixIcon: const Icon(Icons.search_rounded)),
              onChanged: (v) async {
                if (v.trim().length < 2) return;
                try {
                  final r = await api.citySearch(city, v.trim());
                  set(() => routes = [
                        for (final x in (r['routes'] as List? ?? const []))
                          if (x is Map) x.cast<String, dynamic>()
                      ]);
                } catch (_) {} // best-effort: offline -> nothing listed
              },
            ),
            for (final r in routes.take(5))
              RadioListTile<String>(
                value: '${r['id']}',
                groupValue: '${picked?['id'] ?? ''}',
                onChanged: (_) => set(() => picked = r),
                title: Text(cityD(ctx,
                    bn && '${r['name_bn'] ?? ''}'.isNotEmpty ? '${r['name_bn']}' : '${r['name'] ?? r['ref'] ?? ''}')),
              ),
            if (picked != null)
              Wrap(children: [
                for (var i = 1; i <= 5; i++)
                  IconButton(
                    key: ValueKey('city_star_$i'),
                    tooltip: cityD(ctx, t.cityStarsN('$i')),
                    onPressed: () => set(() => stars = i),
                    icon: Icon(i <= stars ? Icons.star_rounded : Icons.star_border_rounded, size: 32),
                  ),
              ]),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const ValueKey('city_rate_send'),
                style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
                onPressed: picked == null || stars == 0 ? null : () => Navigator.pop(ctx, true),
                child: Text(t.citySend),
              ),
            ),
          ]),
        ),
      );
    }),
  );
  q.dispose();
  if (done != true || picked == null || !context.mounted) return;
  final msg = ScaffoldMessenger.of(context);
  try {
    await api.cityNightRating('${picked!['id']}', stars, city: city);
    msg.showSnackBar(SnackBar(content: Text(t.cityThanksRating)));
  } catch (_) {
    msg.showSnackBar(SnackBar(content: Text(t.citySendFailed)));
  }
}
