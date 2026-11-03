// nearby (owner 3 Nov 18:50): the emergency numbers of the country the
// phone is in — one big call button for the main number, the rest as rows.
// Works with no location and no network (numbers are bundled). Never ads.
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/action_feedback.dart';
import '../theme.dart';
import '../widgets/money_digits.dart' show toBanglaDigits;
import 'emergency_numbers.dart';

String emergencyKindLabel(AppLocalizations t, EmergencyKind k) => switch (k) {
      EmergencyKind.all => t.nearbyNumAll,
      EmergencyKind.police => t.nearbyNumPolice,
      EmergencyKind.ambulance => t.nearbyNumAmbulance,
      EmergencyKind.fire => t.nearbyNumFire,
      EmergencyKind.ambulanceFire => t.nearbyNumAmbulanceFire,
      EmergencyKind.civilDefence => t.nearbyNumCivilDefence,
      EmergencyKind.womenChild => t.nearbyNumWomenChild,
      EmergencyKind.child => t.nearbyNumChild,
      EmergencyKind.womenFamily => t.nearbyNumWomenFamily,
      EmergencyKind.health => t.nearbyNumHealth,
      EmergencyKind.healthNonEmergency => t.nearbyNumHealthNonEmergency,
      EmergencyKind.policeNonEmergency => t.nearbyNumPoliceNonEmergency,
      EmergencyKind.crisis => t.nearbyNumCrisis,
    };

String emergencyCountryName(AppLocalizations t, String cc) => switch (cc) {
      'BD' => t.nearbyCountryBD,
      'SA' => t.nearbyCountrySA,
      'AE' => t.nearbyCountryAE,
      'MY' => t.nearbyCountryMY,
      'QA' => t.nearbyCountryQA,
      'OM' => t.nearbyCountryOM,
      'KW' => t.nearbyCountryKW,
      'SG' => t.nearbyCountrySG,
      'IT' => t.nearbyCountryIT,
      'GB' => t.nearbyCountryGB,
      'US' => t.nearbyCountryUS,
      _ => cc,
    };

class EmergencyNumbersCard extends StatelessWidget {
  final CountryEmergency data;
  final bool bn;
  const EmergencyNumbersCard({super.key, required this.data, required this.bn});

  String _d(String s) => bn ? toBanglaDigits(s) : s;

  Future<void> _call(BuildContext context, EmergencyNumber n) =>
      openForUser(context, Uri.parse('tel:${n.dial}'), where: 'nearby.emergency_call');

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final known = data.cc.isNotEmpty;
    final title = known
        ? t.nearbyEmergencyIn(emergencyCountryName(t, data.cc))
        : t.nearbyEmergencyNumbers;
    final first = data.primary;
    return Card(
      key: const ValueKey('nearby_emergency_numbers'),
      margin: const EdgeInsets.only(bottom: Gap.md),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Icon(Icons.emergency_rounded, color: Brand.danger),
            const SizedBox(width: Gap.sm),
            Expanded(
                child: Text(title,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15))),
          ]),
          if (!known) ...[
            const SizedBox(height: Gap.xs),
            Text(t.nearbyNumbersFallback,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5)),
          ],
          const SizedBox(height: Gap.sm),
          FilledButton.icon(
            key: const ValueKey('nearby_emergency_primary'),
            style: FilledButton.styleFrom(
                backgroundColor: Brand.dangerFill,
                foregroundColor: Colors.white,
                minimumSize: const Size(48, 56)),
            onPressed: () => _call(context, first),
            icon: const Icon(Icons.call_rounded),
            label: Text('${_d(first.number)} · ${emergencyKindLabel(t, first.kind)}',
                textAlign: TextAlign.center),
          ),
          for (final n in data.numbers.skip(1))
            Semantics(
              button: true,
              label: t.nearbyCallNumber(_d(n.number)),
              excludeSemantics: true,
              child: InkWell(
                onTap: () => _call(context, n),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Row(children: [
                    SizedBox(
                        width: 72,
                        child: Text(_d(n.number),
                            style: const TextStyle(
                                fontWeight: FontWeight.w800, fontSize: 16))),
                    Expanded(child: Text(emergencyKindLabel(t, n.kind))),
                    const Icon(Icons.call_rounded, color: Brand.success, size: 20),
                  ]),
                ),
              ),
            ),
          const SizedBox(height: Gap.xs),
          Text(t.nearbyNumbersSource(_d(data.source)),
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11.5)),
          if (!data.verified)
            Text(t.nearbyNumbersUnverified,
                style: TextStyle(color: Brand.warnInk(context), fontSize: 11.5)),
        ]),
      ),
    );
  }
}
