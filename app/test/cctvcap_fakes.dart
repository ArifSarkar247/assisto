// cctvcap: fakes for the CCTV caps (AI checks, 80/100 % notices, extra pack).
import 'package:assisto/api.dart';

import 'cctvguard_fakes.dart';

Map<String, dynamic> cgCap({
  String relay = 'notice',
  String ai = 'full',
  bool enforced = true,
  String lang = 'en',
  int aiUsed = 100,
  int aiCap = 100,
}) {
  final bn = lang == 'bn';
  return {
    'month': '2026-11',
    'enforced': enforced,
    'relay': {
      'level': enforced ? relay : 'off', 'pct': relay == 'paused' ? 100 : 80, 'cap_mb': 600,
      'used_mb': 482.4, 'extra_mb': 0,
      'message': '',
    },
    'ai': {
      'level': ai, 'pct': aiCap == 0 ? 100 : (aiUsed * 100 ~/ aiCap), 'cap': aiCap,
      'used': aiUsed, 'left': aiCap - aiUsed, 'extra': 0,
      'message': ai == 'full'
          ? (bn
              ? 'এই মাসের AI ছবি-যাচাই শেষ — নতুন ছবির বর্ণনা এখন ধরন-সময় থেকে লেখা (AI নয়)। সতর্কতা, ছবি, SOS ও প্রমাণ আগের মতো চলবে।'
              : "This month's AI photo checks are used up — new photo descriptions are written from the alert type and time (not AI). Alerts, photos, SOS and evidence keep working.")
          : '',
    },
    'packs': [
      {'kind': 'relay', 'mb': 1000, 'price_bdt': 150, 'credits': 150,
       'play_product': 'cctv_extra_relay_1gb'},
      {'kind': 'ai', 'checks': 100, 'price_bdt': 80, 'credits': 80,
       'play_product': 'cctv_extra_ai_100'},
    ],
    'balance': 120,
    'safety_note': bn ? 'SOS, সতর্কতা, ছবি ও প্রমাণ কখনো থামে না।'
        : 'SOS, alerts, photos and evidence never stop.',
  };
}

/// "This month's use" with the cap block.
Map<String, dynamic> cgUsageCap({String lang = 'en', String relay = 'notice', String ai = 'full',
    bool enforced = true}) =>
    {
      ...cgUsage(lang: lang, enforced: enforced, level: relay),
      'cap': cgCap(lang: lang, relay: relay, ai: ai, enforced: enforced),
    };

class FakePackBuyer {
  final List<String> calls = [];
  ApiException? failWith;
  final String lang;
  FakePackBuyer({this.lang = 'en'});

  Future<Map<String, dynamic>> call(String kind) async {
    calls.add(kind);
    final f = failWith;
    if (f != null) throw f;
    return {
      ...cgUsage(lang: lang, level: 'ok'),
      'cap': cgCap(lang: lang, relay: 'ok', ai: kind == 'ai' ? 'ok' : 'full',
          aiUsed: 100, aiCap: kind == 'ai' ? 200 : 100),
      'bought': {'kind': kind, 'charged_credits': kind == 'ai' ? 80 : 150},
    };
  }
}
