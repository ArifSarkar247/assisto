// theftalerts (owner 2 Nov) — the three theft alerts, app side:
//   * an OWNER COPY of a theft alert is drawn on the owner's other devices
//     and dropped on the protected phone itself (device-hash prefix);
//   * the device hash matches the server's (core/own_device.py) formula;
//   * a push's intruder photo is drawn only from our own signed https link,
//     and only when the bytes are a JPEG;
//   * the protection screen shows the nominee switch with an honest count
//     and the honest camera / uninstall / factory-reset limits.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/push/push_notifier.dart';
import 'package:assisto/screens/always_on_protection_screen.dart';
import 'package:assisto/services/own_device_guard.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'fake_api.dart';

const _dev = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';
// python: sha256(b"assisto-dev:" + _dev).hexdigest()
const _devHash =
    '24ea1ec05591105a38a3050c777541e6b8683f60c22234fff34b1fc6a59257fa';

Map<String, String> _copy(String src) => {
      'kind': 'family_alert',
      'alert_kind': 'antitheft',
      'antitheft_kind': 'intruder_photo',
      'phone_id': '9',
      'owner_id': '42',
      'owner_copy': '1',
      'src_dev': src,
    };

const _channel = MethodChannel('com.assisto/antitheft');

Future<void> _pump(WidgetTester tester, String lang) async {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
    switch (call.method) {
      case 'capabilities':
        return {'sdk': 33, 'brand': 'realme', 'canCamera': true};
      case 'isRunning':
        return true;
      default:
        return null;
    }
  });
  final s = AppState();
  s.api = FakeApi(mode: FakeMode.data, lang: lang);
  s.user = AppUser(
      id: 1, name: 'Me', phone: '+8801700000000', email: '',
      autonomyLevel: 2, language: lang);
  s.locale = Locale(lang);
  s.loading = false;
  await tester.binding.setSurfaceSize(const Size(400, 900));
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
    value: s,
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
      home: const AlwaysOnProtectionScreen(),
    ),
  ));
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('owner copy', () {
    test('device hash matches the server formula', () {
      expect(OwnDeviceGuard.devHashOf(_dev), _devHash);
      expect(OwnDeviceGuard.devHashOf(''), '');
    });

    test('dropped on the protected phone, drawn on the other device', () {
      final d = _copy(_devHash.substring(0, 16));
      expect(OwnDeviceGuard.isOwn(d, me: 42, myDevHash: _devHash), isTrue);
      final other = OwnDeviceGuard.devHashOf('ffffeeeeddddccccbbbbaaaa99998888');
      expect(OwnDeviceGuard.isOwn(d, me: 42, myDevHash: other), isFalse);
      // even when this device remembers the protected phone id
      expect(OwnDeviceGuard.isOwn(d, me: 42, phoneIds: {9}, myDevHash: other),
          isFalse);
    });

    test('unknown device either side -> dropped (never on the wrong phone)',
        () {
      expect(OwnDeviceGuard.isOwn(_copy(''), me: 42, myDevHash: _devHash),
          isTrue);
      expect(
          OwnDeviceGuard.isOwn(_copy(_devHash.substring(0, 16)),
              me: 42, myDevHash: ''),
          isTrue);
    });

    test('a normal (non-copy) alert about my phone is still dropped', () {
      final d = Map<String, String>.from(_copy('x'))
        ..remove('owner_copy')
        ..remove('src_dev');
      expect(OwnDeviceGuard.isOwn(d, me: 42, myDevHash: _devHash), isTrue);
      expect(OwnDeviceGuard.isOwn(d, me: 7), isFalse); // family: shows
    });
  });

  group('push photo', () {
    test('only our signed https engine-photo link', () {
      expect(
          PushNotifier.theftPhotoUrlOk('https://lifeassisto.com/api/v1/'
              'security/engine/event/12/photo?v=1&e=2&s=abc'),
          isTrue);
      expect(
          PushNotifier.theftPhotoUrlOk('http://lifeassisto.com/api/v1/'
              'security/engine/event/12/photo?v=1&e=2&s=abc'),
          isFalse);
      expect(
          PushNotifier.theftPhotoUrlOk(
              'https://evil.example/anything.jpg?s=1'),
          isFalse);
      expect(
          PushNotifier.theftPhotoUrlOk('https://lifeassisto.com/api/v1/'
              'security/engine/event/12/photo'),
          isFalse); // unsigned
      expect(PushNotifier.theftPhotoUrlOk(null), isFalse);
    });

    test('jpeg check', () {
      expect(
          PushNotifier.looksLikeJpeg(
              Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 0])),
          isTrue);
      expect(PushNotifier.looksLikeJpeg(Uint8List.fromList([1, 2, 3, 4, 5])),
          isFalse);
      expect(PushNotifier.looksLikeJpeg(null), isFalse);
    });
  });

  for (final lang in ['en', 'bn']) {
    testWidgets('nominee switch + honest limits ($lang)', (tester) async {
      await _pump(tester, lang);
      final t = AppLocalizations.of(
          tester.element(find.byType(AlwaysOnProtectionScreen)));
      await tester.dragUntilVisible(find.byKey(const Key('ta-nominee-switch')),
          find.byType(Scrollable).first, const Offset(0, -300));
      expect(find.text(t.taNomineeTitle), findsOneWidget);
      expect(find.text(t.taNomineeReach(1, 2)), findsOneWidget);
      expect(find.text(t.taOwnerCopy), findsOneWidget);
      await tester.dragUntilVisible(find.text(t.taLimitReset),
          find.byType(Scrollable).first, const Offset(0, -300));
      expect(find.text(t.taLimitCamera), findsOneWidget);
      expect(find.text(t.taLimitUninstall), findsOneWidget);
      if (lang == 'bn') {
        // Bangla digits in the count
        expect(t.taNomineeReach(1, 2).contains('১'), isTrue);
      }
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null);
    });
  }
}
