// privacyupd — owner Play decision 5 (9 Nov): Money from notifications keeps
// wallet-APP notifications; the part that reads SMS-app notifications (bank /
// wallet sender ids) follows the SERVER switch money_notif_sms (default ON).
// OFF = ignored on the phone (native gate before any read), waiting items
// dropped, never saved or sent; an owner "preview" of OFF counts as OFF.
import 'dart:io';

import 'package:assisto/feature_flags.dart';
import 'package:assisto/feature_registry.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/notiflisten/callmoney_screens.dart';
import 'package:assisto/notiflisten/notif_listen_channel.dart';
import 'package:assisto/notiflisten/notif_listen_service.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'callmoney_fake.dart';
import 'fake_api.dart' show FakeMode;
import 'screenshots_test.dart' as gallery;

const _kt = 'android_overlay/app/src/main/kotlin/com/assisto/assisto/notiflisten';
const _flag = NotifListenService.smsFlag;

Future<void> _server({required bool on, List<String> preview = const []}) async {
  await FeatureFlags.instance.refresh(
      (_) async => (
            status: 200,
            body: <String, dynamic>{
              'features': {_flag: on, 'daily_info': true},
              'preview': preview,
            },
            etag: 'e${on}_${preview.length}',
          ),
      force: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    NotifListenService.liveDevice = false;
    NotifListenService.resetSmsSwitchForTest();
    FeatureFlags.instance.debugOverride = null;
  });
  tearDown(() async {
    FeatureFlags.instance.debugOverride = null;
    await _server(on: true);
    NotifListenService.resetSmsSwitchForTest();
  });

  test('default ON (today): registry default + both SMS items kept', () async {
    expect(kFeatureDefaults[_flag], isTrue);
    final fake = FakeNotifBridge(queue: fakeMoneyQueue());
    NotifListenChannel.instance = fake;
    await _server(on: true);
    expect(NotifListenService.smsAllowed(), isTrue);
    final q = await NotifListenService.takeQueue();
    expect(q.map((x) => x.id), [1, 2, 3]);
    expect(fake.smsSwitch, [true]);
    expect(fake.done, isEmpty);
  });

  test('server OFF: SMS items dropped on the phone, wallet-app item kept', () async {
    final fake = FakeNotifBridge(queue: fakeMoneyQueue());
    NotifListenChannel.instance = fake;
    await _server(on: false);
    expect(NotifListenService.smsAllowed(), isFalse);
    final q = await NotifListenService.takeQueue();
    expect(q.map((x) => x.id), [1]); // the bKash APP notification stays
    expect(q.single.kind, 'app');
    expect(fake.smsSwitch.last, isFalse); // native listener told to ignore SMS
    expect(fake.queue.where((x) => x.kind == 'sms'), isEmpty);
  });

  test('auto-save with the switch OFF never saves an SMS item', () async {
    SharedPreferences.setMockInitialValues(
        {'cm_consent_money_v1': 'x', 'cm_money_on': true, 'cm_money_auto': true});
    final fake = FakeNotifBridge(queue: fakeMoneyQueue());
    NotifListenChannel.instance = fake;
    await _server(on: false);
    final app = gallery.galleryStub(lang: 'en');
    final t = lookupAppLocalizations(const Locale('en'));
    await NotifListenService.autoSave(app, t);
    final saved = [
      for (final x in app.txns.items)
        if ((x['data'] as Map?)?['source'] == 'notification') '${(x['data'] as Map)['ref']}'
    ];
    expect(saved, isNot(contains('71NG3K2PQ'))); // the Nagad SMS
    expect(saved, isNot(contains('88POS1902'))); // the bank SMS
    if (app.loggedIn) expect(fake.queue.where((x) => x.kind == 'sms'), isEmpty);
  });

  test('an owner/staff "preview" of an OFF switch counts as OFF', () async {
    NotifListenChannel.instance = FakeNotifBridge();
    await _server(on: true, preview: [_flag]);
    expect(FeatureFlags.instance.isOn(_flag), isTrue);
    expect(NotifListenService.smsAllowed(), isFalse);
  });

  test('a flag change is pushed to the native listener once', () async {
    final fake = FakeNotifBridge();
    NotifListenChannel.instance = fake;
    await _server(on: true);
    await NotifListenService.syncSmsSwitch();
    await NotifListenService.syncSmsSwitch();
    expect(fake.smsSwitch, [true]);
    await _server(on: false);
    await NotifListenService.syncSmsSwitch();
    expect(fake.smsSwitch, [true, false]);
  });

  testWidgets('settings say so honestly when the switch is OFF', (tester) async {
    SharedPreferences.setMockInitialValues({'cm_consent_money_v1': 'x', 'cm_money_on': true});
    NotifListenChannel.instance =
        FakeNotifBridge(st: const NotifListenStatus(available: true, granted: true, money: true));
    FeatureFlags.instance.debugOverride = {_flag: false};
    final app = gallery.galleryStub(lang: 'en', mode: FakeMode.data);
    await tester.binding.setSurfaceSize(const Size(420, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: app,
      child: MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: AssistoTheme.light,
        home: const Scaffold(body: CallMoneySettingsScreen()),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cmn_sms_paused')), findsOneWidget);
  });

  test('native: SMS gate before readMoney, default ON, OFF drops the queue', () {
    final k = File('$_kt/AssistoNotifListener.kt').readAsStringSync();
    final posted = k.substring(k.indexOf('private fun handlePosted'), k.indexOf('// ---------------------------------------------------------------- calls'));
    final gate = posted.indexOf('kind == "sms" && !NotifListenCore.moneySmsOn(ctx)) return');
    expect(gate, greaterThan(0));
    expect(gate < posted.indexOf('readMoney('), isTrue);
    final core = File('$_kt/NotifListenCore.kt').readAsStringSync();
    expect(core.contains('getBoolean("money_sms", true)'), isTrue); // default ON
    final ch = File('$_kt/NotifListenChannel.kt').readAsStringSync();
    expect(ch.contains('"setMoneySms"'), isTrue);
    expect(ch.contains('NotifListenCore.dropKind(ctx, "sms")'), isTrue);
  });
}
