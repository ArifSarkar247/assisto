import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';

/// Honest surfacing of the DISCREET SOS triggers (item 7) + the live-journey
/// foreground service (item 2) that are NATIVE platform work. We do NOT fake
/// them: each row shows a clear "Available when ___" gate so the user knows
/// exactly what works today (the in-app SOS button, in-app live screen) vs what
/// arrives with the native build.
///
/// The integrator flips a trigger to live by implementing its platform channel
/// and passing `available: true`.
class SosNativeHook {
  final IconData icon;
  final String titleKey; // AppLocalizations getter name documented in report
  final String descKey;
  final bool available;
  const SosNativeHook(this.icon, this.titleKey, this.descKey,
      {this.available = false});
}

class SosNativeHooksSection extends StatelessWidget {
  const SosNativeHooksSection({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final rows = <_Row>[
      _Row(Icons.power_settings_new, t.sosHookPowerTitle, t.sosHookPowerDesc),
      _Row(Icons.vibration, t.sosHookShakeTitle, t.sosHookShakeDesc),
      _Row(Icons.lock_outline, t.sosHookTileTitle, t.sosHookTileDesc),
      _Row(Icons.widgets_outlined, t.sosHookWidgetTitle, t.sosHookWidgetDesc),
      _Row(Icons.notifications_active_outlined, t.sosHookServiceTitle,
          t.sosHookServiceDesc),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t.sosHooksSection,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 6),
        ...rows.map((r) => ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(r.icon, color: Colors.grey),
              title: Text(r.title),
              subtitle: Text(r.desc,
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
              trailing: Chip(
                visualDensity: VisualDensity.compact,
                label: Text(t.sosHookGated,
                    style: const TextStyle(fontSize: 11)),
                backgroundColor: Colors.amber.withOpacity(0.2),
              ),
            )),
      ],
    );
  }
}

class _Row {
  final IconData icon;
  final String title;
  final String desc;
  _Row(this.icon, this.title, this.desc);
}
