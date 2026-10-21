import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/push/incoming_call_screen.dart';
import 'package:assisto/push/push_payload.dart';

Widget _app(Widget child, {Locale locale = const Locale('en')}) => MaterialApp(
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: child,
    );

void main() {
  final payload = PushPayload({
    'kind': 'call',
    'call_id': '7',
    'chat_id': '3',
    'caller_name': 'Ayesha',
    'video': 'false',
  });

  testWidgets('incoming call shows caller + Accept/Decline (en, 360px, big font)',
      (tester) async {
    tester.view.physicalSize = const Size(360 * 3, 720 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
        child: _app(IncomingCallScreen(payload: payload))));
    await tester.pump();
    expect(find.text('Ayesha'), findsOneWidget);
    expect(find.text('Incoming voice call'), findsOneWidget);
    expect(find.byKey(const Key('incoming-accept')), findsOneWidget);
    expect(find.byKey(const Key('incoming-decline')), findsOneWidget);
    expect(tester.takeException(), isNull);
    // let the 45 s ring timeout + close timer run out cleanly
    await tester.pump(const Duration(seconds: 47));
  });

  testWidgets('incoming call renders in Bangla', (tester) async {
    await tester.pumpWidget(
        _app(IncomingCallScreen(payload: payload), locale: const Locale('bn')));
    await tester.pump();
    final t = await AppLocalizations.delegate.load(const Locale('bn'));
    expect(find.text(t.pushCallAccept), findsOneWidget);
    expect(find.text(t.pushCallDecline), findsOneWidget);
    await tester.pump(const Duration(seconds: 47));
  });
}
