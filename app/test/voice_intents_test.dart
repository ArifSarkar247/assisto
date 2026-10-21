// Assisto Voice parser — bn / Banglish / English phrase table (Part 3).
// Bangla is allowed here: the language gate only scans lib/.
import 'package:flutter_test/flutter_test.dart';
import 'package:assisto/voice/voice_intents.dart';
import 'package:assisto/widgets/chatnav.dart';

VaIntent p(String s) =>
    VoiceIntentParser.parse(s, detectRoute: ChatNav.detectRoute);

void expectAction(String phrase, VaAction a, {String? target, String? message}) {
  final r = p(phrase);
  expect(r.action, a, reason: '"$phrase" -> $r');
  if (target != null) {
    expect(r.target, target, reason: '"$phrase" target -> $r');
  }
  if (message != null) {
    expect(r.message, message, reason: '"$phrase" message -> $r');
  }
}

void main() {
  group('call', () {
    final cases = <String, String>{
      'call ammu': 'ammu',
      'Call Ammu': 'ammu',
      'call mom': 'mom',
      'please call rahim bhai': 'rahim bhai',
      'phone abbu': 'abbu',
      'dial karim': 'karim',
      'ammu ke call dao': 'ammu',
      'abbu ke ekta phone dao': 'abbu',
      'rakib ke call koro': 'rakib',
      'rahim vai ke kol dao': 'rahim vai',
      'আম্মুকে ফোন দাও': 'আম্মু',
      'আব্বুকে কল করো': 'আব্বু',
      'রহিম ভাইকে ফোন করো': 'রহিম ভাই',
      'রাকিবকে একটু কল দাও': 'রাকিব',
      'মাকে ফোন দাও': 'মা',
    };
    cases.forEach((phrase, who) {
      test(phrase, () => expectAction(phrase, VaAction.call, target: who));
    });
    test('call is outgoing (needs confirmation)', () {
      expect(p('call ammu').outgoing, isTrue);
    });
  });

  group('sms / whatsapp', () {
    test('en text', () => expectAction('text rakib i am coming', VaAction.sms,
        target: 'rakib', message: 'i am coming'));
    test('en send message to', () => expectAction(
        'send a message to rakib saying i am late', VaAction.sms,
        target: 'rakib', message: 'i am late'));
    test('banglish likho', () => expectAction(
        'rakib ke likho ami ashchi', VaAction.sms,
        target: 'rakib', message: 'ami ashchi'));
    test('banglish sms koro je', () => expectAction(
        'rakib ke sms koro je ami ashchi', VaAction.sms,
        target: 'rakib', message: 'ami ashchi'));
    test('bn likho', () => expectAction('রাকিবকে লিখো আমি আসছি', VaAction.sms,
        target: 'রাকিব', message: 'আমি আসছি'));
    test('bn message dao', () => expectAction(
        'আম্মুকে মেসেজ দাও যে আমি পৌঁছে গেছি', VaAction.sms,
        target: 'আম্মু', message: 'আমি পৌঁছে গেছি'));
    test('en whatsapp', () => expectAction(
        'whatsapp rakib i am coming', VaAction.whatsapp,
        target: 'rakib', message: 'i am coming'));
    test('banglish whatsapp', () => expectAction(
        'rakib ke whatsapp e likho ami ashchi', VaAction.whatsapp,
        target: 'rakib', message: 'ami ashchi'));
    test('bn whatsapp', () => expectAction(
        'রাকিবকে হোয়াটসঅ্যাপে লিখো আমি আসছি', VaAction.whatsapp,
        target: 'রাকিব', message: 'আমি আসছি'));
    test('whatsapp to', () => expectAction(
        'send whatsapp to ammu saying dinner ready', VaAction.whatsapp,
        target: 'ammu', message: 'dinner ready'));
    test('open whatsapp = app', () => expectAction(
        'open whatsapp', VaAction.openApp, target: 'whatsapp'));
    test('note likho is not sms', () {
      expect(p('note e likho dudh kinte hobe').action, isNot(VaAction.sms));
    });
    test('sms/wa are outgoing', () {
      expect(p('text rakib hi').outgoing, isTrue);
      expect(p('whatsapp rakib hi').outgoing, isTrue);
    });
  });

  group('youtube / music', () {
    test('youtube e gaan chalao', () {
      final r = p('youtube e gaan chalao');
      expect(r.action, VaAction.youtube);
      expect(r.app, 'youtube');
      expect(r.target, isNull);
    });
    test('play arijit songs', () => expectAction(
        'play arijit singh songs', VaAction.youtube, target: 'arijit singh'));
    test('play on youtube', () => expectAction(
        'play tahsan on youtube', VaAction.youtube, target: 'tahsan'));
    test('banglish gaan shunao', () =>
        expectAction('habib er gaan shunao', VaAction.youtube));
    test('bn gaan chalao', () =>
        expectAction('রবীন্দ্র সংগীত গান চালাও', VaAction.youtube));
    test('bn youtube', () =>
        expectAction('ইউটিউবে নাটক চালাও', VaAction.youtube, target: 'নাটক'));
    test('open youtube = app', () =>
        expectAction('open youtube', VaAction.openApp, target: 'youtube'));
  });

  group('music: artist + song (owner sentence)', () {
    void song(String phrase, String artist, String title, {String? app}) {
      final r = p(phrase);
      expect(r.action, VaAction.youtube, reason: '$r');
      expect(r.artist?.toLowerCase(), artist, reason: '$r');
      expect(r.song?.toLowerCase(), title, reason: '$r');
      if (app != null) expect(r.app, app, reason: '$r');
    }
    test('banglish owner sentence', () => song(
        'Hey Assisto, YouTube-e Asif-er Amar Priya gaan ta play koro',
        'asif', 'amar priya', app: 'youtube'));
    test('banglish without hey', () => song(
        'asif er amar priya gaan ta chalao', 'asif', 'amar priya'));
    test('bn owner sentence', () => song(
        'হেই অ্যাসিস্টো, ইউটিউবে আসিফের আমার প্রিয়া গানটা চালাও',
        'আসিফ', 'আমার প্রিয়া', app: 'youtube'));
    test('bn without youtube', () =>
        song('আসিফের আমার প্রিয়া গানটা বাজাও', 'আসিফ', 'আমার প্রিয়া'));
    test('en by', () => song(
        'Hey Assisto, play Amar Priya by Asif on YouTube', 'asif',
        'amar priya', app: 'youtube'));
    test("en possessive", () =>
        song("play Asif's Amar Priya", 'asif', 'amar priya'));
    test('spotify', () => song(
        'play Amar Priya by Asif on Spotify', 'asif', 'amar priya',
        app: 'spotify'));
    test('youtube music', () => song(
        'youtube music e james er bhalobashi tomay gaan ta play koro',
        'james', 'bhalobashi tomay', app: 'ytmusic'));
    test('query has song then artist', () {
      expect(p('Asif-er Amar Priya gaan ta play koro').target?.toLowerCase(),
          'amar priya asif');
    });
    test('hi assisto torch on', () =>
        expectAction('Hi Assisto torch on', VaAction.torchOn));
    test('hey assisto call ammu', () =>
        expectAction('hey assisto, ammu ke call dao', VaAction.call,
            target: 'ammu'));
  });

  group('alarm / timer', () {
    final now = DateTime(2026, 10, 21, 22, 0);
    test('kal 8tay alarm', () {
      final r = p('kal 8tay alarm');
      expect(r.action, VaAction.alarm);
      final at = r.clock!.resolve(now);
      expect([at.day, at.hour, at.minute], [22, 8, 0]);
    });
    test('alarm for 6:30 am', () {
      final r = p('set an alarm for 6:30 am');
      expect(r.action, VaAction.alarm);
      expect([r.clock!.hour, r.clock!.minute], [6, 30]);
    });
    test('wake me up at 7', () {
      final r = p('wake me up at 7');
      expect(r.action, VaAction.alarm);
      final at = r.clock!.resolve(now);
      expect(at.hour, 7);
    });
    test('bn sokal 6tay', () {
      final r = p('সকাল ৬টায় অ্যালার্ম দাও');
      expect(r.action, VaAction.alarm);
      expect(r.clock!.hour, 6);
    });
    test('banglish rat 10 tay', () {
      final r = p('rat 10 tay alarm dao');
      expect(r.action, VaAction.alarm);
      expect(r.clock!.hour, 22);
    });
    test('bn sare 7', () {
      final r = p('কাল সাড়ে ৭টায় এলার্ম');
      expect(r.action, VaAction.alarm);
      expect([r.clock!.hour, r.clock!.minute, r.clock!.tomorrow],
          [7, 30, true]);
    });
    test('alarm 5 pm', () {
      final r = p('alarm 5 pm');
      expect(r.clock!.hour, 17);
    });
    test('alarm without time', () {
      final r = p('set an alarm');
      expect(r.action, VaAction.alarm);
      expect(r.clock, isNull);
    });
    test('timer 5 minutes', () {
      final r = p('set a timer for 5 minutes');
      expect(r.action, VaAction.timer);
      expect(r.seconds, 300);
    });
    test('banglish timer', () {
      final r = p('10 minute er timer dao');
      expect(r.seconds, 600);
    });
    test('bn timer', () {
      final r = p('১ ঘণ্টা ৩০ মিনিটের টাইমার');
      expect(r.action, VaAction.timer);
      expect(r.seconds, 5400);
    });
    test('timer seconds', () => expect(p('timer 45 seconds').seconds, 45));
  });

  group('torch', () {
    test('torch on', () => expectAction('torch on', VaAction.torchOn));
    test('turn on the flashlight',
        () => expectAction('turn on the flashlight', VaAction.torchOn));
    test('torch off', () => expectAction('torch off', VaAction.torchOff));
    test('turn off flashlight',
        () => expectAction('turn off flashlight', VaAction.torchOff));
    test('banglish torch jalao',
        () => expectAction('torch jalao', VaAction.torchOn));
    test('banglish bondho', () =>
        expectAction('torch bondho koro', VaAction.torchOff));
    test('bn torch chalu', () => expectAction('টর্চ চালু করো', VaAction.torchOn));
    test('bn torch bondho', () => expectAction('টর্চ বন্ধ করো', VaAction.torchOff));
    test('bn flash nibhao',
        () => expectAction('ফ্ল্যাশলাইট নিভাও', VaAction.torchOff));
  });

  group('maps', () {
    test('navigate to', () => expectAction(
        'navigate to gulshan 2', VaAction.navigate, target: 'gulshan 2'));
    test('directions to', () => expectAction(
        'directions to dhaka airport', VaAction.navigate,
        target: 'dhaka airport'));
    test('banglish jabo kivabe', () => expectAction(
        'uttara te jabo kivabe', VaAction.navigate, target: 'uttara'));
    test('bn kivabe jabo', () => expectAction(
        'ধানমন্ডি কিভাবে যাব', VaAction.navigate, target: 'ধানমন্ডি'));
    test('bn kolkata is not a call', () => expectAction(
        'কলকাতা কিভাবে যাব', VaAction.navigate, target: 'কলকাতা'));
    test('nearest pharmacy', () => expectAction(
        'nearest pharmacy', VaAction.mapSearch, target: 'pharmacy near me'));
    test('bn nearby hospital', () =>
        expectAction('কাছাকাছি হাসপাতাল', VaAction.mapSearch));
    test('on map', () => expectAction(
        'show dhanmondi lake on map', VaAction.mapSearch,
        target: 'dhanmondi lake'));
  });

  group('reminder', () {
    final now = DateTime(2026, 10, 21, 10, 0);
    test('remind me at 5 to call mum', () {
      final r = p('remind me at 5 to call mum');
      expect(r.action, VaAction.reminder);
      expect(r.message, 'call mum');
      final at = r.clock!.resolve(now);
      expect(at.hour, 17); // 5 AM already passed -> 5 PM
    });
    test('remind tomorrow 9am', () {
      final r = p('remind me tomorrow at 9 am to pay the bill');
      expect(r.action, VaAction.reminder);
      expect(r.clock!.tomorrow, isTrue);
      expect(r.clock!.hour, 9);
    });
    test('banglish mone koriye', () {
      final r = p('kal sokal 8 tay oshudh khete mone koriye dio');
      expect(r.action, VaAction.reminder);
      expect(r.clock!.hour, 8);
      expect(r.message, contains('oshudh'));
    });
    test('bn mone koriye', () {
      final r = p('কাল সকাল ৮টায় ওষুধ মনে করিয়ে দিও');
      expect(r.action, VaAction.reminder);
      expect(r.clock!.hour, 8);
      expect(r.clock!.tomorrow, isTrue);
      expect(r.message, 'ওষুধ');
    });
    test('bn reminder', () =>
        expectAction('বিকেল ৪টায় মিটিং এর রিমাইন্ডার দাও', VaAction.reminder));
    test('reminder is not outgoing', () {
      expect(p('remind me at 5 to call mum').outgoing, isFalse);
    });
  });

  group('expense', () {
    test('banglish bazar', () {
      final r = p('500 taka bazar khoroch');
      expect(r.action, VaAction.expense);
      expect(r.amount, 500);
      expect(r.category, 'groceries');
    });
    test('bn bazar', () {
      final r = p('৫০০ টাকা বাজার খরচ');
      expect(r.action, VaAction.expense);
      expect(r.amount, 500);
      expect(r.category, 'groceries');
    });
    test('en spent', () {
      final r = p('i spent 200 on rickshaw');
      expect(r.action, VaAction.expense);
      expect(r.amount, 200);
      expect(r.category, 'transport');
    });
    test('hajar', () => expect(p('2 hajar taka kapor kinlam').amount, 2000));
    test('phone bill is expense, not a call', () {
      final r = p('300 taka phone bill');
      expect(r.action, VaAction.expense);
      expect(r.category, 'bills');
    });
    test('bn khabar', () {
      final r = p('দুপুরের খাবারে ১৫০ টাকা খরচ হলো');
      expect(r.action, VaAction.expense);
      expect(r.amount, 150);
      expect(r.category, 'food');
    });
    test('loan goes to the agent', () {
      expect(p('rahim ke 500 taka dhar dilam').action, VaAction.unknown);
    });
  });

  group('sos', () {
    test('sos', () => expectAction('sos', VaAction.sos));
    test('help me', () => expectAction('help me', VaAction.sos));
    test('bachao', () => expectAction('amake bachao', VaAction.sos));
    test('bn bachao', () => expectAction('বাঁচাও', VaAction.sos));
    test('bn bipode', () => expectAction('আমি বিপদে আছি', VaAction.sos));
    test('emergency', () => expectAction('emergency', VaAction.sos));
    test('help me write is not sos',
        () => expect(p('help me write a letter to my boss').action,
            isNot(VaAction.sos)));
    test('sos is outgoing', () => expect(p('sos').outgoing, isTrue));
  });

  group('open', () {
    test('open facebook', () =>
        expectAction('open facebook', VaAction.openApp, target: 'facebook'));
    test('banglish kholo', () =>
        expectAction('facebook kholo', VaAction.openApp, target: 'facebook'));
    test('bn camera', () =>
        expectAction('ক্যামেরা খোলো', VaAction.openApp, target: 'ক্যামেরা'));
    test('open in-app screen', () {
      final r = p('open my reminders');
      expect(r.action, VaAction.openScreen);
      expect(r.route, 'reminders');
    });
    test('show money', () {
      final r = p('show money');
      expect(r.action, VaAction.openScreen);
      expect(r.route, 'money');
    });
    test('voice assistant route', () {
      final r = p('open voice assistant');
      expect(r.route, 'voice_assistant');
    });
  });

  group('unknown -> server agent', () {
    for (final s in [
      'how much did i spend this month',
      'এই মাসে কত খরচ হলো?',
      'amar chabi kothay',
      'what is the capital of france',
      '',
    ]) {
      test('"$s"', () => expect(p(s).action, VaAction.unknown));
    }
  });

  group('reply language (auto)', () {
    final cases = <String, String>{
      'আম্মুকে ফোন দাও': 'bn',
      'ammu ke call dao': 'bn',
      'YouTube-e Asif-er Amar Priya gaan ta play koro': 'bn',
      'kal 8tay alarm': 'bn',
      '500 taka bazar khoroch': 'bn',
      'torch jalao': 'bn',
      'Call Ammu': 'en',
      'play Amar Priya by Asif on YouTube': 'en',
      'set an alarm for 6:30 am': 'en',
      'turn on the flashlight': 'en',
      'remind me at 5 to call mum': 'en',
    };
    cases.forEach((s, l) =>
        test(s, () => expect(VaText.replyLang(s), l)));
  });

  group('helpers', () {
    test('yes/no', () {
      expect(VaYesNo.classify('yes'), isTrue);
      expect(VaYesNo.classify('হ্যাঁ'), isTrue);
      expect(VaYesNo.classify('ha koro'), isTrue);
      expect(VaYesNo.classify('no'), isFalse);
      expect(VaYesNo.classify('না, থাক'), isFalse);
      expect(VaYesNo.classify('lagbe na'), isFalse);
      expect(VaYesNo.classify('banana'), isNull);
    });
    test('skeleton cross-script', () {
      expect(VaText.skeleton('Rakib'), VaText.skeleton('রাকিব'));
      expect(VaText.skeleton('Rahim'), VaText.skeleton('রহিম'));
      expect(VaText.skeleton('Shakil'), VaText.skeleton('শাকিল'));
    });
    test('contact rank: relation alias + script', () {
      final book = [
        {'name': 'Ammu', 'phone': '01711111111'},
        {'name': 'Rakib Hasan', 'phone': '01722222222'},
        {'name': 'Abbu', 'phone': '01733333333'},
        {'name': 'Karim', 'phone': '01744444444'},
      ];
      expect(VaContacts.rank('আম্মু', book).first['name'], 'Ammu');
      expect(VaContacts.rank('mom', book).first['name'], 'Ammu');
      expect(VaContacts.rank('রাকিব', book).first['name'], 'Rakib Hasan');
      expect(VaContacts.rank('zzz', book), isEmpty);
    });
    test('app match', () {
      final apps = [
        {'label': 'WhatsApp', 'package': 'com.whatsapp'},
        {'label': 'Camera', 'package': 'com.oplus.camera'},
        {'label': 'bKash', 'package': 'com.bKash.customerapp'},
      ];
      expect(VaApps.best('whatsapp', apps), 'com.whatsapp');
      expect(VaApps.best('হোয়াটসঅ্যাপ', apps), 'com.whatsapp');
      expect(VaApps.best('ক্যামেরা', apps), 'com.oplus.camera');
      expect(VaApps.best('বিকাশ', apps), 'com.bKash.customerapp');
      expect(VaApps.best('photoshop', apps), isNull);
    });
    test('wa number', () {
      expect(VaText.waNumber('01712-345678'), '8801712345678');
      expect(VaText.waNumber('+8801712345678'), '8801712345678');
    });
  });
}
