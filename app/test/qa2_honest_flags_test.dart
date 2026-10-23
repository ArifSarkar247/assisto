// qa2: screens that keep a true/false error flag now keep the failure too —
// a server 5xx shows "Assisto's server…", only a real network failure keeps
// the "check your internet" line.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/inbox_screen.dart';
import 'package:assisto/screens/nominee_screen.dart';
import 'package:assisto/screens/vault_screen.dart';
import 'package:assisto/services/error_kind.dart';
import 'package:assisto/state.dart';

class _Api extends ApiClient {
  _Api(this.error) {
    token = 't';
  }
  final Object error;

  @override
  Future<List<Map<String, dynamic>>> listItems(String path) async => throw error;

  @override
  Future<List<Map<String, dynamic>>> listDocuments() async => throw error;

  @override
  Future<Map<String, dynamic>> getJson(String path) async => throw error;
}

Future<AppLocalizations> _pump(
    WidgetTester tester, Widget screen, Object error) async {
  final app = AppState();
  app.api = _Api(error);
  app.user = AppUser(
      id: 1, name: 'A', phone: '0', email: '', autonomyLevel: 2, language: 'en');
  app.loading = false;
  late AppLocalizations t;
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
    value: app,
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(builder: (ctx) {
        t = AppLocalizations.of(ctx);
        return screen;
      }),
    ),
  ));
  await tester.pumpAndSettle();
  return t;
}

void main() {
  test('isServerFailure: only a 5xx is our server', () {
    expect(isServerFailure(ApiException('x', 503)), isTrue);
    expect(isServerFailure(ApiException('x', 404)), isFalse);
  });

  final screens = <String, Widget Function()>{
    'nominee': () => const NomineeScreen(),
    'vault': () => const VaultScreen(previewUnlocked: true),
    'inbox': () => const InboxScreen(),
  };
  screens.forEach((name, build) {
    testWidgets('$name: HTTP 500 says our server, not the internet',
        (tester) async {
      final t = await _pump(
          tester, build(), ApiException('Something went wrong (500)', 500));
      expect(find.text(t.m3ErrServer), findsOneWidget);
      expect(find.text(t.checkInternetRetry), findsNothing);
      expect(serverFailText(t, ApiException('x', 500)), t.m3ErrServer);
      expect(serverFailText(t, http.ClientException('x')), isNull);
    });
    testWidgets('$name: no connection keeps the internet line',
        (tester) async {
      final t = await _pump(
          tester, build(), http.ClientException('Failed host lookup'));
      expect(find.text(t.checkInternetRetry), findsOneWidget);
      expect(find.text(t.m3ErrServer), findsNothing);
    });
  });
}
