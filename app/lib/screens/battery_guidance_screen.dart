import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';

/// All-Android hardening: many OEMs (Xiaomi/Oppo/Vivo/Realme/Samsung/OnePlus)
/// aggressively kill background apps, so reminders/alerts may not fire unless
/// the user exempts Assisto. Brand-specific steps (user picks their brand — no
/// extra plugin). Bangla + English.
class BatteryGuidanceScreen extends StatefulWidget {
  const BatteryGuidanceScreen({super.key});
  @override
  State<BatteryGuidanceScreen> createState() => _BatteryGuidanceScreenState();
}

class _BatteryGuidanceScreenState extends State<BatteryGuidanceScreen> {
  String _brand = 'generic';

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    // OEM-specific steps, localized at build time (user picks their brand).
    final steps = <String, List<String>>{
      'generic': [tr.batteryGenericStep1, tr.batteryOneplusStep1, tr.batteryGenericStep3],
      'xiaomi': [tr.batteryXiaomiStep1, tr.batteryXiaomiStep2, tr.batteryXiaomiStep3],
      'oppo': [tr.batteryOppoStep1, tr.batteryOppoStep2, tr.batteryOppoStep3],
      'vivo': [tr.batteryVivoStep1, tr.batteryXiaomiStep2, tr.batteryVivoStep3],
      'realme': [tr.batteryRealmeStep1, tr.batteryRealmeStep2, tr.batteryRealmeStep3],
      'samsung': [tr.batterySamsungStep1, tr.batterySamsungStep2, tr.batterySamsungStep3],
      'oneplus': [tr.batteryOneplusStep1, tr.batteryOneplusStep2, tr.batteryRealmeStep3],
    };
    final brands = <(String, String)>[
      ('generic', tr.batteryBrandGeneric), ('samsung', 'Samsung'), ('xiaomi', 'Xiaomi/Redmi/POCO'),
      ('oppo', 'Oppo'), ('vivo', 'Vivo'), ('realme', 'Realme'), ('oneplus', 'OnePlus'),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(tr.makeRemindersReliable)),
      body: ListView(padding: const EdgeInsets.all(Gap.lg), children: [
        Card(
          color: scheme.tertiaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Text(
              tr.manyPhonesKillBackgroundApps,
              style: TextStyle(color: scheme.onTertiaryContainer),
            ),
          ),
        ),
        const SizedBox(height: Gap.lg),
        Text(tr.yourPhoneBrand,
            style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.sm),
        Wrap(spacing: Gap.sm, children: [
          for (final b in brands)
            ChoiceChip(
              label: Text(b.$2),
              selected: _brand == b.$1,
              onSelected: (_) => setState(() => _brand = b.$1),
            ),
        ]),
        const SizedBox(height: Gap.lg),
        for (int i = 0; i < steps[_brand]!.length; i++)
          ListTile(
            leading: CircleAvatar(
              radius: 14,
              backgroundColor: scheme.primaryContainer,
              child: Text('${i + 1}',
                  style: TextStyle(color: scheme.onPrimaryContainer, fontSize: 13)),
            ),
            title: Text(steps[_brand]![i]),
          ),
        const SizedBox(height: Gap.md),
        Text(
          tr.noteExactMenuNamesVary,
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
      ]),
    );
  }
}
