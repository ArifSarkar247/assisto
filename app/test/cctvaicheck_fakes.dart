// cctvaicheck (W4 B3/B4): fakes for the AI check of the alert snapshot —
// the per-camera "AI দিয়ে যাচাই" switch and alert rows carrying the AI
// label. Shapes mirror backend/core/cctv_ai_check.py (server words, viewer's
// language).
import 'cctv1_fakes.dart';
import 'cctvalerts_fakes.dart';

Map<String, dynamic> aiSwitchPayload(String lang, {bool ready = true, bool on = true}) {
  final bn = lang == 'bn';
  return {
    'on': ready && on,
    'ready': ready,
    'used': 12,
    'cap': 100,
    'title': bn ? 'AI দিয়ে যাচাই' : 'Check with AI',
    'note': !ready
        ? (bn
            ? 'AI চাবি যুক্ত নেই — তাই যাচাই হয় না; সতর্কতা আগের মতোই আসে।'
            : 'No AI key connected — no check; alerts still come as before.')
        : (bn
            ? 'সতর্কতা সাথে সাথেই যায়; তারপর শুধু ছবিটা AI দেখে বলে মানুষ / গাড়ি / প্রাণী নাকি কিছুই না। ভিডিও বা শব্দ কখনো যায় না, কাউকে চেনা হয় না। এই মাসে ব্যবহার ১২ / ১০০।'
            : 'The alert goes out at once; then only the photo is shown to the AI: person, vehicle, animal or nothing. Never video or sound, nobody is identified. Used this month: 12 / 100.'),
  };
}

/// Alert types + the AI switch. mode: 'ready' (key, on) | 'nokey' | 'savefail'.
class FakeAiAlertTypes extends FakeAlertTypes {
  final String aiMode;
  bool aiOn = true;
  FakeAiAlertTypes(this.aiMode, {super.lang = 'en'}) : super('hik');

  Map<String, dynamic> _with(Map<String, dynamic> d) =>
      {...d, 'ai_check': aiSwitchPayload(lang, ready: aiMode != 'nokey', on: aiOn)};

  @override
  Future<Map<String, dynamic>> load(int cameraId) async => _with(await super.load(cameraId));

  @override
  Future<Map<String, dynamic>> save(int cameraId, Map<String, bool> types) async {
    if (aiMode == 'savefail') {
      saved.add(Map.of(types));
      throw Exception('offline');
    }
    final d = await super.save(cameraId, Map.of(types)..remove('ai_check'));
    saved
      ..removeLast()
      ..add(Map.of(types));
    if (types.containsKey('ai_check')) aiOn = types['ai_check']!;
    return _with(d);
  }
}

Map<String, dynamic> aiLabel(String lang, String state, {String? cls, double? conf}) {
  final bn = lang == 'bn';
  String text;
  var likelyFalse = false;
  if (state == 'done' && cls == 'person') {
    text = bn ? 'AI: মানুষ দেখা গেছে ৯২%' : 'AI: Person seen 92%';
  } else if (state == 'done' && cls == 'none') {
    likelyFalse = true;
    text = bn
        ? 'সম্ভবত ভুল সতর্কতা (AI কিছু দেখেনি, ৮৫% নিশ্চিত)'
        : 'Probably a false alarm (AI saw nothing, 85% sure)';
  } else if (state == 'cap') {
    text = bn ? 'AI যাচাই হয়নি — এই মাসের AI সীমা শেষ' : "AI not checked — this month's AI allowance is used up";
  } else {
    text = bn ? 'AI যাচাই হয়নি — AI চাবি যুক্ত নেই' : 'AI not checked — no AI key connected';
  }
  return {'state': state, 'cls': cls, 'conf': conf, 'likely_false': likelyFalse, 'text': text};
}

/// The alert list with AI labels: a person seen, a probable false alarm,
/// and an honest "not checked" (over the monthly allowance).
class FakeWatchmanAi extends FakeWatchman {
  final String lang;
  FakeWatchmanAi({this.lang = 'en'}) : super('data');

  @override
  Future<Map<String, dynamic>> events(int siteId) async {
    final d = await super.events(siteId);
    final rows = [for (final e in (d['events'] as List)) Map<String, dynamic>.from(e as Map)];
    rows[0]['ai_check'] = aiLabel(lang, 'done', cls: 'person', conf: 0.92);
    rows[1]['ai_check'] = aiLabel(lang, 'done', cls: 'none', conf: 0.85);
    rows.add({
      ...rows[0],
      'id': 103,
      'type': 'motion',
      'count': 1,
      'ai_check': aiLabel(lang, 'cap'),
    });
    return {...d, 'events': rows};
  }
}
