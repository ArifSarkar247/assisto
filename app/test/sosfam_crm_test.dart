// sosfam-crm-proof (board row 15): the owner sees WHY a customer gets no
// message path — how and when they said STOP — and that only the customer
// can turn messages back on. bn (Bangla digits) + en, 200% font.
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/crm/crm100_api.dart';
import 'package:assisto/screens/crm/crm_send_sheet.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_api.dart';
import 'fake_crm100.dart';

class _StopWhyApi extends FakeApi {
  _StopWhyApi(this.source, {super.lang = 'en'});
  final String source;
  final posts = <String>[];

  @override
  Future<Map<String, dynamic>> postJson(String path,
      [Map<String, dynamic> body = const {}]) async {
    posts.add(path.split('?').first);
    if (path.startsWith('/crm/send/preview')) {
      return {
        ...crm100Preview(blocked: 'opted_out'),
        'wa_url': '',
        'sms_uri': '',
        'opted_out': true,
        // noon Dhaka time — the same calendar day in every test time zone
        'stop': {'source': source, 'at': '2026-11-17T06:00:00+00:00'},
      };
    }
    return super.postJson(path, body);
  }
}

Future<AppLocalizations> _open(WidgetTester tester, FakeApi api,
    {String lang = 'en', double scale = 1.0}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.5;
  addTearDown(tester.view.reset);
  final s = AppState()
    ..api = api
    ..user = AppUser(
        id: 1, name: 'Me', phone: '01712345678', email: '', autonomyLevel: 2, language: lang)
    ..locale = Locale(lang)
    ..loading = false;
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: s,
      child: MaterialApp(
        locale: Locale(lang),
        theme: AssistoTheme.light,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        builder: (ctx, child) => MediaQuery(
            data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!),
        home: Builder(
            builder: (c) => Scaffold(
                body: Center(
                    child: FilledButton(
                        onPressed: () => CrmSendSheet.show(c,
                            target: const CustomerTarget(phone: '01712345678'),
                            name: 'Karim Mia',
                            initialText: 'Hello'),
                        child: const Text('open'))))),
      )));
  await tester.pumpAndSettle();
  final t = AppLocalizations.of(tester.element(find.text('open')));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(t.c100ChooseHow));
  await tester.pumpAndSettle();
  return t;
}

String _noteText(WidgetTester tester) {
  final note = find.byKey(const ValueKey('gbz-send-optedout'));
  expect(note, findsOneWidget);
  return tester
      .widgetList<Text>(find.descendant(of: note, matching: find.byType(Text)))
      .map((w) => w.data ?? '')
      .join('\n');
}

void main() {
  group('STOP: the owner sees the reason', () {
    final cases = <String, String Function(AppLocalizations, String)>{
      'sms_link': (t, d) => t.gbzStopByLink(d),
      'chat': (t, d) => t.gbzStopByChat(d),
      'in_app': (t, d) => t.gbzStopByApp(d),
      'owner': (t, d) => t.gbzStopByOwner(d),
    };
    for (final e in cases.entries) {
      testWidgets('en: ${e.key} -> how + when + only the customer can undo', (tester) async {
        final api = _StopWhyApi(e.key);
        final t = await _open(tester, api);
        final text = _noteText(tester);
        expect(text, contains(t.c100SmsOptedOut));
        expect(text, contains(e.value(t, '17-11-2026')));
        expect(text, contains(t.gbzStopUndo));
        await tester.tap(find.text(t.c100WayWa));
        await tester.pumpAndSettle();
        expect(api.posts.where((p) => p.startsWith('/crm/send/log')), isEmpty);
        expect(api.posts.where((p) => p.startsWith('/crm/send/sms')), isEmpty);
      });
    }

    testWidgets('bn: Bangla digits in the date, 200% font, no overflow', (tester) async {
      final api = _StopWhyApi('sms_link', lang: 'bn');
      final t = await _open(tester, api, lang: 'bn', scale: 2.0);
      final text = _noteText(tester);
      expect(text, contains(t.gbzStopByLink('১৭-১১-২০২৬')));
      expect(RegExp(r'[0-9]').hasMatch(t.gbzStopByLink('১৭-১১-২০২৬')), isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('unknown source / no date: just the STOP note, never a broken line',
        (tester) async {
      final api = _StopWhyApi('something_new');
      final t = await _open(tester, api);
      final text = _noteText(tester);
      expect(text, contains(t.c100SmsOptedOut));
      expect(text, isNot(contains('null')));
    });
  });
}
