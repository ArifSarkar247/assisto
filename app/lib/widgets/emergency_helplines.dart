import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';

/// Verified BD emergency helpline directory. Numbers are hard-coded here from
/// the verified set (mirrors core.logic.safety.EMERGENCY_HELPLINES) so the
/// directory works fully OFFLINE — no network needed to call for help.
///
/// Verified 2026 against Daily Star / TBS / govt sources:
///   999  national emergency (police/fire/ambulance, toll-free 24/7) — primary
///   109  violence against women & children (MoWCA, toll-free)
///   333  government information service
///   102  fire service & civil defence
///   199  central ambulance coordination centre
///   100  police control room (999 is the primary line)
///   1090 disaster / weather warning (toll-free)
class EmergencyHelpline {
  final String key;
  final String number;
  final bool primary;
  final IconData icon;
  const EmergencyHelpline(this.key, this.number, this.icon,
      {this.primary = false});

  String label(AppLocalizations t) {
    switch (key) {
      case 'national':
        return t.emergencyHlNational;
      case 'women_child':
        return t.emergencyHlWomenChild;
      case 'govt_info':
        return t.emergencyHlGovt;
      case 'fire':
        return t.emergencyHlFire;
      case 'ambulance':
        return t.emergencyHlAmbulance;
      case 'police':
        return t.emergencyHlPolice;
      case 'disaster':
        return t.emergencyHlDisaster;
    }
    return key;
  }

  String note(AppLocalizations t) {
    switch (key) {
      case 'national':
        return t.emergencyHlNationalNote;
      case 'women_child':
        return t.emergencyHlWomenChildNote;
      case 'govt_info':
        return t.emergencyHlGovtNote;
      case 'fire':
        return t.emergencyHlFireNote;
      case 'ambulance':
        return t.emergencyHlAmbulanceNote;
      case 'police':
        return t.emergencyHlPoliceNote;
      case 'disaster':
        return t.emergencyHlDisasterNote;
    }
    return '';
  }

  static const all = <EmergencyHelpline>[
    EmergencyHelpline('national', '999', Icons.emergency, primary: true),
    EmergencyHelpline('women_child', '109', Icons.female),
    EmergencyHelpline('govt_info', '333', Icons.info_outline),
    EmergencyHelpline('fire', '102', Icons.local_fire_department),
    EmergencyHelpline('ambulance', '199', Icons.local_hospital),
    EmergencyHelpline('police', '100', Icons.local_police),
    EmergencyHelpline('disaster', '1090', Icons.cyclone),
  ];
}

/// One-tap helpline directory list. Localised labels, Bangla/English, source
/// line shown at the foot. Big tap targets. `onCall` dials the number.
class EmergencyHelplineList extends StatelessWidget {
  final void Function(String number) onCall;
  final String Function(String latin) localeDigits;
  const EmergencyHelplineList({
    super.key,
    required this.onCall,
    required this.localeDigits,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Column(children: [
      for (final h in EmergencyHelpline.all)
        Card(
          color: h.primary
              ? Brand.danger.withValues(alpha: 0.08)
              : null,
          margin: const EdgeInsets.only(bottom: Gap.sm),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(
                horizontal: Gap.lg, vertical: Gap.xs),
            leading: CircleAvatar(
              backgroundColor:
                  h.primary ? Brand.danger : Theme.of(context).colorScheme.secondaryContainer,
              foregroundColor: h.primary
                  ? Colors.white
                  : Theme.of(context).colorScheme.onSecondaryContainer,
              child: Icon(h.icon),
            ),
            title: Text(h.label(t),
                style: TextStyle(
                    fontWeight:
                        h.primary ? FontWeight.w800 : FontWeight.w600)),
            subtitle: Text(h.note(t),
                style: const TextStyle(fontSize: 12)),
            trailing: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: h.primary ? Brand.danger : null,
                padding: const EdgeInsets.symmetric(horizontal: Gap.md),
                minimumSize: const Size(0, 48),
              ),
              onPressed: () => onCall(h.number),
              icon: const Icon(Icons.call, size: 18),
              label: Text(localeDigits(h.number)),
            ),
          ),
        ),
      const SizedBox(height: Gap.xs),
      Text(t.emergencyHelplineSource,
          style: const TextStyle(fontSize: 11, color: Colors.grey)),
    ]);
  }
}
