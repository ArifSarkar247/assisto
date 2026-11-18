import 'package:flutter/material.dart';
import '../../ds/ds.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/skeleton.dart';
import '../../world/world_api.dart';
import '../../world/world_widgets.dart';
import 'package:assisto/widgets/app_sheet.dart';

/// p4-world TODAY: daily cards the user turns on/off (synced to the account):
/// prayer times (calculated on the server, no key), weather (MET Norway),
/// currency (ExchangeRate-API), gold & fuel (official prices typed by
/// Assisto, dated), Bangladesh + world headlines (official RSS: headline +
/// short summary + link only) and live scores (only with a licensed key).
/// A card with no real data is not shown — nothing is ever made up.
/// p3feed: Bangladesh Bank's official USD rate (owner-entered, dated) leads the
/// currency card; official notice links (load-shedding, BMD, flood); cards
/// that are on but have no real data are listed under "Not connected yet" with the
/// honest reason; prayer times for a week so an offline phone stays right.
class WorldTodayScreen extends StatefulWidget {
  const WorldTodayScreen({super.key, this.api, this.debugSavedCopy});
  final WorldApi? api;

  /// Gallery / tests only: the saved copy instead of the phone's cache.
  final Map<String, dynamic>? debugSavedCopy;

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
  'football',
  'notices'
];

class _WorldTodayScreenState extends State<WorldTodayScreen> {
  late final WorldApi api =
      widget.api ?? ApiWorldApi(context.read<AppState>().api);
  Map<String, dynamic>? _data;
  Map<String, dynamic>? _config;
  bool _loading = true;
  bool _fromCache = false;
  bool _error = false;
  // homefeed: the last refresh failed while a saved copy is on screen
  bool _offline = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  /// homefeed: cache FIRST (the saved copy paints at once, dated), then the
  /// server in the background. A failed refresh keeps the copy on screen with
  /// "offline — copy saved X ago"; never a blank page while a copy exists.
  Future<void> _load({bool byUser = false}) async {
    final lang = uwLang(context);
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (_data == null) {
      final c = widget.debugSavedCopy ?? await WorldCache.read('today', lang);
      if (!mounted) return;
      if (c != null && _data == null) {
        setState(() {
          _data = c;
          _fromCache = true;
          _loading = false;
        });
      }
    }
    setState(() {
      _loading = _data == null;
      _error = false;
    });
    try {
      final r = await Future.wait([api.today(), api.config()])
          .timeout(const Duration(seconds: 15));
      if (!mounted) return;
      if (worldStatus(r[0]) != 200) throw StateError('status');
      await WorldCache.save('today', lang, r[0]);
      if (!mounted) return;
      setState(() {
        _data = r[0];
        _config = worldStatus(r[1]) == 200 ? r[1] : _config;
        _fromCache = false;
        _offline = false;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _offline = _data != null;
        _error = _data == null;
        _loading = false;
      });
      if (byUser && _data != null) {
        messenger?.showSnackBar(SnackBar(
            content: Text(t.uwOfflineCopyAgo(
                uwAgo(context, '${_data?['generated_at'] ?? ''}')))));
      }
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
        'football' => t.uwCardFootball,
        _ => t.uwCardNotices,
      };

  IconData _cardIcon(String id) => switch (id) {
        'prayer' => Icons.mosque_rounded,
        'weather' => Icons.wb_cloudy_rounded,
        'currency' => Icons.currency_exchange_rounded,
        'gold' => Icons.diamond_rounded,
        'fuel' => Icons.local_gas_station_rounded,
        'news_bd' => Icons.newspaper_rounded,
        'news_world' => Icons.public_rounded,
        'cricket' => Icons.sports_cricket_rounded,
        'football' => Icons.sports_soccer_rounded,
        _ => Icons.campaign_rounded,
      };

  /// p3feed: a cached copy from an earlier day carries the next 7 days of
  /// prayer times — show today's (pure calculation, valid offline).
  /// homefeed: null when the copy has no times for today (older than a
  /// week) — never another day's times shown as today's.
  Map<String, dynamic>? _prayerForToday(Map<String, dynamic> c) {
    // the times are Bangladesh clock times for a Bangladesh city: judge
    // "today" and "next" on Bangladesh time (UTC+6, no DST) — right for an
    // expat phone on another clock too
    final now = DateTime.now().toUtc().add(const Duration(hours: 6));
    final today =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final hhmm =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    Map<String, dynamic> pick(Map<String, dynamic> times) {
      var next = 'fajr';
      for (final k in const ['fajr', 'dhuhr', 'asr', 'maghrib', 'isha']) {
        final v = times[k];
        if (v != null && '$v'.compareTo(hhmm) > 0) {
          next = k;
          break;
        }
      }
      return {...c, 'times': times, 'next': next, 'date': today};
    }

    if ('${c['date'] ?? ''}' == today) return pick(worldMap(c['times']));
    for (final d in worldList(c['days'])) {
      if ('${d['date']}' == today) return pick(worldMap(d['times']));
    }
    // an old copy without a date (before homefeed) is trusted only if it is
    // from today, judged by when it was made
    final made = DateTime.tryParse('${_data?['generated_at'] ?? ''}')
        ?.toUtc()
        .add(const Duration(hours: 6));
    if (c['date'] == null &&
        made != null &&
        made.year == now.year &&
        made.month == now.month &&
        made.day == now.day) {
      return pick(worldMap(c['times']));
    }
    return null;
  }

  // homefeed: the server's freshness limits (minutes), applied again on the
  // phone because a saved copy keeps ageing after it was saved.
  static const _freshMin = {
    'weather': 180,
    'currency': 36 * 60,
    'news_bd': 360,
    'news_world': 360,
    'cricket': 30,
    'football': 30,
  };
  static const _dropMin = {'weather': 24 * 60, 'cricket': 360, 'football': 360};

  bool _isStale(String id, Map<String, dynamic> c) {
    if (c['stale'] == true) return true;
    final age = uwAgeMin('${c['fetched_at'] ?? ''}');
    final lim = _freshMin[id];
    return age != null && lim != null && age > lim;
  }

  /// The cards / "not connected" lists as they are true NOW (a saved copy
  /// is re-judged: too-old weather or scores and other-day prayer times
  /// move to "not connected" with the honest reason).
  (Map<String, dynamic>, Map<String, dynamic>, Map<String, dynamic>)
      _effective(Map<String, dynamic> d) {
    final cards = Map<String, dynamic>.from(worldMap(d['cards']));
    final hidden = Map<String, dynamic>.from(worldMap(d['hidden']));
    final since = Map<String, dynamic>.from(worldMap(d['hidden_since']));
    // a fresh server copy is today's by definition; a saved one is re-judged
    if (cards['prayer'] != null && (_fromCache || _offline)) {
      final p = _prayerForToday(worldMap(cards['prayer']));
      if (p == null) {
        cards.remove('prayer');
        hidden['prayer'] = 'old_copy';
      } else {
        cards['prayer'] = p;
      }
    }
    for (final e in _dropMin.entries) {
      final c = worldMap(cards[e.key]);
      final at = '${c['fetched_at'] ?? ''}';
      final age = uwAgeMin(at);
      if (age != null && age > e.value) {
        cards.remove(e.key);
        hidden[e.key] = 'stale';
        since[e.key] = at;
      }
    }
    return (cards, hidden, since);
  }

  String _hiddenReason(AppLocalizations t, String why, String since) =>
      switch (why) {
        'needs_key' => t.uwNoLicensedSource,
        'not_entered' => t.uwOfficialNotEntered,
        'old_copy' => t.uwSavedCopyTooOld,
        'stale' when uwAgo(context, since).isNotEmpty =>
          t.uwSourceDownSince(uwAgo(context, since)),
        _ => t.uwSourceDownNow,
      };

  /// "The source isn't responding — last updated X ago" (red), shown only
  /// when the card's last good fetch is older than its limit.
  Widget _staleLine(AppLocalizations t, ColorScheme scheme, String id,
      Map<String, dynamic> c) {
    if (!_isStale(id, c)) return const SizedBox.shrink();
    final ago = uwAgo(context, '${c['fetched_at'] ?? ''}');
    return Padding(
      key: ValueKey('uw_stale_$id'),
      padding: const EdgeInsets.only(top: Gap.xs),
      child: Text(
          ago.isEmpty ? t.uwSourceDownNow : t.uwSourceStaleAgo(ago),
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: scheme.error, fontWeight: FontWeight.w600)),
    );
  }

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
    final saved = await showAppSheet<bool>(
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
          icon: const Icon(Icons.tune_rounded),
        ),
      ]),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off_rounded,
                  tint: scheme.error,
                  title: t.loadFailed,
                  message: t.uwOffline,
                  action: DsButton.secondary(onPressed: _load, icon: Icons.refresh_rounded, label: t.retry),
                )
              : RefreshIndicator(
                  onRefresh: () => _load(byUser: true), child: _body(t, scheme)),
    );
  }

  Widget _body(AppLocalizations t, ColorScheme scheme) {
    final d = _data!;
    final (cards, hidden, since) = _effective(d);
    final city = worldMap(d['city']);
    final shown = _order.where(cards.containsKey).toList();
    final savedAgo = uwAgo(context, '${d['generated_at'] ?? ''}');
    final soon = _order
        .where((id) => hidden.containsKey(id) && !cards.containsKey(id))
        .toList();
    return ListView(
      // homefeed: pull to refresh works even when the cards fit the screen
      physics: const AlwaysScrollableScrollPhysics(),
      padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.xl)),
      children: [
        if (_fromCache || _offline) ...[
          KeyedSubtree(
            key: ValueKey(_offline ? 'uw_offline_copy' : 'uw_saved_copy'),
            child: UwNote(
                icon: _offline
                    ? Icons.offline_bolt_rounded
                    : Icons.history_rounded,
                text: savedAgo.isEmpty
                    ? t.uwCachedCopy
                    : _offline
                        ? t.uwOfflineCopyAgo(savedAgo)
                        : t.uwSavedCopyRefreshing(savedAgo)),
          ),
          const SizedBox(height: Gap.sm),
        ],
        if ('${city['name'] ?? ''}'.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.sm),
            child: Row(children: [
              Icon(Icons.place_rounded,
                  size: 18, color: scheme.ds.muted),
              const SizedBox(width: Gap.xs),
              Text('${city['name']}',
                  style: AType.bodyMedium.copyWith(color: scheme.ds.muted)),
            ]),
          ),
        if (shown.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Gap.xl),
            child: StateMessage(
                icon: Icons.dashboard_customize_rounded,
                title: t.uwNoCardsTitle,
                message: t.uwNoCardsBody),
          ),
        for (final id in shown)
          Padding(
            key: ValueKey('uw_card_$id'),
            padding: const EdgeInsets.only(bottom: Gap.md),
            child: DsSurface(flat: true, borderColor: Theme.of(context).colorScheme.ds.border,
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
        if (soon.isNotEmpty)
          DsSurface(flat: true, borderColor: Theme.of(context).colorScheme.ds.border,
            padding: const EdgeInsets.all(Gap.lg),
            child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(Icons.hourglass_top_rounded,
                          color: scheme.ds.muted),
                      const SizedBox(width: Gap.sm),
                      Expanded(
                          child: Text(t.uwNotConnectedTitle,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w700))),
                    ]),
                    const SizedBox(height: Gap.xs),
                    for (final id in soon)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: Gap.xs),
                        child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(_cardIcon(id),
                                  size: 20, color: scheme.ds.muted),
                              const SizedBox(width: Gap.sm),
                              Expanded(
                                  child: Text(
                                      '${_cardTitle(t, id)} — ${_hiddenReason(t, '${hidden[id]}', '${since[id] ?? ''}')}',
                                      style: AType.bodyMedium.copyWith(
                                          color: scheme.ds.muted,
                                          height: 1.35))),
                            ]),
                      ),
                  ]),
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
              style: AType.bodyMedium.copyWith(
                  fontWeight: strong ? FontWeight.w700 : FontWeight.w500)),
        ]),
      );

  Widget _cardBody(AppLocalizations t, ColorScheme scheme, String id,
      Map<String, dynamic> c) {
    final dg = (Object v) => uwDigits(context, v);
    switch (id) {
      case 'prayer':
        final pc = c; // already today's (see _effective)
        final times = worldMap(pc['times']);
        final next = '${pc['next'] ?? ''}';
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
          if ('${pc['date'] ?? ''}'.isNotEmpty)
            Text(
                t.uwPrayerForDate(
                    uwWhen(context, '${pc['date']}', time: false)),
                key: const ValueKey('uw_prayer_date'),
                style: Theme.of(context).textTheme.bodySmall),
          Text('${pc['note'] ?? ''}',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.ds.muted)),
        ]);
      case 'weather':
        final next = worldList(c['next']);
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('${dg((c['temp'] as num?)?.round() ?? '')}°',
                style: AFonts.figures(Theme.of(context).textTheme.displaySmall)),
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
                    style: AFonts.figures(Theme.of(context).textTheme.bodySmall)),
            ]),
          ],
          UwSourceLine(
              source: '${c['source']}',
              url: '${c['source_url'] ?? ''}',
              // homefeed: when OUR server last got it (the as-of a user needs)
              updated: '${c['fetched_at'] ?? c['updated'] ?? ''}'),
          _staleLine(t, scheme, id, c),
        ]);
      case 'currency':
        final off = worldMap(c['official']);
        final rows = worldList(c['rows']);
        final small = Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(color: scheme.ds.muted);
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (off.isNotEmpty) ...[
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Expanded(
                  child: Text(t.uwFxOfficialUsd,
                      style: Theme.of(context).textTheme.titleSmall)),
              const SizedBox(width: Gap.sm),
              Text('৳${dg((off['bdt'] as num?)?.toStringAsFixed(2) ?? '')}',
                  style:
                      AFonts.figures(Theme.of(context).textTheme.headlineSmall)),
            ]),
            const SizedBox(height: Gap.xxs),
            Wrap(spacing: Gap.sm, runSpacing: Gap.xxs, children: [
              Chip(
                visualDensity: VisualDensity.compact,
                avatar: Icon(Icons.verified_rounded,
                    size: 16, color: scheme.primary),
                label: Text(t.uwOfficialBadge),
              ),
              Text(
                  t.uwRateDate(
                      uwWhen(context, '${off['date'] ?? ''}', time: false)),
                  style: small),
            ]),
            if (off['stale'] == true)
              Padding(
                padding: const EdgeInsets.only(top: Gap.xxs),
                child: Text(t.uwFxOfficialStale,
                    style: small?.copyWith(color: scheme.error)),
              ),
            UwSourceLine(
                source: '${off['source']}', url: '${off['source_url'] ?? ''}'),
            if (rows.isNotEmpty) ...[
              const Divider(height: Gap.xl),
              Text(t.uwFxIndicativeTitle, style: small),
              const SizedBox(height: Gap.xxs),
            ],
          ],
          for (final r in rows)
            _row('${r['name']} (${r['code']})', '৳${dg(r['bdt'])}'),
          if (rows.isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            Text('${c['note'] ?? ''}', style: small),
            UwSourceLine(
                source: '${c['source']}',
                url: '${c['source_url'] ?? ''}',
                updated: '${c['updated'] ?? ''}'),
            _staleLine(t, scheme, id, c),
          ],
        ]);
      case 'notices':
        final links = worldList(c['links']);
        final groups = <String, String>{
          'power': t.uwNoticeGroupPower,
          'weather': t.uwNoticeGroupWeather,
          'money': t.uwNoticeGroupMoney,
        };
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final g in groups.keys)
            if (links.any((l) => l['group'] == g)) ...[
              Padding(
                padding: const EdgeInsets.only(top: Gap.sm),
                child: Text(groups[g]!,
                    style: Theme.of(context)
                        .textTheme
                        .labelLarge
                        ?.copyWith(color: scheme.primary)),
              ),
              for (final l in links.where((l) => l['group'] == g))
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  minTileHeight: 48,
                  dense: false,
                  title: Text('${l['label']}'),
                  trailing: const Icon(Icons.open_in_new_rounded, size: 20),
                  onTap: () => uwOpen(context, '${l['url']}'),
                ),
            ],
          const SizedBox(height: Gap.xs),
          Text(t.uwNoticesNote,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.ds.muted)),
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
                  ?.copyWith(color: scheme.ds.muted)),
          if (c['stale'] == true ||
              (uwAgeMin('${c['updated'] ?? ''}') ?? 0) >
                  (id == 'gold' ? 7 : 35) * 24 * 60 + 24 * 60)
            Padding(
              key: ValueKey('uw_stale_$id'),
              padding: const EdgeInsets.only(top: Gap.xs),
              child: Text(
                  t.uwPriceMayHaveChanged(
                      uwAgo(context, '${c['updated'] ?? ''}')),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.error, fontWeight: FontWeight.w600)),
            ),
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
                          style: AType.bodyMedium.copyWith(
                              fontWeight: FontWeight.w600, height: 1.35)),
                      if ('${it['snippet'] ?? ''}'.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: Gap.xxs),
                          child: Text('${it['snippet']}',
                              style: AType.bodyMedium.copyWith(
                                  color: scheme.ds.muted,
                                  height: 1.35)),
                        ),
                      const SizedBox(height: Gap.xxs),
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
                  ?.copyWith(color: scheme.ds.muted)),
          _staleLine(t, scheme, id, c),
        ]);
      default:
        final m = worldList(c['matches']);
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (m.isEmpty) Text(t.uwNoLiveMatches),
          for (final x in m)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Gap.xs),
              child: id == 'cricket'
                  ? Text('${x['name']}\n${dg(x['score'] ?? '')}  ${x['status']}')
                  : Text(
                      '${x['home']} ${dg(x['score'] ?? '')} ${x['away']}  (${x['league']})'),
            ),
          UwSourceLine(
              source: '${c['source']}', updated: '${c['updated'] ?? ''}'),
          _staleLine(t, scheme, id, c),
        ]);
    }
  }
}
