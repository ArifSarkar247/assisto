// rt2: a server 5xx is never shown as "check your internet".
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:assisto/api.dart';
import 'package:assisto/calls/call_controller.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/circle_call_screen.dart';
import 'package:assisto/services/error_kind.dart';
import 'package:assisto/widgets/loading_gate.dart';

import 'c2_calls_fakes.dart';

class _ThrowingPlace extends FakeSignaling {
  _ThrowingPlace(this.error);
  final Object error;
  @override
  Future<Map<String, dynamic>> place(int memberId, String kind,
      {String? clientCallId}) async {
    eventLog.add('place:$memberId:$kind');
    throw error;
  }
}

CallController _mk(FakeSignaling s) => CallController(
      media: FakeCallMedia(),
      signaling: s,
      sounds: FakeSounds(),
      video: false,
      outgoing: true,
      memberId: 7,
      callId: null,
      reconnectGrace: const Duration(milliseconds: 20),
      reconnectGiveUp: const Duration(milliseconds: 400),
      statusEvery: const Duration(seconds: 30),
      statsEvery: const Duration(seconds: 30),
      setupRetryDelays: const [Duration.zero, Duration.zero],
    );

void main() {
  test('failKindOf: 5xx = server, 4xx = refused, socket/timeout = network', () {
    expect(failKindOf(ApiException('boom', 500)), FailKind.server);
    expect(failKindOf(ApiException('boom', 503)), FailKind.server);
    expect(failKindOf(ApiException('bad', 400)), FailKind.refused);
    expect(failKindOf(ApiException('nope', 403)), FailKind.refused);
    expect(failKindOf(http.ClientException('Connection refused')), FailKind.network);
    expect(failKindOf(TimeoutException('slow')), FailKind.network);
    expect(isServerFailure(ApiException('x', 502)), isTrue);
    expect(isServerFailure(http.ClientException('x')), isFalse);
  });

  test('placing a call that gets HTTP 500 ends as serverError, not network', () async {
    final c = _mk(_ThrowingPlace(ApiException('Something went wrong (500)', 500)));
    await c.start();
    expect(c.endReason, CallEndReason.serverError);
    expect(isFailureReason(c.endReason), isTrue);
    expect(canCallAgain(c, hasMember: true), isTrue);
    c.dispose();
  });

  test('placing a call with no connection still says network', () async {
    final c = _mk(_ThrowingPlace(http.ClientException('Failed host lookup')));
    await c.start();
    expect(c.endReason, CallEndReason.network);
    c.dispose();
  });

  for (final lang in ['en', 'bn']) {
    testWidgets('labels ($lang): server error never mentions the internet line',
        (tester) async {
      late AppLocalizations t;
      await tester.pumpWidget(MaterialApp(
        locale: Locale(lang),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(builder: (ctx) {
          t = AppLocalizations.of(ctx);
          return Scaffold(
            body: LoadErrorRetry(
                error: ApiException('Something went wrong (500)', 500),
                onRetry: () {}),
          );
        }),
      ));
      await tester.pump();
      final server = endReasonLabel(t, CallEndReason.serverError, outgoing: true);
      // calls-presence: after the silent retries — "Server problem" vs
      // "Weak network" (never the internet line for a server 5xx)
      expect(server, t.cpCallServerProblem);
      expect(server, isNot(t.cpCallWeakNetwork));
      expect(endReasonLabel(t, CallEndReason.network, outgoing: true),
          t.cpCallWeakNetwork);
      // the shared load-error view: a 5xx shows the server line
      expect(find.text(t.m3ErrServer), findsOneWidget);
      expect(find.text(t.qaLoadFailedRetry), findsNothing);
      expect(honestFailText(t, ApiException('x', 500)), t.m3ErrServer);
      expect(honestFailText(t, http.ClientException('x')), t.qaLoadFailedRetry);
    });
  }
}
