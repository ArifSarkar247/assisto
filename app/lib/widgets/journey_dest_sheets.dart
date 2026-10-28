import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'app_sheet.dart';
import 'journey_api.dart';
import 'journey_ride.dart';

/// journey2 — the destination sheets of the Safe Journey start form:
///  * paste a Google Maps link (long or maps.app.goo.gl) or "23.78, 90.41";
///  * search a place by name (only offered when the server has a geocoder);
///  * save a place as Home / School / Office / other.
/// Every sheet returns plain data; nothing is invented when a lookup fails.

typedef JourneyDest = ({String name, double lat, double lng});

Future<JourneyDest?> showJourneyLinkSheet(BuildContext context, ApiClient api) {
  return showAppSheet<JourneyDest>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _LinkSheet(api: api),
  );
}

class _LinkSheet extends StatefulWidget {
  final ApiClient api;
  const _LinkSheet({required this.api});
  @override
  State<_LinkSheet> createState() => _LinkSheetState();
}

class _LinkSheetState extends State<_LinkSheet> {
  final _ctl = TextEditingController();
  bool _busy = false;
  String? _err;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    try {
      final d = await Clipboard.getData(Clipboard.kTextPlain);
      final s = d?.text?.trim() ?? '';
      if (s.isNotEmpty) setState(() => _ctl.text = s);
    } catch (_) {
      // best-effort: no clipboard access — the field stays typeable
    }
  }

  Future<void> _use() async {
    final t = AppLocalizations.of(context);
    final text = _ctl.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      final r = await widget.api.journeyParseLink(text);
      final lat = (r['lat'] as num?)?.toDouble(), lng = (r['lng'] as num?)?.toDouble();
      if (lat == null || lng == null) throw StateError('no coords');
      if (!mounted) return;
      Navigator.pop<JourneyDest>(
          context, (name: '${r['name'] ?? ''}'.trim(), lat: lat, lng: lng));
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _err = e.status == 400 ? t.j2PasteLinkBad : t.grpActionFailed;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _err = t.grpActionFailed;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Text(t.j2PasteLinkTitle,
              style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.xs),
          Text(t.j2PasteLinkHint, style: AType.bodyMedium.copyWith(color: cs.onSurfaceVariant)),
          const SizedBox(height: Gap.md),
          TextField(
            key: const ValueKey('j2_link_field'),
            controller: _ctl,
            minLines: 1,
            maxLines: 3,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: t.j2PasteLinkField,
              errorText: _err,
              errorMaxLines: 4,
              suffixIcon: IconButton(
                  tooltip: t.j2Paste,
                  icon: const Icon(Icons.content_paste_rounded),
                  onPressed: _paste),
            ),
            onSubmitted: (_) => _use(),
          ),
          const SizedBox(height: Gap.md),
          FilledButton.icon(
            key: const ValueKey('j2_link_use'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: _busy ? null : _use,
            icon: _busy
                ? const SizedBox(
                    width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.check_rounded),
            label: Text(t.j2PasteLinkUse),
          ),
        ]),
      ),
    );
  }
}

Future<JourneyDest?> showJourneySearchSheet(BuildContext context, ApiClient api,
    {double? lat, double? lng}) {
  return showAppSheet<JourneyDest>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _SearchSheet(api: api, lat: lat, lng: lng),
  );
}

class _SearchSheet extends StatefulWidget {
  final ApiClient api;
  final double? lat, lng;
  const _SearchSheet({required this.api, this.lat, this.lng});
  @override
  State<_SearchSheet> createState() => _SearchSheetState();
}

class _SearchSheetState extends State<_SearchSheet> {
  final _ctl = TextEditingController();
  List<Map<String, dynamic>> _rows = [];
  bool _busy = false;
  String? _msg;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final t = AppLocalizations.of(context);
    final q = _ctl.text.trim();
    if (q.length < 2) return;
    setState(() {
      _busy = true;
      _msg = null;
    });
    try {
      final r = await widget.api.journeyGeocode(q, lat: widget.lat, lng: widget.lng);
      final rows = ((r['results'] ?? const []) as List)
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .where((m) => m['lat'] is num && m['lng'] is num)
          .toList();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _rows = rows;
        _msg = r['state'] == 'failed'
            ? t.j2SearchFailed
            : (rows.isEmpty ? t.j2SearchNone : null);
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

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          TextField(
            key: const ValueKey('j2_search_field'),
            controller: _ctl,
            autofocus: true,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              labelText: t.j2SearchField,
              suffixIcon: IconButton(
                  tooltip: t.j2Search,
                  icon: const Icon(Icons.search_rounded),
                  onPressed: _busy ? null : _search),
            ),
            onSubmitted: (_) => _search(),
          ),
          if (_busy)
            const Padding(
                padding: EdgeInsets.all(Gap.md),
                child: Center(child: CircularProgressIndicator())),
          if (_msg != null)
            Padding(
              padding: const EdgeInsets.only(top: Gap.md),
              child: Text(_msg!, style: AType.bodyMedium.copyWith(color: cs.onSurfaceVariant)),
            ),
          Flexible(
            child: ListView(shrinkWrap: true, children: [
              for (final r in _rows)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.place_rounded),
                  title: Text('${r['name'] ?? ''}'),
                  subtitle: '${r['address'] ?? ''}'.isEmpty ? null : Text('${r['address']}'),
                  onTap: () => Navigator.pop<JourneyDest>(context, (
                    name: '${r['name'] ?? ''}',
                    lat: (r['lat'] as num).toDouble(),
                    lng: (r['lng'] as num).toDouble(),
                  )),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Save the current pin as Home / School / Office / other. Returns
/// (kind, name) or null.
Future<({String kind, String name})?> showJourneySavePlaceSheet(BuildContext context,
    {String kind = 'home', String name = ''}) {
  return showAppSheet<({String kind, String name})>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _SaveSheet(kind: kind, name: name),
  );
}

class _SaveSheet extends StatefulWidget {
  final String kind, name;
  const _SaveSheet({required this.kind, required this.name});
  @override
  State<_SaveSheet> createState() => _SaveSheetState();
}

class _SaveSheetState extends State<_SaveSheet> {
  late String _kind = widget.kind;
  late final _ctl = TextEditingController(text: widget.name);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Text(t.j2SavePlaceTitle, style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
            for (final k in const ['home', 'school', 'office', 'other'])
              ChoiceChip(
                key: ValueKey('j2_kind_$k'),
                avatar: Icon(jPlaceIcon(k), size: 18),
                label: Text(jKindLabel(t, k)),
                selected: _kind == k,
                onSelected: (_) => setState(() => _kind = k),
              ),
          ]),
          const SizedBox(height: Gap.md),
          TextField(
            key: const ValueKey('j2_place_name'),
            controller: _ctl,
            maxLength: 60,
            decoration: InputDecoration(labelText: t.j2SavePlaceName),
          ),
          const SizedBox(height: Gap.sm),
          FilledButton.icon(
            key: const ValueKey('j2_place_save'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            icon: const Icon(Icons.bookmark_add_rounded),
            label: Text(t.j2SavePlace),
            onPressed: () => Navigator.pop<({String kind, String name})>(
                context, (kind: _kind, name: _ctl.text.trim())),
          ),
        ]),
      ),
    );
  }
}

/// Ride details during the trip (the Pathao/Uber driver is often known only
/// once the ride starts). Returns the edited map or null.
Future<Map<String, dynamic>?> showJourneyRideSheet(BuildContext context,
    Map<String, dynamic> initial) {
  return showAppSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _RideSheet(initial: initial),
  );
}

class _RideSheet extends StatefulWidget {
  final Map<String, dynamic> initial;
  const _RideSheet({required this.initial});
  @override
  State<_RideSheet> createState() => _RideSheetState();
}

class _RideSheetState extends State<_RideSheet> {
  late String? _mode = kJourneyModes.contains(widget.initial['mode']) ? '${widget.initial['mode']}' : null;
  late String? _app = kRideApps.contains(widget.initial['app']) ? '${widget.initial['app']}' : null;
  late final _plate = TextEditingController(text: '${widget.initial['plate'] ?? ''}');
  late final _name = TextEditingController(text: '${widget.initial['driver_name'] ?? ''}');
  late final _phone = TextEditingController(text: '${widget.initial['driver_phone'] ?? ''}');

  @override
  void dispose() {
    _plate.dispose();
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Text(t.j2RideCardTitle, style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.sm),
          DropdownButtonFormField<String>(
            initialValue: _mode,
            isExpanded: true,
            decoration: InputDecoration(labelText: t.journeyModeLabel),
            items: [
              for (final m in kJourneyModes)
                DropdownMenuItem(value: m, child: Text(jModeLabel(t, m))),
            ],
            onChanged: (v) => setState(() => _mode = v),
          ),
          const SizedBox(height: Gap.sm),
          DropdownButtonFormField<String>(
            initialValue: _app,
            isExpanded: true,
            decoration: InputDecoration(labelText: t.j2AppLabel),
            items: [
              DropdownMenuItem<String>(value: null, child: Text(t.j2AppNone)),
              for (final a in kRideApps)
                DropdownMenuItem(value: a, child: Text(jAppLabel(t, a))),
            ],
            onChanged: (v) => setState(() => _app = v),
          ),
          const SizedBox(height: Gap.sm),
          TextField(
              key: const ValueKey('j2_ride_plate'),
              controller: _plate,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(labelText: t.journeyPlateLabel)),
          const SizedBox(height: Gap.sm),
          TextField(
              key: const ValueKey('j2_ride_driver'),
              controller: _name,
              decoration: InputDecoration(labelText: t.j2DriverName)),
          const SizedBox(height: Gap.sm),
          TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(labelText: t.j2DriverPhone)),
          const SizedBox(height: Gap.xs),
          Text(t.j2RideHint, style: AType.bodySmall.copyWith(color: cs.onSurfaceVariant)),
          const SizedBox(height: Gap.md),
          FilledButton.icon(
            key: const ValueKey('j2_ride_save'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            icon: const Icon(Icons.send_rounded),
            label: Text(t.j2RideShare),
            onPressed: () => Navigator.pop<Map<String, dynamic>>(context, {
              'mode': _mode ?? '',
              'app': _app ?? '',
              'plate': _plate.text.trim(),
              'driver_name': _name.text.trim(),
              'driver_phone': _phone.text.trim(),
            }),
          ),
        ]),
      ),
    );
  }
}
