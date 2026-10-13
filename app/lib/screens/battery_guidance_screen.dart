import 'package:flutter/material.dart';
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

  // Bangla steps per brand (reminders reliability).
  static const _steps = {
    'generic': [
      'Settings → Apps → Assisto → Battery → "Unrestricted"/"সীমাহীন" করুন।',
      'Settings → Battery → Battery optimization → Assisto → "Don\'t optimize"।',
      'নোটিফিকেশন অনুমতি চালু রাখুন।',
    ],
    'xiaomi': [
      'Settings → Apps → Manage apps → Assisto → Battery saver → "No restrictions"।',
      'Autostart → Assisto চালু করুন।',
      'Recent apps-এ Assisto lock (তালা) করুন যাতে বন্ধ না হয়।',
    ],
    'oppo': [
      'Settings → Battery → Assisto → Allow background activity + "Don\'t optimize"।',
      'Startup Manager / Auto startup → Assisto চালু।',
      'Floating/Recent-এ Assisto lock করুন।',
    ],
    'vivo': [
      'Settings → Battery → High background power consumption → Assisto allow।',
      'Autostart → Assisto চালু।',
      'iManager → App manager → Autostart।',
    ],
    'realme': [
      'Settings → Battery → Assisto → Allow background activity, "Don\'t optimize"।',
      'Settings → Apps → Auto-launch → Assisto চালু।',
      'Recent apps-এ Assisto lock করুন।',
    ],
    'samsung': [
      'Settings → Apps → Assisto → Battery → "Unrestricted"।',
      'Settings → Battery → Background usage limits → Assisto যেন "Sleeping/Deep sleeping"-এ না থাকে।',
      'Device care → Battery → যেন Assisto restricted না হয়।',
    ],
    'oneplus': [
      'Settings → Battery → Battery optimization → Assisto → "Don\'t optimize"।',
      'Settings → Apps → Assisto → Battery → Allow background।',
      'Recent apps-এ Assisto lock করুন।',
    ],
  };

  static const _brands = [
    ('generic', 'সাধারণ / General'), ('samsung', 'Samsung'), ('xiaomi', 'Xiaomi/Redmi/POCO'),
    ('oppo', 'Oppo'), ('vivo', 'Vivo'), ('realme', 'Realme'), ('oneplus', 'OnePlus'),
  ];

  @override
  Widget build(BuildContext context) {
    final en = context.watch<AppState>().locale?.languageCode == 'en';
    String tr(String bn, String e) => en ? e : bn;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr('রিমাইন্ডার নির্ভরযোগ্য করুন', 'Make reminders reliable'))),
      body: ListView(padding: const EdgeInsets.all(Gap.lg), children: [
        Card(
          color: scheme.tertiaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Text(
              tr('অনেক ফোন ব্যাটারি বাঁচাতে অ্যাপ বন্ধ করে দেয়, তখন রিমাইন্ডার/অ্যালার্ট নাও আসতে পারে। '
                  'নিচের ধাপে Assisto-কে ছাড় দিন।',
                  'Many phones kill background apps to save battery, so reminders/alerts may not arrive. '
                  'Exempt Assisto using the steps below.'),
              style: TextStyle(color: scheme.onTertiaryContainer),
            ),
          ),
        ),
        const SizedBox(height: Gap.lg),
        Text(tr('আপনার ফোনের ব্র্যান্ড', 'Your phone brand'),
            style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.sm),
        Wrap(spacing: Gap.sm, children: [
          for (final b in _brands)
            ChoiceChip(
              label: Text(b.$2),
              selected: _brand == b.$1,
              onSelected: (_) => setState(() => _brand = b.$1),
            ),
        ]),
        const SizedBox(height: Gap.lg),
        for (int i = 0; i < _steps[_brand]!.length; i++)
          ListTile(
            leading: CircleAvatar(
              radius: 14,
              backgroundColor: scheme.primaryContainer,
              child: Text('${i + 1}',
                  style: TextStyle(color: scheme.onPrimaryContainer, fontSize: 13)),
            ),
            title: Text(_steps[_brand]![i]),
          ),
        const SizedBox(height: Gap.md),
        Text(
          tr('দ্রষ্টব্য: ঠিক মেনু নাম ফোন/সংস্করণভেদে একটু আলাদা হতে পারে।',
              'Note: exact menu names vary slightly by phone/version.'),
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
      ]),
    );
  }
}
