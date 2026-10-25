import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';

/// First-aid quick cards. Steps mirror core.logic.safety.FIRST_AID_CARDS
/// (WHO / BDRCS / Red Cross), condensed. These NEVER diagnose; every card ends
/// by routing to 999. Source-named per card. The content is hard-coded here so
/// it works fully offline.
///
/// Localised entirely through AppLocalizations (no Bangla literal here).
class FirstAidCard {
  final String key;
  final IconData icon;
  const FirstAidCard(this.key, this.icon);

  String title(AppLocalizations t) {
    switch (key) {
      case 'bleeding':
        return t.firstAidBleedingTitle;
      case 'choking':
        return t.firstAidChokingTitle;
      case 'burns':
        return t.firstAidBurnsTitle;
      case 'cpr':
        return t.firstAidCprTitle;
      case 'faint':
        return t.firstAidFaintTitle;
      case 'snakebite':
        return t.firstAidSnakebiteTitle;
    }
    return key;
  }

  List<String> steps(AppLocalizations t) {
    switch (key) {
      case 'bleeding':
        return [
          t.firstAidBleeding1,
          t.firstAidBleeding2,
          t.firstAidBleeding3,
          t.firstAidBleeding4
        ];
      case 'choking':
        return [
          t.firstAidChoking1,
          t.firstAidChoking2,
          t.firstAidChoking3,
          t.firstAidChoking4
        ];
      case 'burns':
        return [
          t.firstAidBurns1,
          t.firstAidBurns2,
          t.firstAidBurns3,
          t.firstAidBurns4
        ];
      case 'cpr':
        return [t.firstAidCpr1, t.firstAidCpr2, t.firstAidCpr3, t.firstAidCpr4];
      case 'faint':
        return [
          t.firstAidFaint1,
          t.firstAidFaint2,
          t.firstAidFaint3,
          t.firstAidFaint4
        ];
      case 'snakebite':
        return [
          t.firstAidSnakebite1,
          t.firstAidSnakebite2,
          t.firstAidSnakebite3,
          t.firstAidSnakebite4
        ];
    }
    return const [];
  }

  static const all = <FirstAidCard>[
    FirstAidCard('cpr', Icons.favorite_rounded),
    FirstAidCard('bleeding', Icons.bloodtype_rounded),
    FirstAidCard('choking', Icons.air_rounded),
    FirstAidCard('burns', Icons.local_fire_department_rounded),
    FirstAidCard('faint', Icons.airline_seat_flat_rounded),
    FirstAidCard('snakebite', Icons.pest_control_rounded),
  ];
}

/// Collapsible list of first-aid quick cards with a standing disclaimer.
class FirstAidList extends StatelessWidget {
  final String Function(String latin) localeDigits;
  const FirstAidList({super.key, required this.localeDigits});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        padding: const EdgeInsets.all(Gap.md),
        margin: const EdgeInsets.only(bottom: Gap.sm),
        decoration: BoxDecoration(
          color: Brand.warning.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
        child: Row(children: [
          Icon(Icons.info_outline_rounded, size: 18, color: Brand.warnInk(context)),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(t.firstAidDisclaimer,
                style: TextStyle(fontSize: 12, color: Brand.warnInk(context))),
          ),
        ]),
      ),
      for (final c in FirstAidCard.all)
        Card(
          margin: const EdgeInsets.only(bottom: Gap.sm),
          child: ExpansionTile(
            leading: Icon(c.icon, color: Brand.danger),
            title: Text(c.title(t),
                style: const TextStyle(fontWeight: FontWeight.w700)),
            childrenPadding: const EdgeInsets.fromLTRB(
                Gap.lg, 0, Gap.lg, Gap.md),
            children: [
              for (int i = 0; i < c.steps(t).length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: Gap.sm),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CircleAvatar(
                        radius: 11,
                        backgroundColor: Brand.danger,
                        child: Text(localeDigits('${i + 1}'),
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.bold)),
                      ),
                      const SizedBox(width: Gap.sm),
                      Expanded(
                          child: Text(c.steps(t)[i],
                              style: const TextStyle(height: 1.4))),
                    ],
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(t.firstAidSourceLabel(_sourceOf(c.key)),
                    style: const TextStyle(
                        fontSize: 11, color: Colors.grey)),
              ),
            ],
          ),
        ),
    ]);
  }

  // Source attribution — kept language-neutral (org names), so it lives here.
  String _sourceOf(String key) {
    switch (key) {
      case 'cpr':
      case 'choking':
        return 'WHO / Red Cross';
      case 'bleeding':
        return 'WHO / BDRCS';
      default:
        return 'WHO';
    }
  }
}
