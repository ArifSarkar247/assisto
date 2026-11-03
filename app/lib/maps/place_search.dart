import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gm;

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../state.dart' show Settings;
import '../theme.dart';
import '../widgets/app_sheet.dart';
import '../widgets/journey_api.dart';
import '../widgets/journey_ride.dart' show jDistanceM;
import '../widgets/local_counter.dart';
import '../widgets/notif_models.dart' show notifLocalizeDigits;
import '../widgets/permission_reason.dart';
import 'address_resolver.dart';
import 'maps_api.dart';
import 'maps_sdk.dart';
import 'place_search_controller.dart';

/// jsearch (owner phone test 4 Nov 00:05) — ONE place search for the whole
/// app, like the Google Maps app's search box:
///  * before typing: Current location, Choose on map, saved places, recent
///    places;
///  * from 2 letters: live suggestions (300 ms debounce, stale answers
///    dropped, one session token per search) from OUR server's Places API
///    (New) Autocomplete — biased to the user's spot and Bangladesh, in the
///    app's language; each row = name + area line + distance;
///  * picking a row = ONE Place Details Essentials (ends the session) ->
///    [PlacePick] with the full address -> [PlaceConfirmCard].
/// Used by My Trip ("Where are you going?" + the Search a place sheet),
/// Destination Alarm, Child School and saved places. Maps cost rules stay:
/// server proxy only, caps + cache on the server, never a legacy endpoint
/// from the phone. SOS never uses this.

typedef PlacePick = ({String name, String address, double lat, double lng});

/// How this screen can search: live suggestions (our maps proxy is ready),
/// the older capped name search on the search key only, or no search.
enum PlaceSearchMode { live, legacy, off }

/// GET /maps/status + the older /journey/geocode probe -> what to offer.
/// Never throws (offline = off; saved places / map / link still work).
Future<PlaceSearchMode> placeSearchMode(ApiClient api) async {
  try {
    if ((await api.getJson('/maps/status'))['ready'] == true) return PlaceSearchMode.live;
  } catch (_) {} // best-effort: older server or offline
  try {
    if ((await api.journeyGeocode(''))['available'] == true) return PlaceSearchMode.legacy;
  } catch (_) {} // best-effort: offline
  return PlaceSearchMode.off;
}

/// Recent places — on this phone only (last 5 picked).
class PlaceRecents {
  static const key = 'place_search_recent_v1';
  static const max = 5;

  static Future<List<PlacePick>> load() async {
    try {
      final j = jsonDecode(await Settings.getString(key) ?? '[]');
      if (j is! List) return const [];
      return [
        for (final m in j.whereType<Map>())
          if (m['lat'] is num && m['lng'] is num)
            (
              name: '${m['name'] ?? ''}',
              address: '${m['address'] ?? ''}',
              lat: (m['lat'] as num).toDouble(),
              lng: (m['lng'] as num).toDouble()
            )
      ];
    } catch (_) {
      return const [];
    }
  }

  static Future<void> add(PlacePick p) async {
    final old = await load();
    final list = [
      p,
      ...old.where((o) => !(o.name == p.name && (o.lat - p.lat).abs() < 1e-5 && (o.lng - p.lng).abs() < 1e-5)),
    ].take(max);
    await Settings.setString(
        key,
        jsonEncode([
          for (final o in list) {'name': o.name, 'address': o.address, 'lat': o.lat, 'lng': o.lng}
        ]));
  }
}

/// "850 m" / "2.1 km" in the app's digits.
String placeDistanceText(BuildContext context, AppLocalizations t, num m) =>
    notifLocalizeDigits(
        context, m >= 1000 ? t.trKm((m / 1000).toStringAsFixed(1)) : t.trMetres(m.round().toString()));

/// The phone's own position for "Current location" (asks with the in-app
/// reason first). null when location is off / refused.
Future<({double lat, double lng})?> placeHereNow(BuildContext context) async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    if (!context.mounted) return null;
    final perm = await askLocationWithReason(context);
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return null;
    final p = await Geolocator.getCurrentPosition().timeout(const Duration(seconds: 10));
    return (lat: p.latitude, lng: p.longitude);
  } catch (_) {
    return null;
  }
}

/// The search box + its list. Inline (My Trip) or inside [showPlaceSearchSheet].
class PlaceSearchBox extends StatefulWidget {
  final ApiClient api;
  final PlaceSearchMode mode;
  final TextEditingController? controller;
  final Key fieldKey;
  final String? label;
  final double? nearLat, nearLng;
  final bool autofocus;

  /// Saved places shown before typing.
  final List<PlacePick> saved;

  /// "Current location" row (null = hidden).
  final Future<({double lat, double lng})?> Function()? onCurrent;

  /// "Choose on map" row (null = no map in this build / screen).
  final Future<({double lat, double lng})?> Function()? onMap;

  /// The pre-typing list shows only while the field has focus and is empty
  /// (inline) — or always when empty (sheet).
  final bool listWhenUnfocused;
  final ValueChanged<PlacePick> onPicked;
  final ValueChanged<String>? onTyped;
  final Widget? suffixIcon;

  const PlaceSearchBox({
    super.key,
    required this.api,
    required this.mode,
    required this.onPicked,
    this.controller,
    this.fieldKey = const ValueKey('ps_field'),
    this.label,
    this.nearLat,
    this.nearLng,
    this.autofocus = false,
    this.saved = const [],
    this.onCurrent,
    this.onMap,
    this.listWhenUnfocused = false,
    this.onTyped,
    this.suffixIcon,
  });

  @override
  State<PlaceSearchBox> createState() => _PlaceSearchBoxState();
}

class _PlaceSearchBoxState extends State<PlaceSearchBox> {
  late final TextEditingController _ctl = widget.controller ?? TextEditingController();
  final _focus = FocusNode();
  List<Map<String, dynamic>> _rows = [];
  List<PlacePick> _recent = const [];
  bool _busy = false;
  String? _msg;
  bool _google = false;
  late bool _legacy = widget.mode == PlaceSearchMode.legacy;
  late final PlaceSearchController _ps = PlaceSearchController(
    suggest: (q, session) =>
        widget.api.mapsAutocomplete(q, session, lat: widget.nearLat, lng: widget.nearLng),
    details: (id, session) => widget.api.mapsPlace(id, session),
    onView: _onView,
  );

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (mounted) setState(() {});
    });
    unawaited(PlaceRecents.load().then((r) {
      if (mounted) setState(() => _recent = r);
    }));
  }

  @override
  void dispose() {
    _ps.dispose();
    _focus.dispose();
    if (widget.controller == null) _ctl.dispose();
    super.dispose();
  }

  String? _stateMsg(AppLocalizations t, String st) => switch (st) {
        'none' => t.j2SearchNone,
        'failed' || 'bad_session' => t.j2SearchFailed,
        'off' => t.mapscSearchOff,
        'user_cap' || 'global_cap' || 'plan_cap' => t.mapscSearchCapped,
        _ => null,
      };

  void _onView(PlaceSearchView v) {
    if (!mounted) return;
    final t = AppLocalizations.of(context);
    if (v.state == 'legacy') {
      _legacy = true;
      setState(() => _busy = false);
      return;
    }
    setState(() {
      _busy = v.state == 'loading';
      _google = v.rows.isNotEmpty;
      _rows = v.rows;
      _msg = _stateMsg(t, v.state);
    });
  }

  void _changed(String text) {
    widget.onTyped?.call(text);
    if (text.trim().isEmpty && (_msg != null || _rows.isNotEmpty)) {
      setState(() {
        _msg = null;
        _rows = [];
      });
    }
    if (widget.mode == PlaceSearchMode.off || _legacy) {
      return; // older server: only on the search key (its search is costly)
    }
    _ps.onChanged(text);
  }

  Future<void> _submit() async {
    if (widget.mode == PlaceSearchMode.off) return;
    if (!_legacy) {
      await _ps.submit(_ctl.text);
      if (!_legacy) return;
    }
    await _legacySearch();
  }

  /// Older servers: GET /journey/geocode on the search key (capped there).
  Future<void> _legacySearch() async {
    final t = AppLocalizations.of(context);
    final q = _ctl.text.trim();
    if (q.length < PlaceSearchController.minChars) return;
    setState(() {
      _busy = true;
      _msg = null;
    });
    try {
      final r = await widget.api.journeyGeocode(q, lat: widget.nearLat, lng: widget.nearLng);
      final rows = ((r['results'] ?? const []) as List)
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .where((m) => m['lat'] is num && m['lng'] is num)
          .toList();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _rows = rows;
        _google = rows.isNotEmpty;
        _msg = r['state'] == 'failed'
            ? t.j2SearchFailed
            : (rows.isEmpty ? (_stateMsg(t, '${r['state']}') ?? t.j2SearchNone) : null);
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _rows = [];
          _msg = t.j2SearchFailed;
        });
      }
    }
  }

  void _done(PlacePick p) {
    unawaited(PlaceRecents.add(p));
    _ctl.text = p.name;
    _focus.unfocus();
    setState(() {
      _rows = [];
      _msg = null;
      _google = false;
      _busy = false;
    });
    widget.onPicked(p);
  }

  Future<void> _pick(Map<String, dynamic> r) async {
    final name = '${r['name'] ?? ''}';
    if (r['lat'] is num && r['lng'] is num) {
      _done((
        name: name,
        address: '${r['address'] ?? r['secondary'] ?? ''}',
        lat: (r['lat'] as num).toDouble(),
        lng: (r['lng'] as num).toDouble()
      ));
      return;
    }
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    final got = await _ps.select('${r['place_id']}',
        error: (st) => _msg = _stateMsg(t, st) ?? t.j2SearchFailed);
    if (!mounted) return;
    if (got == null) {
      setState(() => _busy = false);
      return;
    }
    final area = '${r['secondary'] ?? ''}';
    _done((
      name: name,
      address: got.address.isNotEmpty ? got.address : (area.isNotEmpty ? '$name, $area' : name),
      lat: got.lat,
      lng: got.lng
    ));
  }

  /// Current location / map: the pin is exact; the address comes from the
  /// phone's free Geocoder first (our capped server only as fallback).
  Future<void> _fromPoint(Future<({double lat, double lng})?> Function() get, String name) async {
    final t = AppLocalizations.of(context);
    final lang = Localizations.localeOf(context).languageCode;
    final p = await get();
    if (p == null || !mounted) {
      if (mounted) setState(() => _msg = t.kwLocationUnavailable);
      return;
    }
    setState(() => _busy = true);
    final a = await AddressResolver.resolve(widget.api, p.lat, p.lng, lang: lang);
    if (!mounted) return;
    _done((name: name, address: a.text, lat: p.lat, lng: p.lng));
  }

  String? _distance(BuildContext context, AppLocalizations t, Map<String, dynamic> r) {
    final dm = r['distance_m'];
    if (dm is num) return placeDistanceText(context, t, dm);
    final lat = widget.nearLat, lng = widget.nearLng;
    if (lat != null && lng != null && r['lat'] is num && r['lng'] is num) {
      return placeDistanceText(context, t,
          jDistanceM(lat, lng, (r['lat'] as num).toDouble(), (r['lng'] as num).toDouble()));
    }
    return null;
  }

  Widget _tile(
      {required Key key,
      required IconData icon,
      required String title,
      String? subtitle,
      String? trailing,
      required VoidCallback? onTap}) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      key: key,
      contentPadding: EdgeInsets.zero,
      minTileHeight: 56,
      leading: CircleAvatar(
          radius: 18,
          backgroundColor: cs.surfaceContainerHighest,
          child: Icon(icon, size: 20, color: cs.onSurfaceVariant)),
      title: Text(title, style: AType.bodyLarge.copyWith(fontWeight: FontWeight.w600)),
      subtitle: subtitle == null || subtitle.isEmpty
          ? null
          : Text(subtitle, style: AType.bodySmall.copyWith(color: cs.onSurfaceVariant)),
      trailing: trailing == null
          ? null
          : Text(trailing, style: AType.bodySmall.copyWith(color: cs.onSurfaceVariant)),
      onTap: _busy ? null : onTap,
    );
  }

  List<Widget> _preTyping(AppLocalizations t) {
    final out = <Widget>[];
    if (widget.onCurrent != null) {
      out.add(_tile(
          key: const ValueKey('ps_current'),
          icon: Icons.my_location_rounded,
          title: t.journeyUseCurrent,
          onTap: () => _fromPoint(widget.onCurrent!, t.psHereName)));
    }
    if (widget.onMap != null) {
      out.add(_tile(
          key: const ValueKey('ps_map'),
          icon: Icons.map_rounded,
          title: t.j2PickMap,
          onTap: () => _fromPoint(widget.onMap!, t.journeyDestPinned)));
    }
    for (final (i, p) in widget.saved.indexed) {
      out.add(_tile(
          key: ValueKey('ps_saved_$i'),
          icon: Icons.bookmark_rounded,
          title: p.name,
          subtitle: p.address,
          onTap: () => _done(p)));
    }
    if (_recent.isNotEmpty) {
      out.add(Padding(
        padding: const EdgeInsets.only(top: Gap.sm),
        child: Text(t.psRecent, style: AType.labelLarge),
      ));
      for (final (i, p) in _recent.indexed) {
        out.add(_tile(
            key: ValueKey('ps_recent_$i'),
            icon: Icons.history_rounded,
            title: p.name,
            subtitle: p.address,
            onTap: () => _done(p)));
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final empty = _ctl.text.trim().isEmpty;
    final showPre = empty && (widget.listWhenUnfocused || _focus.hasFocus);
    final searching = widget.mode != PlaceSearchMode.off;
    // a tap on a suggestion counts as "inside" the field (the list must not
    // close under the finger)
    return TextFieldTapRegion(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      TextField(
        key: widget.fieldKey,
        controller: _ctl,
        focusNode: _focus,
        autofocus: widget.autofocus,
        maxLength: 120,
        buildCounter: localCounter,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          labelText: widget.label ?? t.j2SearchField,
          prefixIcon: const Icon(Icons.search_rounded),
          helperText: searching && _focus.hasFocus && empty ? t.psFieldHint : null,
          helperMaxLines: 2,
          suffixIcon: widget.suffixIcon,
        ),
        onChanged: _changed,
        onSubmitted: (_) => _submit(),
      ),
      if (_busy)
        const Padding(
            padding: EdgeInsets.all(Gap.sm), child: Center(child: CircularProgressIndicator())),
      if (_msg != null)
        Padding(
          padding: const EdgeInsets.only(top: Gap.xs),
          child: Text(_msg!,
              key: const ValueKey('mc_search_msg'),
              style: AType.bodyMedium.copyWith(color: cs.onSurfaceVariant)),
        ),
      if (showPre) ..._preTyping(t),
      if (!empty)
        for (final (i, r) in _rows.indexed)
          _tile(
              key: ValueKey('ps_row_$i'),
              icon: Icons.place_rounded,
              title: '${r['name'] ?? ''}',
              subtitle: '${r['secondary'] ?? r['address'] ?? ''}',
              trailing: _distance(context, t, r),
              onTap: () => _pick(r)),
      if (_google && !empty)
        Padding(
          padding: const EdgeInsets.only(top: Gap.xs),
          child: Text(t.mapscPoweredByGoogle,
              key: const ValueKey('mc_powered_google'),
              textAlign: TextAlign.end,
              style: AType.bodySmall.copyWith(color: cs.onSurfaceVariant)),
        ),
    ]));
  }
}

/// The picked place: full address, a pin on Google's map when this build
/// has the Maps SDK key (else no map — everything still works), Change.
class PlaceConfirmCard extends StatelessWidget {
  final PlacePick pick;
  final bool showMap;
  final String? title;
  final VoidCallback onChange;
  final String? useLabel;
  final VoidCallback? onUse;
  final List<Widget> extra;
  const PlaceConfirmCard(
      {super.key,
      required this.pick,
      required this.showMap,
      required this.onChange,
      this.title,
      this.useLabel,
      this.onUse,
      this.extra = const []});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final pos = gm.LatLng(pick.lat, pick.lng);
    return Container(
      key: const ValueKey('ps_confirm'),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
          color: Brand.successFill.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(Radii.md)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.where_to_vote_rounded, color: Brand.successFill),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(pick.name, style: AType.bodyLarge.copyWith(fontWeight: FontWeight.w700)),
              if (pick.address.isNotEmpty && pick.address != pick.name)
                Text(pick.address,
                    key: const ValueKey('ps_confirm_address'), style: AType.bodyMedium),
              if (title != null)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.xxs),
                  child: Text(title!, style: AType.bodySmall.copyWith(color: cs.onSurfaceVariant)),
                ),
            ]),
          ),
        ]),
        if (showMap) ...[
          const SizedBox(height: Gap.sm),
          ClipRRect(
            borderRadius: BorderRadius.circular(Radii.md),
            child: SizedBox(
              height: 150,
              child: gm.GoogleMap(
                key: const ValueKey('ps_confirm_map'),
                liteModeEnabled: true,
                initialCameraPosition: gm.CameraPosition(target: pos, zoom: 15),
                markers: {gm.Marker(markerId: const gm.MarkerId('dest'), position: pos)},
                myLocationButtonEnabled: false,
                mapToolbarEnabled: false,
                zoomControlsEnabled: false,
              ),
            ),
          ),
        ],
        ...extra,
        const SizedBox(height: Gap.sm),
        Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
          if (onUse != null)
            FilledButton.icon(
                key: const ValueKey('ps_use'),
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.check_rounded),
                label: Text(useLabel ?? t.psUse),
                onPressed: onUse),
          OutlinedButton.icon(
              key: const ValueKey('ps_change'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              icon: const Icon(Icons.edit_location_alt_rounded),
              label: Text(t.trChange),
              onPressed: onChange),
        ]),
      ]),
    );
  }
}

/// The search as a sheet: search -> confirm card -> "Use this place".
Future<PlacePick?> showPlaceSearchSheet(BuildContext context, ApiClient api,
    {double? lat,
    double? lng,
    PlaceSearchMode? mode,
    List<PlacePick> saved = const [],
    bool currentLocation = true,
    Future<({double lat, double lng})?> Function()? onMap,
    Key fieldKey = const ValueKey('j2_search_field')}) async {
  final m = mode ?? await placeSearchMode(api);
  final sdk = await MapsSdk.available();
  if (!context.mounted) return null;
  return showAppSheet<PlacePick>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _PlaceSheet(
        api: api,
        mode: m,
        sdk: sdk,
        lat: lat,
        lng: lng,
        saved: saved,
        currentLocation: currentLocation,
        onMap: onMap,
        fieldKey: fieldKey),
  );
}

class _PlaceSheet extends StatefulWidget {
  final ApiClient api;
  final PlaceSearchMode mode;
  final bool sdk, currentLocation;
  final double? lat, lng;
  final List<PlacePick> saved;
  final Future<({double lat, double lng})?> Function()? onMap;
  final Key fieldKey;
  const _PlaceSheet(
      {required this.api,
      required this.mode,
      required this.sdk,
      required this.saved,
      required this.currentLocation,
      required this.fieldKey,
      this.lat,
      this.lng,
      this.onMap});
  @override
  State<_PlaceSheet> createState() => _PlaceSheetState();
}

class _PlaceSheetState extends State<_PlaceSheet> {
  PlacePick? _picked;

  @override
  Widget build(BuildContext context) {
    final p = _picked;
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
            Gap.lg, Gap.lg, Gap.lg, Gap.lg + MediaQuery.viewInsetsOf(context).bottom),
        child: p != null
            ? PlaceConfirmCard(
                pick: p,
                showMap: widget.sdk,
                onUse: () => Navigator.pop<PlacePick>(context, p),
                onChange: () => setState(() => _picked = null))
            : PlaceSearchBox(
                api: widget.api,
                mode: widget.mode,
                fieldKey: widget.fieldKey,
                autofocus: true,
                listWhenUnfocused: true,
                nearLat: widget.lat,
                nearLng: widget.lng,
                saved: widget.saved,
                onCurrent: widget.currentLocation ? () => placeHereNow(context) : null,
                onMap: widget.onMap,
                onPicked: (pick) => setState(() => _picked = pick)),
      ),
    );
  }
}
