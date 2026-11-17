// cityapp B11: ask by voice ("From here to New Market which bus", also in
// Bangla) — the shared voice input (VoiceMicButton,
// text goes into the box, never auto-sent), answered from OUR route data
// first: the places are looked up in city/search (stops, stations), and a
// bus name ("Bikolpo", "Raida") shows that route's stops.
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/material.dart';

import '../../api.dart';
import '../../city/city_api.dart';
import '../../city/city_widgets.dart';
import '../../l10n/app_localizations.dart';
import '../../maps/place_search.dart' show PlacePick, showPlaceSearchSheet;
import '../../theme.dart';
import '../../widgets/app_sheet.dart' show showAppSheet;
import '../../widgets/local_counter.dart';
import '../../widgets/voice_input.dart' show VoiceDictation, VoiceMicButton;

typedef CityAsk = ({PlacePick? from, PlacePick to});

/// What a sentence asks: from (null = here) and to. Pure.
@visibleForTesting
({String? from, String to})? parseCityAsk(String raw) {
  var s = raw.trim().replaceAll(RegExp(r'[?？।!.]+$'), '').trim();
  if (s.isEmpty) return null;
  // drop the question tail
  final tail = RegExp(
              r'\s*(which bus|what bus|by bus|how (do i|to) go|how to get( there)?|\u0995\u09CB\u09A8 \u09AC\u09BE\u09B8\u09C7?|\u0995\u09BF \u09AD\u09BE\u09AC\u09C7|\u0995\u09C0\u09AD\u09BE\u09AC\u09C7|\u0995\u09BF\u09AD\u09BE\u09AC\u09C7|\u0995\u09C7\u09AE\u09A8\u09C7|\u09AF\u09BE\u09AC|\u09AF\u09BE\u09AC\u09CB|\u09AF\u09BE\u0993\u09AF\u09BC\u09BE \u09AF\u09BE\u09AF\u09BC|\u09AF\u09BE\u0993\u09AF\u09BC\u09BE\u09B0 \u0989\u09AA\u09BE\u09AF\u09BC|\u09AF\u09C7\u09A4\u09C7 \u099A\u09BE\u0987|kon bus(e)?|ki bhabe|kibhabe|kivabe|ki vabe|kemne|kemone|jabo|jaabo|jaite chai|jete chai|jawa jay|jaoa jay|jabar upay|jawar upay)\s*$',
      caseSensitive: false);
  for (var i = 0; i < 4; i++) {
    final n = s.replaceAll(tail, '').trim();
    if (n == s) break;
    s = n;
  }
  bool isHere(String x) => RegExp(r'^(here|my location|current location|ekhan|ekhane|ekhan theke|amar location|\u098F\u0996\u09BE\u09A8|\u098F\u0996\u09BE\u09A8\u09C7|\u098F\u0996\u09BE\u09A8 \u09A5\u09C7\u0995\u09C7|\u0986\u09AE\u09BE\u09B0 \u0985\u09AC\u09B8\u09CD\u09A5\u09BE\u09A8)$',
          caseSensitive: false)
      .hasMatch(x.trim());
  final en = RegExp(r'^(?:go\s+)?from\s+(.+?)\s+to\s+(.+)$', caseSensitive: false).firstMatch(s);
  if (en != null) {
    final f = en.group(1)!.trim(), t = en.group(2)!.trim();
    return (from: isHere(f) ? null : f, to: t);
  }
  final en2 = RegExp(r'^(?:go\s+|going\s+)?to\s+(.+)$', caseSensitive: false).firstMatch(s);
  if (en2 != null) return (from: null, to: en2.group(1)!.trim());
  final bn = RegExp(r'^(.+?)\s*(?:\u09A5\u09C7\u0995\u09C7|\u09B9\u09A4\u09C7)\s+(.+?)(?:\s+\u09AA\u09B0\u09CD\u09AF\u09A8\u09CD\u09A4)?$').firstMatch(s) ??
      // gap-city: romanized Bangla ("Farmgate theke Motijheel jabo")
      RegExp(r'^(.+?)\s+(?:theke|thekey|hote|hoite)\s+(.+?)(?:\s+(?:porjonto|porjnto))?$', caseSensitive: false)
          .firstMatch(s);
  if (bn != null) {
    final f = bn.group(1)!.trim(), t = bn.group(2)!.trim();
    return (from: isHere(f) ? null : f, to: t);
  }
  return (from: null, to: s);
}

Future<CityAsk?> showCityVoiceAsk(BuildContext context,
        {required ApiClient api, required String city, ({double lat, double lon})? here}) =>
    showAppSheet<CityAsk>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _VoiceSheet(api: api, city: city, here: here),
    );

class _VoiceSheet extends StatefulWidget {
  final ApiClient api;
  final String city;
  final ({double lat, double lon})? here;
  const _VoiceSheet({required this.api, required this.city, this.here});
  @override
  State<_VoiceSheet> createState() => _VoiceSheetState();
}

class _VoiceSheetState extends State<_VoiceSheet> {
  final _c = TextEditingController();
  final _voice = VoiceDictation();
  bool _busy = false;
  String? _msg;
  List<Map<String, dynamic>> _routes = const [];

  /// gap-city: names our city data did not know -> the place the user picked
  /// in the full place search (same search as Safe Journey).
  final Map<String, PlacePick> _picked = {};
  String? _missing;

  @override
  void dispose() {
    _voice.dispose();
    _c.dispose();
    super.dispose();
  }

  Future<PlacePick?> _find(String name) async {
    final had = _picked[name];
    if (had != null) return had;
    final r = await widget.api.citySearch(widget.city, name);
    for (final s in (r['stops'] as List? ?? const [])) {
      if (s is Map && s['lat'] is num && s['lon'] is num) {
        final bn = cityBn(context);
        final n = bn && '${s['name_bn'] ?? ''}'.isNotEmpty ? '${s['name_bn']}' : '${s['name'] ?? name}';
        return (name: n, address: '', lat: (s['lat'] as num).toDouble(), lng: (s['lon'] as num).toDouble());
      }
    }
    if (mounted) {
      setState(() => _routes = [
            for (final x in (r['routes'] as List? ?? const []))
              if (x is Map) x.cast<String, dynamic>()
          ]);
    }
    return null;
  }

  Future<void> _ask() async {
    final t = AppLocalizations.of(context);
    final q = parseCityAsk(_c.text);
    if (q == null) return;
    setState(() {
      _busy = true;
      _msg = null;
      _missing = null;
      _routes = const [];
    });
    try {
      PlacePick? from;
      if (q.from != null) {
        from = await _find(q.from!);
        if (from == null) {
          if (mounted) {
            setState(() {
              _msg = t.cityVoiceNotFound(q.from!);
              _missing = q.from;
            });
          }
          return;
        }
      } else if (widget.here == null) {
        if (mounted) setState(() => _msg = t.cityVoiceNeedLocation);
        return;
      }
      final to = await _find(q.to);
      if (!mounted) return;
      if (to == null) {
        setState(() {
          _msg = _routes.isNotEmpty ? t.cityVoiceRoutesFound : t.cityVoiceNotFound(q.to);
          _missing = q.to;
        });
        return;
      }
      Navigator.pop<CityAsk>(context, (from: from, to: to));
    } catch (_) {
      if (mounted) setState(() => _msg = t.cityVoiceOffline);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _searchAll(String name) async {
    final h = widget.here;
    final p = await showPlaceSearchSheet(context, widget.api,
        lat: h?.lat, lng: h?.lon, currentLocation: false, initialQuery: name,
        fieldKey: const ValueKey('city_voice_place_field'));
    if (p == null || !mounted) return;
    _picked[name] = p;
    await _ask();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final bn = cityBn(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.lg + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.cityVoiceAsk, style: AType.titleLarge.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: Gap.xs),
          Text(t.cityVoiceExample),
          const SizedBox(height: Gap.sm),
          Row(children: [
            Expanded(
              child: TextField(
                key: const ValueKey('city_voice_field'),
                controller: _c,
                maxLength: 120,
                buildCounter: localCounter,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _ask(),
                decoration: InputDecoration(hintText: t.cityVoiceHint),
              ),
            ),
            VoiceMicButton(voice: _voice, input: _c),
          ]),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const ValueKey('city_voice_go'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
              onPressed: _busy ? null : _ask,
              icon: const Icon(Icons.search_rounded),
              label: Text(t.cityVoiceGo),
            ),
          ),
          if (_msg != null) ...[const SizedBox(height: Gap.sm), Text(cityD(context, _msg!))],
          if (_missing != null && !_busy)
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: OutlinedButton.icon(
                key: const ValueKey('city_voice_search_all'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => _searchAll(_missing!),
                icon: const Icon(Icons.travel_explore_rounded),
                label: Text(t.cityGSearchAll(_missing!)),
              ),
            ),
          for (final r in _routes.take(6))
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(cityModeIcon('${r['mode'] ?? 'bus'}')),
              title: Text(cityD(context,
                  bn && '${r['name_bn'] ?? ''}'.isNotEmpty ? '${r['name_bn']}' : '${r['name'] ?? r['ref'] ?? ''}')),
              subtitle: Text(cityD(context, '${r['from'] ?? ''} → ${r['to'] ?? ''}')),
              onTap: () => showCityRoute(context, widget.api, widget.city, '${r['id']}'),
            ),
        ]),
      ),
    );
  }
}

/// A route's full stop list (GET city/route/<id>).
Future<void> showCityRoute(BuildContext context, ApiClient api, String city, String id) async {
  final t = AppLocalizations.of(context);
  Map<String, dynamic>? r;
  try {
    r = await api.cityRoute(city, id);
  } catch (_) {
    r = null;
  }
  if (!context.mounted) return;
  final bn = cityBn(context);
  final stops = [for (final s in (r?['stops'] as List? ?? const [])) if (s is Map) s];
  await showAppSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (c) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      builder: (c, sc) => ListView(controller: sc, padding: const EdgeInsets.all(Gap.lg), children: [
        if (r == null)
          Text(t.cityVoiceOffline)
        else ...[
          Text(cityD(c, bn && '${r['name_bn'] ?? ''}'.isNotEmpty ? '${r['name_bn']}' : '${r['name'] ?? r['ref'] ?? ''}'),
              style: AType.titleLarge.copyWith(fontWeight: FontWeight.w800)),
          if ('${r['operator'] ?? ''}'.isNotEmpty) Text(cityD(c, '${r['operator']}')),
          const SizedBox(height: Gap.xs),
          CityStatusBadge('${r['status'] ?? ''}'),
          const SizedBox(height: Gap.sm),
          Text(cityD(c, t.cityStopsCount('${stops.length}')), style: AType.titleMedium),
          for (final s in stops)
            ListTile(
              dense: true,
              leading: const Icon(Icons.circle_outlined, size: 14),
              title: Text(cityD(c, bn && '${s['name_bn'] ?? ''}'.isNotEmpty ? '${s['name_bn']}' : '${s['name'] ?? ''}')),
            ),
        ],
      ]),
    ),
  );
}
