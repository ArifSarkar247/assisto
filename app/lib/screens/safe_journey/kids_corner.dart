import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api.dart';
import '../../kids_watch_api.dart';
import '../../l10n/app_localizations.dart';
import '../../maps/maps_api.dart' show mapsSearchUrl;
import '../../maps/place_search.dart';
import '../../services/action_feedback.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/journey_ride.dart' show jDigits;
import '../../widgets/local_counter.dart';
import '../../widgets/permission_reason.dart';
import 'package:assisto/safety/ad_block_context.dart' show AdBlockedState;

/// sjkids — Children Corner (Safe Journey v2, owner order 9 Nov 11:15).
/// Lives on each child's Child School card: the guardian's open question
/// ("Do you know where NAME is?"), where the child is now (place NAME only),
/// and the guardian-set places — SAFE places with time windows (school,
/// coaching, tuition, playground, relative's house) and WATCH places
/// (market, river, highway) that tell the guardians on entry. The rules run
/// on the server's school-plan pipeline (kids watch, tracker chip, the
/// child's phone) and fcbrain's on-phone fences — no Google cost.

const List<String> kKcSafeKinds = [
  'school', 'coaching', 'tuition', 'playground', 'relative', 'other'
];
const List<String> kKcWatchKinds = ['market', 'river', 'highway', 'watch_other'];
const int kKcMaxPlaces = 12;

bool kcIsWatch(String kind) => kKcWatchKinds.contains(kind);

IconData kcIcon(String kind) => switch (kind) {
      'school' => Icons.school_rounded,
      'coaching' => Icons.menu_book_rounded,
      'tuition' => Icons.edit_note_rounded,
      'playground' => Icons.sports_soccer_rounded,
      'relative' => Icons.family_restroom_rounded,
      'market' => Icons.storefront_rounded,
      'river' => Icons.water_rounded,
      'highway' => Icons.add_road_rounded,
      'watch_other' => Icons.visibility_rounded,
      'home' => Icons.home_rounded,
      _ => Icons.place_rounded,
    };

String kcKindLabel(AppLocalizations t, String kind) => switch (kind) {
      'school' => t.kcKindSchool,
      'coaching' => t.kcKindCoaching,
      'tuition' => t.kcKindTuition,
      'playground' => t.kcKindPlayground,
      'relative' => t.kcKindRelative,
      'market' => t.kcKindMarket,
      'river' => t.kcKindRiver,
      'highway' => t.kcKindHighway,
      'watch_other' => t.kcKindWatchOther,
      'home' => t.kcKindHome,
      _ => t.kcKindOther,
    };

/// The name a guardian gave, else the kind's label. Pure.
String kcPlaceName(AppLocalizations t, String kind, Object? name) {
  final n = '${name ?? ''}'.trim();
  return n.isNotEmpty ? n : kcKindLabel(t, kind);
}

/// The first window a new place of [kind] gets (the owner's examples:
/// school 8–1 Sun–Thu, coaching / tuition on chosen days). Pure.
Map<String, dynamic>? kcDefaultWindow(String kind) => switch (kind) {
      'school' => {'days': [6, 0, 1, 2, 3], 'start': '08:00', 'end': '13:00'},
      'coaching' || 'tuition' => {'days': [0, 2], 'start': '16:00', 'end': '18:00'},
      _ => null,
    };

/// Python weekday (Mon=0..Sun=6) -> MaterialLocalizations weekday index
/// (Sun=0..Sat=6). Pure.
int kcMaterialDay(int py) => (py + 1) % 7;

/// Bangladesh week order for the day chips: Sat, Sun, ... Fri (Python days).
const List<int> kKcWeek = [5, 6, 0, 1, 2, 3, 4];

String _hm(BuildContext c, String hhmm) {
  final p = hhmm.split(':');
  if (p.length != 2) return hhmm;
  final tod = TimeOfDay(hour: int.tryParse(p[0]) ?? 0, minute: int.tryParse(p[1]) ?? 0);
  return jDigits(c, MaterialLocalizations.of(c).formatTimeOfDay(tod));
}

/// "Sun, Tue · 4:00 PM–6:00 PM" in the screen's language and digits.
String kcWindowText(BuildContext c, Map w) {
  final ml = MaterialLocalizations.of(c);
  final days = ((w['days'] as List?) ?? const [])
      .whereType<num>()
      .map((d) => d.toInt())
      .toList();
  final ordered = [for (final d in kKcWeek) if (days.contains(d)) d];
  final dTxt = ordered.length == 7
      ? AppLocalizations.of(c).kcEveryDay
      : ordered.map((d) => ml.narrowWeekdays[kcMaterialDay(d)]).join(' ');
  return '$dTxt · ${_hm(c, '${w['start']}')}–${_hm(c, '${w['end']}')}';
}

String _clock(BuildContext c, Object? iso) {
  final d = DateTime.tryParse('${iso ?? ''}')?.toLocal();
  return d == null ? '—' : jDigits(c, TimeOfDay.fromDateTime(d).format(c));
}

/// The corner section on one child's plan card.
class KidsCornerSection extends StatefulWidget {
  final Map<String, dynamic> plan;
  final Future<void> Function() onChanged;
  const KidsCornerSection({super.key, required this.plan, required this.onChanged});

  @override
  State<KidsCornerSection> createState() => _KidsCornerSectionState();
}

class _KidsCornerSectionState extends State<KidsCornerSection> {
  bool _busy = false;

  ApiClient get _api => context.read<AppState>().api;

  Future<void> _answer(Map<String, dynamic> ask) async {
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      await _api.postJson('/school-mode/plans/${widget.plan['id']}/kc-answer',
          {'ask_id': '${ask['id']}', 'answer': 'ok'});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.kcAnswered)));
      await widget.onChanged();
    } catch (e) {
      if (mounted) showActionFailed(context, 'sjkids.answer', e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openMap(num lat, num lng) async {
    try {
      await launchUrl(Uri.parse(mapsSearchUrl(lat.toDouble(), lng.toDouble())),
          mode: LaunchMode.externalApplication);
    } catch (e) {
      if (mounted) showActionFailed(context, 'sjkids.map', e);
    }
  }

  Widget _ask(AppLocalizations t, Map<String, dynamic> a, String child) {
    final cs = Theme.of(context).colorScheme;
    final open = a['state'] == 'open';
    final place = kcPlaceName(t, '${a['place_kind'] ?? ''}', a['place_name']);
    final lat = a['lat'], lng = a['lng'];
    return Container(
      key: ValueKey('kc_ask_${a['id']}'),
      margin: const EdgeInsets.only(top: Gap.sm),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: open
            ? Color.alphaBlend(Brand.warning.withValues(alpha: 0.08), cs.ds.card) // designv2: AA
            : cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: open ? Brand.warnInk(context) : cs.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(open ? Icons.help_rounded : Icons.check_circle_rounded,
              color: open ? Brand.warnInk(context) : Brand.successFill),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(t.kcAskTitle(child),
                style: AType.titleSmall.copyWith(fontWeight: FontWeight.w700)),
          ),
        ]),
        const SizedBox(height: Gap.xs),
        Text(t.kcAskBody(place, _clock(context, a['out_since'] ?? a['at'])),
            style: AType.bodyMedium),
        if (!open)
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: Text(
                a['state'] == 'back_safe'
                    ? t.kcAskBackSafe
                    : t.kcAskAnswered('${a['by'] ?? ''}'.isEmpty ? '—' : '${a['by']}'),
                style: AType.bodySmall.copyWith(color: cs.onSurfaceVariant)),
          )
        else ...[
          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            FilledButton.icon(
              key: ValueKey('kc_ask_ok_${a['id']}'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              icon: const Icon(Icons.check_rounded),
              label: Text(t.kcAskOk),
              onPressed: _busy ? null : () => _answer(a),
            ),
            if (lat is num && lng is num)
              OutlinedButton.icon(
                key: ValueKey('kc_ask_map_${a['id']}'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.map_rounded),
                label: Text(t.kcAskMap),
                onPressed: () => _openMap(lat, lng),
              ),
          ]),
        ],
      ]),
    );
  }

  String _where(AppLocalizations t, Map<String, dynamic> kc) {
    final place = kcPlaceName(t, '${kc['place_kind'] ?? ''}', kc['place_name']);
    return switch ('${kc['where']}') {
      'safe' => t.kcWhereSafe(place, _clock(context, kc['since'])),
      'watch' => t.kcWhereWatch(place, _clock(context, kc['since'])),
      'outside' => t.kcWhereOutside(_clock(context, kc['since'])),
      _ => t.kcWhereUnknown,
    };
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final p = widget.plan;
    final kc = (p['kids_corner'] as Map?)?.cast<String, dynamic>() ?? const {};
    final cfg = (p['config'] as Map?)?.cast<String, dynamic>() ?? const {};
    final places = kwRows(cfg, 'kc_places');
    final asks = kwRows(kc, 'asks').reversed.toList();
    final mine = p['mine'] == true;
    final child = '${p['child_name'] ?? ''}';
    return Column(
      key: ValueKey('kc_section_${p['id']}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: Gap.lg),
        Row(children: [
          Icon(Icons.child_care_rounded, color: cs.primary),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(t.kcTitle,
                style: AType.titleSmall.copyWith(fontWeight: FontWeight.w700)),
          ),
        ]),
        for (final a in asks.where((a) => a['state'] == 'open')) _ask(t, a, child),
        if (p['accepted'] == true && places.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: Text(_where(t, kc),
                key: ValueKey('kc_where_${p['id']}'), style: AType.bodyMedium),
          ),
        if (places.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: Text(t.kcEmptyBody,
                style: AType.bodyMedium.copyWith(color: cs.onSurfaceVariant)),
          )
        else
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: Wrap(spacing: Gap.xs, runSpacing: Gap.xs, children: [
              for (final x in places)
                Chip(
                  avatar: Icon(kcIcon('${x['kind']}'),
                      size: 18,
                      color: kcIsWatch('${x['kind']}')
                          ? Brand.warnInk(context)
                          : Brand.successFill),
                  label: Text(kcPlaceName(t, '${x['kind']}', x['name'])),
                ),
            ]),
          ),
        for (final a in asks.where((a) => a['state'] != 'open').take(2)) _ask(t, a, child),
        const SizedBox(height: Gap.sm),
        if (mine)
          OutlinedButton.icon(
            key: ValueKey('kc_places_${p['id']}'),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            icon: Icon(places.isEmpty ? Icons.add_location_alt_rounded : Icons.edit_location_alt_rounded),
            label: Text(places.isEmpty ? t.kcAddPlace : t.kcManagePlaces),
            onPressed: () async {
              final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
                  builder: (_) => KidsPlacesScreen(plan: p)));
              if (changed == true) await widget.onChanged();
            },
          )
        else if (places.isEmpty)
          Text(t.kcOnlyOwner, style: AType.bodySmall.copyWith(color: cs.onSurfaceVariant)),
      ],
    );
  }
}

/// The guardian's list of a child's places (safe + watch), add / edit / remove.
class KidsPlacesScreen extends StatefulWidget {
  final Map<String, dynamic> plan;
  const KidsPlacesScreen({super.key, required this.plan});

  @override
  State<KidsPlacesScreen> createState() => _KidsPlacesScreenState();
}

class _KidsPlacesScreenState extends State<KidsPlacesScreen>
    with AdBlockedState<KidsPlacesScreen> {
  late List<Map<String, dynamic>> _places;
  bool _saving = false;
  bool _changed = false;

  ApiClient get _api => context.read<AppState>().api;

  @override
  void initState() {
    super.initState();
    final cfg = (widget.plan['config'] as Map?)?.cast<String, dynamic>() ?? const {};
    _places = [for (final p in kwRows(cfg, 'kc_places')) Map<String, dynamic>.from(p)];
  }

  Future<void> _save(List<Map<String, dynamic>> next) async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      final r = await _api.smUpdate((widget.plan['id'] as num).toInt(), {'kc_places': next});
      final cfg = ((r['plan'] as Map?)?['config'] as Map?)?.cast<String, dynamic>();
      if (!mounted) return;
      setState(() {
        _places = cfg == null ? next : kwRows(cfg, 'kc_places');
        _changed = true;
      });
      messenger.showSnackBar(SnackBar(content: Text(t.kcSaved)));
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(
          content: Text(e.message.contains('window') ? t.kcBadTime : t.kcSaveFailed)));
    } catch (e) {
      if (mounted) showActionFailed(context, 'sjkids.save', e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _edit([int? index]) async {
    final res = await showAppSheet<Object>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => KidsPlaceForm(place: index == null ? null : _places[index]),
    );
    if (res == null || !mounted) return;
    final next = [..._places];
    if (res == 'delete' && index != null) {
      next.removeAt(index);
    } else if (res is Map<String, dynamic>) {
      if (index == null) {
        next.add(res);
      } else {
        next[index] = res;
      }
    } else {
      return;
    }
    await _save(next);
  }

  Widget _tile(AppLocalizations t, int i) {
    final p = _places[i];
    final kind = '${p['kind']}';
    final wins = ((p['windows'] as List?) ?? const []).whereType<Map>().toList();
    final sub = kcIsWatch(kind)
        ? t.kcWatchSub
        : (wins.isEmpty ? t.kcAnyTime : wins.map((w) => kcWindowText(context, w)).join('\n'));
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: ListTile(
        key: ValueKey('kc_place_$i'),
        minVerticalPadding: Gap.md,
        leading: Icon(kcIcon(kind),
            color: kcIsWatch(kind) ? Brand.warnInk(context) : Brand.successFill),
        title: Text(kcPlaceName(t, kind, p['name'])),
        subtitle: Text(sub),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: _saving ? null : () => _edit(i),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final safe = [for (var i = 0; i < _places.length; i++) if (!kcIsWatch('${_places[i]['kind']}')) i];
    final watch = [for (var i = 0; i < _places.length; i++) if (kcIsWatch('${_places[i]['kind']}')) i];
    final child = '${widget.plan['child_name'] ?? ''}';
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        appBar: AppBar(title: Text(t.kcPlacesTitle(child))),
        body: ListView(
          padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
          children: [
            if (_places.isEmpty) ...[
              Icon(Icons.add_location_alt_rounded, size: 56, color: cs.primary),
              const SizedBox(height: Gap.md),
              Text(t.kcEmptyTitle,
                  textAlign: TextAlign.center,
                  style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: Gap.sm),
              Text(t.kcEmptyBody, textAlign: TextAlign.center, style: AType.bodyLarge),
              const SizedBox(height: Gap.sm),
              Text(t.kcEmptyHow,
                  textAlign: TextAlign.center,
                  style: AType.bodyMedium.copyWith(color: cs.onSurfaceVariant)),
              const SizedBox(height: Gap.md),
            ] else ...[
              Text(t.kcSafeHeader, style: AType.titleSmall.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: Gap.xs),
              if (safe.isEmpty)
                Text(t.kcNoneYet, style: AType.bodyMedium.copyWith(color: cs.onSurfaceVariant)),
              for (final i in safe) _tile(t, i),
              const SizedBox(height: Gap.md),
              Text(t.kcWatchHeader, style: AType.titleSmall.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: Gap.xs),
              if (watch.isEmpty)
                Text(t.kcNoneYet, style: AType.bodyMedium.copyWith(color: cs.onSurfaceVariant)),
              for (final i in watch) _tile(t, i),
              const SizedBox(height: Gap.md),
            ],
            FilledButton.icon(
              key: const ValueKey('kc_add'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              icon: _saving
                  ? const SizedBox(
                      width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.add_rounded),
              label: Text(t.kcAddPlace),
              onPressed: _saving || _places.length >= kKcMaxPlaces ? null : () => _edit(),
            ),
            const SizedBox(height: Gap.sm),
            Text(t.kcPrivacy, style: AType.bodySmall.copyWith(color: cs.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

/// Add / edit one place. Pops a place map, 'delete', or null.
class KidsPlaceForm extends StatefulWidget {
  final Map<String, dynamic>? place;
  const KidsPlaceForm({super.key, this.place});

  @override
  State<KidsPlaceForm> createState() => _KidsPlaceFormState();
}

class _KidsPlaceFormState extends State<KidsPlaceForm> {
  late String _kind;
  late final TextEditingController _name;
  double? _lat, _lng;
  String _where = '';
  bool _timed = false;
  Set<int> _days = {};
  TimeOfDay _from = const TimeOfDay(hour: 8, minute: 0);
  TimeOfDay _to = const TimeOfDay(hour: 13, minute: 0);
  String _error = '';
  List<Map<String, dynamic>> _saved = [];

  ApiClient get _api => context.read<AppState>().api;

  static TimeOfDay _tod(Object? s, TimeOfDay d) {
    final p = '${s ?? ''}'.split(':');
    if (p.length != 2) return d;
    return TimeOfDay(hour: int.tryParse(p[0]) ?? d.hour, minute: int.tryParse(p[1]) ?? d.minute);
  }

  static String _fmt(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  void initState() {
    super.initState();
    final p = widget.place;
    _kind = '${p?['kind'] ?? 'school'}';
    _name = TextEditingController(text: '${p?['name'] ?? ''}');
    if (p != null) {
      _lat = (p['lat'] as num?)?.toDouble();
      _lng = (p['lng'] as num?)?.toDouble();
      _where = '${p['name'] ?? ''}';
      final wins = ((p['windows'] as List?) ?? const []).whereType<Map>().toList();
      if (wins.isNotEmpty) {
        _timed = true;
        _days = {for (final d in (wins.first['days'] as List? ?? const [])) (d as num).toInt()};
        _from = _tod(wins.first['start'], _from);
        _to = _tod(wins.first['end'], _to);
      }
    } else {
      _applyDefault();
    }
    _loadSaved();
  }

  void _applyDefault() {
    final w = kcDefaultWindow(_kind);
    _timed = w != null;
    if (w != null) {
      _days = {...(w['days'] as List).cast<int>()};
      _from = _tod(w['start'], _from);
      _to = _tod(w['end'], _to);
    }
  }

  Future<void> _loadSaved() async {
    try {
      final r = await _api.smPlaces();
      if (mounted) setState(() => _saved = kwRows(r, 'places'));
    } catch (_) {}
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _pickLocation() async {
    final t = AppLocalizations.of(context);
    final pick = await showAppSheet<Map<String, dynamic>>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          ListTile(
            key: const ValueKey('kc_loc_here'),
            leading: const Icon(Icons.my_location_rounded),
            title: Text(t.kwUseHereNow),
            subtitle: Text(t.kwUseHereNowSub),
            onTap: () => Navigator.pop(ctx, {'here': true}),
          ),
          ListTile(
            key: const ValueKey('kc_loc_search'),
            leading: const Icon(Icons.travel_explore_rounded),
            title: Text(t.j2Search),
            onTap: () => Navigator.pop(ctx, {'search': true}),
          ),
          for (final p in _saved)
            ListTile(
              leading: const Icon(Icons.place_rounded),
              title: Text('${p['label'] ?? ''}'.isNotEmpty ? '${p['label']}' : '${p['name']}'),
              onTap: () => Navigator.pop(ctx, p),
            ),
        ]),
      ),
    );
    if (pick == null || !mounted) return;
    if (pick['search'] == true) {
      final p = await showPlaceSearchSheet(context, _api, currentLocation: false, saved: [
        for (final x in _saved)
          if (x['lat'] is num && x['lng'] is num)
            (
              name: '${x['label'] ?? ''}'.isNotEmpty ? '${x['label']}' : '${x['name'] ?? ''}',
              address: '',
              lat: (x['lat'] as num).toDouble(),
              lng: (x['lng'] as num).toDouble()
            )
      ]);
      if (p == null || !mounted) return;
      setState(() {
        _lat = p.lat;
        _lng = p.lng;
        _where = p.name;
        _error = '';
      });
    } else if (pick['here'] == true) {
      Position? pos;
      try {
        if (await Geolocator.isLocationServiceEnabled() && mounted) {
          final perm = await askLocationWithReason(context);
          if (perm != LocationPermission.denied && perm != LocationPermission.deniedForever) {
            pos = await Geolocator.getCurrentPosition().timeout(const Duration(seconds: 10));
          }
        }
      } catch (_) {
        // best-effort: pos stays null and the form shows "location unavailable"
      }
      if (!mounted) return;
      setState(() {
        if (pos == null) {
          _error = t.kwLocationUnavailable;
        } else {
          _lat = pos.latitude;
          _lng = pos.longitude;
          _where = t.kcHereNow;
          _error = '';
        }
      });
    } else if (pick['lat'] is num && pick['lng'] is num) {
      setState(() {
        _lat = (pick['lat'] as num).toDouble();
        _lng = (pick['lng'] as num).toDouble();
        _where = '${pick['label'] ?? ''}'.isNotEmpty ? '${pick['label']}' : '${pick['name'] ?? ''}';
        _error = '';
      });
    }
  }

  Future<void> _time(bool from) async {
    final v = await showTimePicker(context: context, initialTime: from ? _from : _to);
    if (v == null || !mounted) return;
    setState(() {
      if (from) {
        _from = v;
      } else {
        _to = v;
      }
    });
  }

  void _done() {
    final t = AppLocalizations.of(context);
    if (_lat == null || _lng == null) {
      setState(() => _error = t.kcNeedLocation);
      return;
    }
    final watch = kcIsWatch(_kind);
    if (!watch && _timed) {
      if (_days.isEmpty) {
        setState(() => _error = t.kcNeedDays);
        return;
      }
      if (_to.hour * 60 + _to.minute <= _from.hour * 60 + _from.minute) {
        setState(() => _error = t.kcBadTime);
        return;
      }
    }
    Navigator.of(context).pop(<String, dynamic>{
      if (widget.place?['id'] != null) 'id': widget.place!['id'],
      'kind': _kind,
      'name': _name.text.trim(),
      'lat': _lat,
      'lng': _lng,
      if (widget.place?['radius_m'] != null && widget.place?['kind'] == _kind)
        'radius_m': widget.place!['radius_m'],
      'windows': [
        if (!watch && _timed)
          {'days': (_days.toList()..sort()), 'start': _fmt(_from), 'end': _fmt(_to)}
      ],
    });
  }

  Widget _kindChips(AppLocalizations t, List<String> kinds) => Wrap(
        spacing: Gap.xs,
        runSpacing: Gap.xs,
        children: [
          for (final k in kinds)
            ChoiceChip(
              key: ValueKey('kc_kind_$k'),
              avatar: Icon(kcIcon(k), size: 18),
              label: Text(kcKindLabel(t, k)),
              selected: _kind == k,
              onSelected: (_) => setState(() {
                final wasTimed = kcDefaultWindow(_kind) != null;
                _kind = k;
                if (widget.place == null || wasTimed != (kcDefaultWindow(k) != null)) {
                  _applyDefault();
                }
              }),
            ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final ml = MaterialLocalizations.of(context);
    final watch = kcIsWatch(_kind);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(widget.place == null ? t.kcAddPlace : t.kcEditPlace,
              style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.md),
          Text(t.kcSafeHeader, style: AType.labelLarge),
          const SizedBox(height: Gap.xs),
          _kindChips(t, kKcSafeKinds),
          const SizedBox(height: Gap.sm),
          Text(t.kcWatchHeader, style: AType.labelLarge),
          const SizedBox(height: Gap.xs),
          _kindChips(t, kKcWatchKinds),
          const SizedBox(height: Gap.md),
          TextField(
            key: const ValueKey('kc_name'),
            controller: _name,
            maxLength: 40,
            buildCounter: localCounter,
            decoration: InputDecoration(
                labelText: t.kcName, hintText: kcKindLabel(t, _kind),
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.xs),
          OutlinedButton.icon(
            key: const ValueKey('kc_pick_loc'),
            style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(52), alignment: Alignment.centerLeft),
            icon: Icon(_lat == null ? Icons.add_location_rounded : Icons.check_circle_rounded,
                color: _lat == null ? null : Brand.successFill),
            label: Text(_lat == null ? t.kcPickLocation : t.kcLocationSet(_where.isEmpty ? '✓' : _where),
                maxLines: 2, overflow: TextOverflow.ellipsis),
            onPressed: _pickLocation,
          ),
          const SizedBox(height: Gap.md),
          if (watch)
            Text(t.kcWatchExplain, style: AType.bodyMedium.copyWith(color: cs.onSurfaceVariant))
          else ...[
            SwitchListTile(
              key: const ValueKey('kc_timed'),
              contentPadding: EdgeInsets.zero,
              title: Text(t.kcTimesToggle),
              subtitle: Text(_timed ? t.kcTimesOnSub : t.kcAnyTime),
              value: _timed,
              onChanged: (v) => setState(() {
                _timed = v;
                if (v && _days.isEmpty) _days = {6, 0, 1, 2, 3};
              }),
            ),
            if (_timed) ...[
              Wrap(spacing: Gap.xs, runSpacing: Gap.xs, children: [
                for (final d in kKcWeek)
                  FilterChip(
                    key: ValueKey('kc_day_$d'),
                    label: Text(ml.narrowWeekdays[kcMaterialDay(d)]),
                    tooltip: ml.narrowWeekdays[kcMaterialDay(d)],
                    selected: _days.contains(d),
                    onSelected: (v) => setState(() {
                      if (v) {
                        _days.add(d);
                      } else {
                        _days.remove(d);
                      }
                    }),
                  ),
              ]),
              const SizedBox(height: Gap.sm),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    key: const ValueKey('kc_from'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                    onPressed: () => _time(true),
                    child: Text('${t.kcFrom} ${_hm(context, _fmt(_from))}'),
                  ),
                ),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: OutlinedButton(
                    key: const ValueKey('kc_to'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                    onPressed: () => _time(false),
                    child: Text('${t.kcTo} ${_hm(context, _fmt(_to))}'),
                  ),
                ),
              ]),
              const SizedBox(height: Gap.xs),
              Text(t.kcTimesExplain,
                  style: AType.bodySmall.copyWith(color: cs.onSurfaceVariant)),
            ],
          ],
          if (_error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Gap.sm),
              child: Text(_error,
                  key: const ValueKey('kc_error'),
                  style: AType.bodyMedium.copyWith(color: cs.error)),
            ),
          const SizedBox(height: Gap.md),
          FilledButton(
            key: const ValueKey('kc_save'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: _done,
            child: Text(t.kcSave),
          ),
          if (widget.place != null) ...[
            const SizedBox(height: Gap.sm),
            TextButton.icon(
              key: const ValueKey('kc_delete'),
              style: TextButton.styleFrom(
                  minimumSize: const Size.fromHeight(48), foregroundColor: cs.error),
              icon: const Icon(Icons.delete_outline_rounded),
              label: Text(t.kcDelete),
              onPressed: () => Navigator.of(context).pop('delete'),
            ),
          ],
        ]),
      ),
    );
  }
}
