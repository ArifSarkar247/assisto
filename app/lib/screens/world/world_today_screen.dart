import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/skeleton.dart';
import '../../world/world_api.dart';
import '../../world/world_widgets.dart';

/// p4-world TODAY: daily cards the user turns on/off (synced to the account):
/// prayer times (calculated on the server, no key), weather (MET Norway),
/// currency (ExchangeRate-API), gold & fuel (official prices typed by
/// Assisto, dated), Bangladesh + world headlines (official RSS: headline +
/// short summary + link only) and live scores (only with a licensed key).
/// A card with no real data is not shown — nothing is ever made up.
class WorldTodayScreen extends StatefulWidget {
  const WorldTodayScreen({super.key, this.api});
  final WorldApi? api;

  @override
  State<WorldTodayScreen> createState() => _WorldTodayScreenState();
}

const _order = [
  'prayer',
  'weather',
  'currency',
  'gold',
  'fuel',
  'news_bd',
  'news_world',
  'cricket',
  'football'
];

class _WorldTodayScreenState extends State<WorldTodayScreen> {
  late final WorldApi api =
      widget.api ?? ApiWorldApi(context.read<AppState>().api);
  Map<String, dynamic>? _data;
  Map<String, dynamic>? _config;
  bool _loading = true;
  bool _fromCache = false;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    final lang = uwLang(context);
    setState(() {
      _loading = _data == null;
      _error = false;
    });
    try {
      final r = await Future.wait([api.today(), api.config()])
          .timeout(const Duration(seconds: 30));
      if (!mounted) return;
      if (worldStatus(r[0]) != 200) throw StateError('status');
      await WorldCache.save('today', lang, r[0]);
      setState(() {
        _data = r[0];
        _config = worldStatus(r[1]) == 200 ? r[1] : _config;
        _fromCache = false;
        _loading = false;
      });
    } catch (_) {
      final c = await WorldCache.read('today', lang);
      if (!mounted) return;
      setState(() {
        _data ??= c;
        _fromCache = c != null;
        _error = _data == null;
        _loading = false;
      });
    }
  }

  String _cardTitle(AppLocalizations t, String id) => switch (id) {
        'prayer' => t.uwCardPrayer,
        'weather' => t.uwCardWeather,
        'currency' => t.uwCardCurrency,
        'gold' => t.uwCardGold,
        'fuel' => t.uwCardFuel,
        'news_bd' => t.uwCardNewsBd,
        'news_world' => t.uwCardNewsWorld,
        'cricket' => t.uwCardCricket,
        _ => t.uwCardFootball,
      };

  IconData _cardIcon(String id) => switch (id) {
        'prayer' => Icons.mosque_outlined,
        'weather' => Icons.wb_cloudy_outlined,
        'currency' => Icons.currency_exchange,
        'gold' => Icons.diamond_outlined,
        'fuel' => Icons.local_gas_station_outlined,
        'news_bd' => Icons.newspaper,
        'news_world' => Icons.public,
        'cricket' => Icons.sports_cricket,
        _ => Icons.sports_soccer,
      };

  Future<void> _customize() async {
    final t = AppLocalizations.of(context);
    final cfg = _config ?? const {};
    final prefs = worldMap(cfg['prefs']);
    final on = Map<String, dynamic>.from(worldMap(prefs['cards']).isEmpty
        ? worldMap(_data?['on'])
        : worldMap(prefs['cards']));
    final sports = worldMap(cfg['sports']);
    final hidden = worldMap(_data?['hidden']);
    var city = '${prefs['city'] ?? worldMap(_data?['city'])['id'] ?? 'dhaka'}';
    final cities = worldList(cfg['cities']);
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
        final ids = _order.where((id) =>
            !(id == 'cricket' || id == 'football') || sports[id] == true);
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * 0.85),
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Flexible(
                      child: ListView(
                          shrinkWrap: true,
                          padding: const EdgeInsets.fromLTRB(
                              Gap.lg, 0, Gap.lg, Gap.sm),
                          children: [
                        Text(t.uwCustomizeTitle,
                            style: Theme.of(ctx).textTheme.titleLarge),
                        const SizedBox(height: Gap.xs),
                        Text(t.uwCustomizeBody),
                        const SizedBox(height: Gap.md),
                        if (cities.isNotEmpty)
                          DropdownButtonFormField<String>(
                            initialValue: cities.any((c) => c['id'] == city)
                                ? city
                                : null,
                            isExpanded: true,
                            decoration: InputDecoration(labelText: t.uwCity),
                            items: [
                              for (final c in cities)
                                DropdownMenuItem(
                                    value: '${c['id']}',
                                    child: Text('${c['name']}')),
                            ],
                            onChanged: (v) => setS(() => city = v ?? city),
                          ),
                        const SizedBox(height: Gap.sm),
                        for (final id in ids)
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            secondary: Icon(_cardIcon(id)),
                            title: Text(_cardTitle(t, id)),
                            subtitle: hidden[id] == null
                                ? null
                                : Text(hidden[id] == 'not_entered'
                                    ? t.uwNotEnteredYet
                                    : t.uwNotAvailableNow),
                            value: on[id] != false,
                            onChanged: (v) => setS(() => on[id] = v),
                          ),
                      ])),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                        Gap.lg, Gap.xs, Gap.lg, Gap.lg),
                    child: FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: Text(t.uwSave)),
                  ),
                ]),
          ),
        );
      }),
    );
    if (saved != true || !mounted) return;
    try {
      await api.savePrefs({'cards': on, 'city': city}).timeout(
          const Duration(seconds: 20));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t.uwSaveFailed)));
      }
      return;
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.uwTodayTitle), actions: [
        IconButton(
          tooltip: t.uwCustomize,
          onPressed: _data == null ? null : _customize,
          icon: const Icon(Icons.tune),
        ),
      ]),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off,
                  tint: scheme.error,
                  title: t.loadFailed,
                  message: t.uwOffline,
                  action: FilledButton.tonalIcon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label: Text(t.retry)),
                )
              : RefreshIndicator(onRefresh: _load, child: _body(t, scheme)),
    );
  }

  Widget _body(AppLocalizations t, ColorScheme scheme) {
    final d = _data!;
    final cards = worldMap(d['cards']);
    final city = worldMap(d['city']);
    final shown = _order.where(cards.containsKey).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.xl),
      children: [
        if (_fromCache) ...[
          UwNote(icon: Icons.offline_bolt_outlined, text: t.uwCachedCopy),
          const SizedBox(height: Gap.sm),
        ],
        if ('${city['name'] ?? ''}'.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.sm),
            child: Row(children: [
              Icon(Icons.place_outlined,
                  size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: Gap.xs),
              Text('${city['name']}',
                  style: TextStyle(color: scheme.onSurfaceVariant)),
            ]),
          ),
        if (shown.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Gap.xl),
            child: StateMessage(
                icon: Icons.dashboard_customize_outlined,
                title: t.uwNoCardsTitle,
                message: t.uwNoCardsBody),
          ),
        for (final id in shown)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.md),
            child: Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(Gap.lg),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Icon(_cardIcon(id), color: scheme.primary),
                        const SizedBox(width: Gap.sm),
                        Expanded(
                            child: Text(_cardTitle(t, id),
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w700))),
                        if (id.startsWith('news_'))
                          UwSpeakButton(
                              compact: true,
                              text: worldList(worldMap(cards[id])['items'])
                                  .take(5)
                                  .map((e) => '${e['title']}')
                                  .join('। ')),
                      ]),
                      const SizedBox(height: Gap.sm),
                      _cardBody(t, scheme, id, worldMap(cards[id])),
                    ]),
              ),
            ),
          ),
      ],
    );
  }

  Widget _row(String a, String b, {bool strong = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(child: Text(a)),
          const SizedBox(width: Gap.sm),
          Text(b,
              style: TextStyle(
                  fontWeight: strong ? FontWeight.w700 : FontWeight.w500)),
        ]),
      );

  Widget _cardBody(AppLocalizations t, ColorScheme scheme, String id,
      Map<String, dynamic> c) {
    final dg = (Object v) => uwDigits(context, v);
    switch (id) {
      case 'prayer':
        final times = worldMap(c['times']);
        final next = '${c['next'] ?? ''}';
        final names = {
          'fajr': t.uwFajr,
          'sunrise': t.uwSunrise,
          'dhuhr': t.uwDhuhr,
          'asr': t.uwAsr,
          'maghrib': t.uwMaghrib,
          'isha': t.uwIsha,
        };
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final k in names.keys)
            if (times[k] != null)
              _row(names[k]!, dg(times[k]), strong: k == next),
          const SizedBox(height: Gap.xs),
          Text('${c['note'] ?? ''}',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant)),
        ]);
      case 'weather':
        final next = worldList(c['next']);
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('${dg((c['temp'] as num?)?.round() ?? '')}°',
                style: Theme.of(context).textTheme.displaySmall),
            const SizedBox(width: Gap.md),
            Expanded(
                child: Text('${c['label'] ?? ''}',
                    style: Theme.of(context).textTheme.titleMedium)),
          ]),
          const SizedBox(height: Gap.xs),
          Text(t.uwHumidityWind(dg((c['humidity'] as num?)?.round() ?? '-'),
              dg((c['wind'] as num?)?.toStringAsFixed(1) ?? '-'))),
          if (next.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            Wrap(spacing: Gap.md, runSpacing: Gap.xs, children: [
              for (final s in next)
                Text(
                    '${uwWhen(context, '${s['time']}')}: ${dg((s['temp'] as num?)?.round() ?? '')}° ${s['label']}',
                    style: Theme.of(context).textTheme.bodySmall),
            ]),
          ],
          UwSourceLine(
              source: '${c['source']}',
              url: '${c['source_url'] ?? ''}',
              updated: '${c['updated'] ?? ''}'),
        ]);
      case 'currency':
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final r in worldList(c['rows']))
            _row('${r['name']} (${r['code']})', '৳${dg(r['bdt'])}'),
          const SizedBox(height: Gap.xs),
          Text('${c['note'] ?? ''}',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant)),
          UwSourceLine(
              source: '${c['source']}',
              url: '${c['source_url'] ?? ''}',
              updated: '${c['updated'] ?? ''}'),
        ]);
      case 'gold':
      case 'fuel':
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final r in worldList(c['rows']))
            _row('${r['label']}', '৳${dg((r['bdt'] as num?)?.round() ?? '')}'),
          const SizedBox(height: Gap.xs),
          Text(
              t.uwEnteredByAssisto(
                  uwWhen(context, '${c['updated'] ?? ''}', time: false)),
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant)),
          UwSourceLine(
              source: '${c['source']}', url: '${c['source_url'] ?? ''}'),
        ]);
      case 'news_bd':
      case 'news_world':
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final it in worldList(c['items']))
            InkWell(
              onTap: () => uwOpen(context, '${it['link']}'),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Gap.sm),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${it['title']}',
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, height: 1.35)),
                      if ('${it['snippet'] ?? ''}'.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text('${it['snippet']}',
                              style: TextStyle(
                                  color: scheme.onSurfaceVariant,
                                  height: 1.35)),
                        ),
                      const SizedBox(height: 2),
                      Text(
                        [
                          '${it['source'] ?? ''}',
                          if ('${it['published'] ?? ''}'.isNotEmpty)
                            uwWhen(context, '${it['published']}'),
                        ].join(' · '),
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: scheme.primary),
                      ),
                    ]),
              ),
            ),
          Text(t.uwNewsNote,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant)),
        ]);
      default:
        final m = worldList(c['matches']);
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (m.isEmpty) Text(t.uwNoLiveMatches),
          for (final x in m)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Gap.xs),
              child: id == 'cricket'
                  ? Text('${x['name']}\n${x['score']}  ${x['status']}')
                  : Text(
                      '${x['home']} ${dg(x['score'] ?? '')} ${x['away']}  (${x['league']})'),
            ),
          UwSourceLine(
              source: '${c['source']}', updated: '${c['updated'] ?? ''}'),
        ]);
    }
  }
}
