// qbiz (quality push 9 Nov) — khata customer due link (board row 8):
//  * the statement shows "Send due link" (bn + en, 48 dp, labelled);
//  * tapping it asks the server for THIS customer's link (with the shop id)
//    and hands the server's text to the share sheet — nothing auto-sent;
//  * a failed call says so (no silent dead button).
import 'dart:io';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/business/khata_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_api.dart';

class _Api extends FakeApi {
  _Api({super.lang = 'en'});
  bool down = false;
  final linkCalls = <String>[];

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    if (path.contains('/due-link')) {
      linkCalls.add(path);
      if (down) throw const SocketException('offline');
    }
    return super.postJson(path, body);
  }
}

const _biz = {'id': 4, 'name': 'Rahim Store', 'role': 'owner'};
const _party = {'id': 1, 'name': 'Karim', 'phone': '01712345678', 'book': 'customer'};

Future<AppLocalizations> _pump(WidgetTester tester, _Api api, {String lang = 'en'}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.5;
  addTearDown(tester.view.reset);
  final s = AppState()
    ..api = api
    ..user = AppUser(
        id: 1, name: 'Me', phone: '01712345678', email: '',
        autonomyLevel: 2, language: lang)
    ..locale = Locale(lang)
    ..loading = false;
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
        home: khataStatementPreview(_biz, _party),
      )));
  await tester.pumpAndSettle();
  return lookupAppLocalizations(Locale(lang));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final shared = <String>[];
  setUp(() {
    shared.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('dev.fluttercommunity.plus/share'),
            (call) async {
      final a = call.arguments;
      if (a is Map && a['text'] != null) shared.add('${a['text']}');
      return 'dev.fluttercommunity.plus/share/unavailable';
    });
  });

  for (final lang in ['bn', 'en']) {
    testWidgets('$lang: due link button — asks the server, shares its text', (tester) async {
      final api = _Api(lang: lang);
      final t = await _pump(tester, api, lang: lang);
      final btn = find.byKey(const ValueKey('qbiz-due-link'));
      await tester.ensureVisible(btn);
      await tester.pumpAndSettle();
      expect(find.text(t.qbizDueLinkButton), findsOneWidget);
      expect(find.text(t.qbizDueLinkHint), findsOneWidget);
      expect(tester.getSize(btn).height, greaterThanOrEqualTo(48));
      await tester.tap(btn);
      await tester.pumpAndSettle();
      expect(api.linkCalls, hasLength(1));
      expect(api.linkCalls.single, contains('/business/khata/parties/1/due-link'));
      expect(api.linkCalls.single, contains('business=4'));
      expect(shared, hasLength(1));
      expect(shared.single, contains('https://lifeassisto.com/kh/'));
    });
  }

  testWidgets('a failed link call says so (no dead button)', (tester) async {
    final api = _Api()..down = true;
    await _pump(tester, api);
    final btn = find.byKey(const ValueKey('qbiz-due-link'));
    await tester.ensureVisible(btn);
    await tester.pumpAndSettle();
    await tester.tap(btn);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(SnackBar), findsOneWidget);
    expect(shared, isEmpty);
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });
}
