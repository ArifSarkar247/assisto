// ai-reply-notif — SUGGESTED REPLIES IN NOTIFICATIONS (owner order 17 Nov, part A).
// Rules (Dart == Kotlin), the gate (flag + AI-reply consent + master + per
// app; callmoney consent never opens it), consent before Android Settings,
// revoke stops it, unlock-with-ad only in the app, and static guards: no
// auto-send path, no Accessibility, no READ_SMS, no SMS apps.
// Sample data is made up (no real user data).
import 'dart:io';

import 'package:assisto/api.dart';
import 'package:assisto/feature_flags.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/notiflisten/ai_reply_notif.dart';
import 'package:assisto/notiflisten/ai_reply_notif_rules.dart';
import 'package:assisto/notiflisten/ai_reply_notif_screens.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_reply_notif_fake.dart';
import 'fake_api.dart' show FakeMode;
import 'screenshots_test.dart' as gallery;

const _kt = 'android_overlay/app/src/main/kotlin/com/assisto/assisto/notiflisten';

/// Only the token endpoint is answered; everything else is never called.
class _TokenApi extends ApiClient {
  final Map<String, dynamic> answer;
  int calls = 0;
  _TokenApi(this.answer) : super(token: 'test');
  @override
  Future<Map<String, dynamic>> postJsonRaw(String path, [Map<String, dynamic> body = const {}]) async {
    calls++;
    expect(path, '/ai/reply/notif-token');
    return answer;
  }
}

Map<String, String> _ktMap(String src, String name) {
  final start = src.indexOf('val $name');
  final end = src.indexOf(')\n', start);
  return {
    for (final m in RegExp(r'"([^"]+)" to "([^"]+)"').allMatches(src.substring(start, end)))
      m.group(1)!: m.group(2)!
  };
}

Set<String> _ktSet(String src, String name) {
  final start = src.indexOf('val $name');
  final end = src.indexOf(')\n', start);
  return RegExp(r'"([^"]+)"').allMatches(src.substring(start, end)).map((m) => m.group(1)!).toSet();
}

Future<void> _pump(WidgetTester tester, Widget w, {String lang = 'en'}) async {
  final app = gallery.galleryStub(lang: lang, mode: FakeMode.data);
  await tester.binding.setSurfaceSize(const Size(420, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
    value: app,
    child: MaterialApp(
      locale: Locale(lang),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AssistoTheme.light,
      home: w,
    ),
  ));
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  final t = lookupAppLocalizations(const Locale('en'));

  tearDown(() => FeatureFlags.instance.debugOverride = null);

  group('rules: only chat apps, never banks / OTP / money / SOS', () {
    test('Kotlin lists == Dart mirror (no drift)', () {
      final kt = File('$_kt/AiReplyAllow.kt').readAsStringSync();
      expect(_ktMap(kt, 'CHAT_APPS'), AiReplyRules.chatApps);
      expect(_ktSet(kt, 'BLOCKED_PACKAGES'), AiReplyRules.blockedPackages);
      expect(_ktSet(kt, 'MY_CIRCLE_CHANNELS'), AiReplyRules.myCircleChannels);
      // every slug the screen offers exists natively
      for (final s in AiReplyRules.slugs) {
        expect(s == AiReplyRules.myCircle || AiReplyRules.chatApps.containsValue(s), isTrue, reason: s);
      }
    });

    test('enabled chat app -> slug; banks, MFS, SMS, system -> never', () {
      const own = 'com.assisto.assisto';
      expect(AiReplyRules.chatSlug('com.whatsapp', own, null), 'whatsapp');
      expect(AiReplyRules.chatSlug('org.thoughtcrime.securesms', own, null), 'signal');
      expect(AiReplyRules.chatSlug(own, own, 'chat_msg_v2'), 'mycircle');
      for (final p in [
        'com.bKash.customerapp', 'com.konasl.nagad', 'com.dbbl.mbs.apps.main', 'com.upay.android',
        'com.example.mybank', 'com.example.pay.wallet', 'com.google.android.apps.messaging',
        'com.samsung.android.messaging', 'com.android.systemui', 'android', 'com.example.otpapp',
      ]) {
        expect(AiReplyRules.chatSlug(p, own, null), isNull, reason: p);
      }
      // our own SOS / money / AI-reply channels are never "My Circle chat"
      for (final ch in ['sos_alerts', 'assisto_money_notif', 'assisto_ai_reply', null]) {
        expect(AiReplyRules.chatSlug(own, own, ch), isNull, reason: '$ch');
      }
    });

    test('OTP, money, payment and SOS text -> no suggestions', () {
      for (final m in [
        'Your OTP is 482913', 'Verification code: 5521', 'আপনার কোড ৪৮২৯১৩', '4829 is your code',
        'Send me 500 tk on bKash', 'বিকাশে ৫০০ টাকা পাঠাও', 'payment done?', 'Nagad number dao',
        'SOS! I need help', 'জরুরি, বাঁচাও', 'There was an accident, come to the hospital',
        'Please pay the due today',
      ]) {
        expect(AiReplyRules.blockedText('Rahim', m), isNotNull, reason: m);
      }
      for (final m in ['Are you coming to the meeting today?', 'কাল দেখা হবে?', 'Ki khobor?', 'Happy birthday!']) {
        expect(AiReplyRules.blockedText('Rahim', m), isNull, reason: m);
      }
      expect(AiReplyRules.blockedText('Rahim', '   '), 'empty');
    });
  });

  group('gate: flag + AI-reply consent + master + per app', () {
    late FakeAiReplyBridge fake;
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      fake = FakeAiReplyBridge();
      AiReplyNotifChannel.instance = fake;
      FeatureFlags.instance.debugOverride = {'ai_reply_notif': true};
    });

    test('no consent -> stays OFF, native gate closed, no token asked', () async {
      final api = _TokenApi({'ok': true, 'token': 'tk1'});
      final r = await AiReplyNotifService.apply(t, on: true, apps: ['whatsapp'], api: api);
      expect(r.on, isFalse);
      expect(fake.configs.last['on'], isFalse);
      expect(fake.configs.last['consent'], '');
      expect(fake.configs.last['apps'], isEmpty);
      expect(fake.configs.last['token'], '');
      expect(api.calls, 0);
    });

    test('callmoney consent + access NEVER open AI reply', () async {
      SharedPreferences.setMockInitialValues({
        'cm_consent_call_v1': 'x', 'cm_consent_money_v1': 'x', 'cm_callnote_on': true, 'cm_money_on': true,
        'arn_on': true, 'arn_apps': ['whatsapp'],
      });
      fake.st = const AiReplyNativeStatus(available: true, granted: true);
      final r = await AiReplyNotifService.apply(t, on: true, apps: ['whatsapp']);
      expect(r.on, isFalse);
      expect(fake.st.on, isFalse);
    });

    test('flag OFF -> native gate closed even with consent', () async {
      await AiReplyNotifService.recordConsent(true);
      FeatureFlags.instance.debugOverride = {'ai_reply_notif': false};
      final r = await AiReplyNotifService.apply(t, on: true, apps: ['whatsapp']);
      expect(r.on, isFalse);
      expect(fake.configs.last['flag'], isFalse);
      expect(fake.configs.last['token'], '');
    });

    test('consent + flag + app -> ON with a scoped token; only chosen apps', () async {
      await AiReplyNotifService.recordConsent(true);
      final api = _TokenApi({'ok': true, 'token': 'tk1', 'expires_at': '2099-01-01T00:00:00Z'});
      final r = await AiReplyNotifService.apply(t, on: true, apps: ['whatsapp', 'evil.app', 'mycircle'], api: api);
      expect(r.on, isTrue);
      expect(r.apps, ['mycircle', 'whatsapp']);
      final c = fake.configs.last;
      expect(c['on'], isTrue);
      expect(c['token'], 'tk1');
      expect(c['apps'], ['mycircle', 'whatsapp']);
      expect((c['strings'] as Map)['title'], contains('%NAME%'));
      // a fresh token is not asked again
      await AiReplyNotifService.apply(t, on: true, apps: ['whatsapp'], api: api);
      expect(api.calls, 1);
    });

    test('no app chosen -> no token (nothing can be read)', () async {
      await AiReplyNotifService.recordConsent(true);
      final api = _TokenApi({'ok': true, 'token': 'tk1'});
      await AiReplyNotifService.apply(t, on: true, apps: const [], api: api);
      expect(fake.configs.last['token'], '');
      expect(api.calls, 0);
    });

    test('turn OFF drops the token and every card; sign-out too', () async {
      await AiReplyNotifService.recordConsent(true);
      await AiReplyNotifService.apply(t, on: true, apps: ['whatsapp'],
          api: _TokenApi({'ok': true, 'token': 'tk1', 'expires_at': '2099-01-01T00:00:00Z'}));
      await AiReplyNotifService.turnOff(t);
      expect(fake.configs.last['on'], isFalse);
      expect(fake.configs.last['token'], '');
      await AiReplyNotifService.apply(t, on: true, apps: ['whatsapp']);
      await AiReplyNotifService.signOut();
      expect(fake.configs.last['on'], isFalse);
      expect(fake.configs.last['token'], '');
      expect((await AiReplyNotifService.load()).on, isFalse);
    });

    test('server says flag off / child (403) -> token dropped', () async {
      await AiReplyNotifService.recordConsent(true);
      await AiReplyNotifService.apply(t, on: true, apps: ['whatsapp'],
          api: _TokenApi({'ok': false, 'reason': 'child', '_status': 403}));
      expect(fake.configs.last['token'], '');
    });

    test('native strings exist in bn + en and keep %NAME%', () {
      for (final l in ['bn', 'en']) {
        final s = AiReplyNotifService.nativeStrings(lookupAppLocalizations(Locale(l)));
        expect(s.values.every((v) => v.trim().isNotEmpty), isTrue);
        expect(s['title'], contains('%NAME%'));
        expect(s['sent'], contains('%NAME%'));
      }
    });
  });

  group('screens', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      FeatureFlags.instance.debugOverride = {'ai_reply_notif': true};
    });

    testWidgets('consent screen comes BEFORE Android Settings; decline = off', (tester) async {
      final fake = FakeAiReplyBridge();
      AiReplyNotifChannel.instance = fake;
      await _pump(tester, const AiReplyNotifSettingsScreen());
      await tester.tap(find.byKey(const ValueKey('arn_master')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('arn_consent')), findsOneWidget);
      expect(fake.openedSettings, 0);
      await tester.tap(find.byKey(const ValueKey('arn_decline')));
      await tester.pumpAndSettle();
      expect(fake.openedSettings, 0);
      expect((await AiReplyNotifService.load()).on, isFalse);
    });

    testWidgets('agree -> recorded, then Android access page opens', (tester) async {
      final fake = FakeAiReplyBridge();
      AiReplyNotifChannel.instance = fake;
      await _pump(tester, const AiReplyNotifSettingsScreen());
      await tester.tap(find.byKey(const ValueKey('arn_master')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('arn_agree')));
      await tester.tap(find.byKey(const ValueKey('arn_agree')));
      await tester.pumpAndSettle();
      expect(await AiReplyNotifService.hasConsent(), isTrue);
      expect(fake.openedSettings, 1);
      // all apps OFF by default: the user is asked to pick one
      expect(find.text(t.arnAppsPickOne), findsOneWidget);
    });

    testWidgets('consent screen says what, where, not stored, credits, how to stop (bn)', (tester) async {
      await _pump(tester, const AiReplyNotifConsentScreen(), lang: 'bn');
      final bn = lookupAppLocalizations(const Locale('bn'));
      for (final s in [bn.arnDiscRead, bn.arnDiscWhere, bn.arnDiscNoStore, bn.arnDiscCost, bn.arnDiscOff]) {
        expect(find.text(s), findsOneWidget);
      }
    });

    testWidgets('master OFF -> per-app switches cannot be turned on', (tester) async {
      AiReplyNotifChannel.instance = FakeAiReplyBridge();
      await _pump(tester, const AiReplyNotifSettingsScreen());
      final sw = tester.widget<SwitchListTile>(find.byKey(const ValueKey('arn_app_whatsapp')));
      expect(sw.onChanged, isNull);
      expect(sw.value, isFalse);
    });

    testWidgets('access revoked -> shown as stopped', (tester) async {
      SharedPreferences.setMockInitialValues({'arn_consent_v1': 'x', 'arn_on': true, 'arn_apps': ['whatsapp']});
      AiReplyNotifChannel.instance =
          FakeAiReplyBridge(st: const AiReplyNativeStatus(available: true, granted: false, apps: ['whatsapp']));
      await _pump(tester, const AiReplyNotifSettingsScreen());
      expect(find.byKey(const ValueKey('arn_access_off')), findsOneWidget);
      expect(find.text(t.arnAccessStopped), findsOneWidget);
    });

    testWidgets('no credits -> "unlock with an ad" lives in the app', (tester) async {
      SharedPreferences.setMockInitialValues({'arn_consent_v1': 'x', 'arn_on': true, 'arn_apps': ['whatsapp']});
      AiReplyNotifChannel.instance = FakeAiReplyBridge(
          st: const AiReplyNativeStatus(available: true, granted: true, on: true, apps: ['whatsapp'], noCreditCount: 3));
      await _pump(tester, const AiReplyNotifSettingsScreen());
      expect(find.byKey(const ValueKey('arn_unlock_card')), findsOneWidget);
      expect(find.byKey(const ValueKey('arn_unlock_ad')), findsOneWidget);
    });

    testWidgets('companion preview: 2 replies + Write myself', (tester) async {
      await _pump(tester, const Scaffold(body: AiReplyCompanionCard()));
      expect(find.text(t.arnSampleReply1), findsOneWidget);
      expect(find.text(t.arnSampleReply2), findsOneWidget);
      expect(find.text(t.arnWriteMyself), findsOneWidget);
    });
  });

  group('native guards (static)', () {
    final core = File('$_kt/AiReplyCore.kt').readAsStringSync();
    final rx = File('$_kt/AiReplyTapReceiver.kt').readAsStringSync();
    final listener = File('$_kt/AssistoNotifListener.kt').readAsStringSync();
    final channel = File('$_kt/NotifListenChannel.kt').readAsStringSync();

    test('NO auto-send: the only PendingIntent.send is in sendFromTap, called only by the tap receiver', () {
      final sends = RegExp(r'\.send\(').allMatches(core).toList();
      expect(sends.length, 1);
      final fn = core.indexOf('fun sendFromTap(');
      final fnEnd = core.indexOf('\n    }\n', fn);
      expect(sends.single.start > fn && sends.single.start < fnEnd, isTrue);
      // sendFromTap is referenced nowhere else in native code but the receiver
      for (final f in Directory('android_overlay').listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.kt')) continue;
        final s = f.readAsStringSync();
        final n = 'sendFromTap('.allMatches(s).length;
        if (f.path.endsWith('AiReplyCore.kt')) {
          expect(n, 1, reason: 'definition only');
        } else if (f.path.endsWith('AiReplyTapReceiver.kt')) {
          expect(n, 1);
        } else {
          expect(n, 0, reason: f.path);
        }
        if (f.path.endsWith('AiReplyTapReceiver.kt') || f.path.endsWith('AiReplyCore.kt')) continue;
        expect(s.contains('AiReplyCore.EXTRA_TARGET'), isFalse, reason: f.path);
      }
      // the receiver re-checks the gate + access before sending
      expect(rx.indexOf('masterOn(ctx)'), lessThan(rx.indexOf('sendFromTap(')));
      expect(rx.indexOf('granted(ctx)'), lessThan(rx.indexOf('sendFromTap(')));
    });

    test('gate before any content; callmoney access never opens it', () {
      final onPosted = core.substring(core.indexOf('fun onPosted('), core.indexOf('fun onRemoved('));
      expect(onPosted.indexOf('shouldRead('), lessThan(onPosted.indexOf('extract(')));
      expect(onPosted.indexOf('extract('), lessThan(onPosted.indexOf('blockedText(')));
      expect(onPosted.indexOf('blockedText('), lessThan(onPosted.indexOf('fetch(')));
      final master = core.substring(core.indexOf('fun masterOn('), core.indexOf('fun enabledApps('));
      for (final k in ['"ai_on"', '"ai_flag"', '"ai_consent"']) {
        expect(master, contains(k));
      }
      expect(master.contains('callnote') || master.contains('money'), isFalse);
      final should = core.substring(core.indexOf('fun shouldRead('), core.indexOf('private fun s('));
      expect(should, contains('masterOn(ctx)'));
      expect(should, contains('!in enabledApps(ctx)'));
      // message content (EXTRA_TEXT / EXTRA_MESSAGES) only inside extract()/lines()
      final readStart = core.indexOf('private fun lines(');
      final readEnd = core.indexOf('// ------------------------------------------------------------ on posted');
      for (final x in ['EXTRA_TEXT', 'EXTRA_MESSAGES', 'EXTRA_TITLE']) {
        for (final m in RegExp(x).allMatches(core)) {
          expect(m.start > readStart && m.start < readEnd, isTrue, reason: '$x read outside extract');
        }
      }
      // the listener hands over before the callmoney check, crash-guarded
      final posted = listener.substring(listener.indexOf('private fun handlePosted'));
      expect(posted.indexOf('AiReplyCore.onPosted'), lessThan(posted.indexOf('anyOn(ctx)) return')));
    });

    test('turning either feature off never stops the other', () {
      expect(channel, contains('setComponentOn(ctx, cn || mo || AiReplyCore.masterOn(ctx))'));
      expect(channel, contains('live || NotifListenCore.callNoteOn(ctx) || NotifListenCore.moneyOn(ctx)'));
    });

    test('no credits -> no card in the notification (counted for the in-app unlock)', () {
      final f = core.substring(core.indexOf('private fun fetch('), core.indexOf('// ------------------------------------------------------------ companion'));
      final nc = f.indexOf('"no_credits"');
      expect(nc, greaterThan(0));
      expect(f.substring(nc, f.indexOf('return null', nc)).contains('post('), isFalse);
      expect(core.toLowerCase().contains('admob'), isFalse);
    });

    test('no Accessibility, no SMS permission or SMS apps, no new permission', () {
      for (final f in [
        ...Directory(_kt).listSync().whereType<File>(),
        ...Directory('lib/notiflisten').listSync().whereType<File>().where((f) => f.path.contains('ai_reply')),
      ]) {
        final s = f.readAsStringSync();
        for (final bad in ['AccessibilityService', 'READ_SMS', 'SmsManager', 'Telephony.Sms.Inbox', 'BIND_ACCESSIBILITY']) {
          expect(s.contains(bad), isFalse, reason: '${f.path} uses $bad');
        }
      }
      final ci = File('../.github/workflows/android.yml').readAsStringSync();
      final b = ci.substring(ci.indexOf('# ---- ai-reply-notif ----'), ci.indexOf('# ---- /ai-reply-notif ----'));
      expect(b, contains('notiflisten.AiReplyTapReceiver'));
      expect(b, contains('android:exported="false"'));
      expect(b.contains('uses-permission'), isFalse);
      expect(b.contains('<service'), isFalse);
    });

    test('companion card: low-noise channel, grouped, one per conversation', () {
      expect(core, contains('NotificationManager.IMPORTANCE_LOW'));
      expect(core, contains('.setGroup(GROUP)'));
      expect(core, contains('fun nid(sbnKey: String)'));
      expect(core, contains('if (last.fromMe) return null'));
    });
  });
}
