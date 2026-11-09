// mapapp (owner order 10 Nov 00:35 item 4, LEARN FROM TRIPS): after a City
// Service trip, ONE tap: "Which bus? What fare?". No name, no free text —
// the server keeps an anonymous key only (city/trips/confirm). The answer
// feeds our own data (ride confirmations per route, crowd fares) and shows
// the rider "You verified N stops".
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../services/bangla_calendar.dart' show asciiDigits;
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart' show showAppSheet;
import '../../widgets/local_counter.dart';
import '../city_models.dart';
import '../city_widgets.dart';
import 'city_map_data.dart';

/// The bus / leguna rides of a trip that can be confirmed (both stops known).
List<CityLeg> learnableRides(CityOption o) => [
      for (final l in o.legs)
        if ((l.mode == 'bus' || l.mode == 'leguna') &&
            (l.board?.id.isNotEmpty ?? false) &&
            (l.alight?.id.isNotEmpty ?? false))
          l
    ];

/// Fare quick picks: the fare range ends + the next round 5 above.
List<int> fareChoices(CityLeg l) {
  final f = l.fare;
  final out = <int>{};
  if (f != null && f.high > 0) {
    if (f.low > 0) out.add(f.low);
    out.add(f.high);
    out.add(((f.high + 5) / 5).ceil() * 5);
  }
  return out.toList()..sort();
}

/// Show the card. Returns the stops-verified count after a send (null =
/// skipped / nothing to ask).
Future<int?> showCityTripLearnCard(BuildContext context, {required CityOption option, String city = 'dhaka'}) {
  final rides = learnableRides(option);
  if (rides.isEmpty) return Future.value(null);
  return showAppSheet<int>(
    context: context,
    isScrollControlled: true,
    builder: (_) => CityTripLearnCard(rides: rides, city: city),
  );
}

class CityTripLearnCard extends StatefulWidget {
  final List<CityLeg> rides;
  final String city;
  const CityTripLearnCard({super.key, required this.rides, this.city = 'dhaka'});
  @override
  State<CityTripLearnCard> createState() => _CityTripLearnCardState();
}

class _CityTripLearnCardState extends State<CityTripLearnCard> {
  String? _route; // route id; '' = another bus
  int? _fare;
  bool _other = false, _sending = false, _failed = false;
  int? _verified;
  final _c = TextEditingController();

  CityLeg get _leg => widget.rides.firstWhere((l) => l.routeId == _route, orElse: () => widget.rides.first);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final api = context.read<AppState>().api;
    final leg = _leg;
    final typed = _other ? int.tryParse(asciiDigits(_c.text.trim())) : null;
    setState(() {
      _sending = true;
      _failed = false;
    });
    try {
      final r = await api.cityTripConfirm(
          city: widget.city,
          mode: leg.mode,
          routeId: _route ?? '',
          boardId: leg.board!.id,
          alightId: leg.alight!.id,
          paid: typed ?? _fare);
      if (!mounted) return;
      setState(() {
        _sending = false;
        _verified = (r['stops_verified'] as num?)?.toInt() ?? 0;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _sending = false;
          _failed = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    final bn = cityBn(context);
    final pad = EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.lg + MediaQuery.viewInsetsOf(context).bottom);
    if (_verified != null) {
      return Padding(
        key: const ValueKey('city_learn_done'),
        padding: pad,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.verified_rounded, size: 48, color: Brand.success),
          const SizedBox(height: Gap.sm),
          Text(t.cityLearnThanks, style: AType.titleLarge, textAlign: TextAlign.center),
          const SizedBox(height: Gap.xs),
          Text(cityD(context, t.cityLearnVerified('${_verified!}')),
              key: const ValueKey('city_learn_count'),
              style: AType.titleMedium.copyWith(fontWeight: FontWeight.w800, color: s.primary),
              textAlign: TextAlign.center),
          const SizedBox(height: Gap.md),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: const ValueKey('city_learn_close'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
              onPressed: () => Navigator.pop(context, _verified),
              child: Text(t.cityLearnDone),
            ),
          ),
        ]),
      );
    }
    final seen = <String>{};
    final routes = [for (final l in widget.rides) if (seen.add(l.routeId)) l];
    final fares = fareChoices(_leg);
    return SingleChildScrollView(
      key: const ValueKey('city_learn_card'),
      padding: pad,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t.cityLearnCardTitle, style: AType.titleLarge.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: Gap.xs),
        Text(t.cityLearnCardSub, style: AType.bodyMedium.copyWith(color: s.onSurfaceVariant)),
        const SizedBox(height: Gap.md),
        Text(t.cityLearnWhichBus, style: AType.titleSmall.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.xs),
        Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
          for (final l in routes)
            ChoiceChip(
              key: ValueKey('city_learn_bus_${l.routeId}'),
              materialTapTargetSize: MaterialTapTargetSize.padded,
              label: Text(bn && l.routeBn.isNotEmpty ? l.routeBn : l.route),
              selected: _route == l.routeId,
              onSelected: (_) => setState(() => _route = l.routeId),
            ),
          ChoiceChip(
            key: const ValueKey('city_learn_bus_other'),
            materialTapTargetSize: MaterialTapTargetSize.padded,
            label: Text(t.cityLearnOtherBus),
            selected: _route == '',
            onSelected: (_) => setState(() => _route = ''),
          ),
        ]),
        const SizedBox(height: Gap.md),
        Text(t.cityLearnWhatFare, style: AType.titleSmall.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.xs),
        Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
          for (final f in fares)
            ChoiceChip(
              key: ValueKey('city_learn_fare_$f'),
              materialTapTargetSize: MaterialTapTargetSize.padded,
              label: Text(cityTaka(context, f, f)),
              selected: !_other && _fare == f,
              onSelected: (_) => setState(() {
                _other = false;
                _fare = _fare == f ? null : f;
              }),
            ),
          ChoiceChip(
            key: const ValueKey('city_learn_fare_other'),
            materialTapTargetSize: MaterialTapTargetSize.padded,
            label: Text(t.cityLearnOtherFare),
            selected: _other,
            onSelected: (_) => setState(() => _other = !_other),
          ),
        ]),
        if (_other)
          TextField(
            key: const ValueKey('city_learn_fare_field'),
            controller: _c,
            keyboardType: TextInputType.number,
            maxLength: 4,
            buildCounter: localCounter,
            decoration: InputDecoration(prefixText: '৳ ', labelText: t.cityIPaidLabel),
          ),
        if (_failed) ...[
          const SizedBox(height: Gap.sm),
          Text(t.citySendFailed, style: AType.bodyMedium.copyWith(color: s.error)),
        ],
        const SizedBox(height: Gap.md),
        Row(children: [
          Expanded(
            child: TextButton(
              key: const ValueKey('city_learn_skip'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 52)),
              onPressed: () => Navigator.pop(context),
              child: Text(t.cityLearnSkip),
            ),
          ),
          const SizedBox(width: Gap.sm),
          Expanded(
            flex: 2,
            child: FilledButton(
              key: const ValueKey('city_learn_send'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
              onPressed: _route == null || _sending ? null : _send,
              child: _sending
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                  : Text(t.citySend),
            ),
          ),
        ]),
      ]),
    );
  }
}
