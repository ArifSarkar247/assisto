import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  // Privacy: a call may show over the lock screen, but closing the ringing
  // screen (decline / system back) must hand the lock screen back at once, so
  // nothing underneath is visible on a locked phone.
  group('lock screen is released when the ringing screen closes', () {
    late List<String> calls;
    setUp(() {
      calls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('com.assisto/lockscreen'),
              (c) async {
        calls.add(c.method);
        return null;
      });
    });
    tearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('com.assisto/lockscreen'), null));

    Future<void> openRinging(WidgetTester tester) async {
      await tester.pumpWidget(_app(Builder(
          builder: (ctx) => Center(
              child: TextButton(
                  onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(
                      builder: (_) => IncomingCallScreen(payload: payload))),
                  child: const Text('open'))))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('incoming-decline')), findsOneWidget);
      expect(calls, isEmpty);
    }

    testWidgets('decline', (tester) async {
      await openRinging(tester);
      await tester.tap(find.byKey(const Key('incoming-decline')));
      await tester.pump(); // pop has STARTED, transition not finished
      expect(calls, contains('release'));
      await tester.pumpAndSettle();
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('system back gesture', (tester) async {
      await openRinging(tester);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(calls, contains('release'));
      await tester.pumpAndSettle();
    });
  });
}
