// calls-presence (owner 24 Oct):
//   * calls: silent setup retries (rtc config / place / accept) before an
//     honest "Weak network" / "Server problem"; Wi-Fi <-> mobile network
//     switch -> "Reconnecting…" + ICE restart, never an immediate drop.
//   * presence: two simulated accounts on a fake server that applies the
//     same rules as core/views_c3_msg.py (Everyone / My contacts / Nobody,
//     reciprocal) — online, typing…, recording audio…, last seen (bn/en);
//     the voice-note "recording" pulse; the privacy chips (no clipping).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';

import 'package:assisto/api.dart';
import 'package:assisto/calls/call_controller.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/presence_label.dart';
import 'package:assisto/realtime/realtime_channel.dart';
import 'package:assisto/realtime/realtime_transport.dart';
import 'package:assisto/screens/circle_call_screen.dart';
import 'package:assisto/widgets/circle_privacy_controls.dart';

import 'c2_calls_fakes.dart';

Future<void> settle() => pumpEventQueue(times: 30);

/// Fails the first [fails] tries of place / accept / rtcConfig.
class _Flaky extends FakeSignaling {
  _Flaky({this.placeErrors = const [], this.acceptErrors = const [],
      this.throttledTimes = 0});
  final List<Object> placeErrors;
  final List<Object> acceptErrors;
  int throttledTimes;
  int placeTries = 0, acceptTries = 0, rtcTries = 0;

  @override
  Future<Map<String, dynamic>> place(int memberId, String kind,
      {String? clientCallId}) async {
    placeTries++;
    placeKeys.add(clientCallId);
    if (placeTries <= placeErrors.length) throw placeErrors[placeTries - 1];
    eventLog.add('place:$memberId:$kind');
    return placeBody;
  }

  @override
  Future<Map<String, dynamic>> accept(int callId) async {
    acceptTries++;
    if (acceptTries <= acceptErrors.length) throw acceptErrors[acceptTries - 1];
    return super.accept(callId);
  }

  @override
  Future<Map<String, dynamic>?> rtcConfig() async {
    rtcTries++;
    if (rtcTries <= throttledTimes) {
      return {'configured': true, 'throttled': true, 'ice_servers': []};
    }
    return rtc;
  }
}

final _reports = <String>[];

CallController _mk(FakeCallMedia m, FakeSignaling s,
        {bool outgoing = true, Stream<String>? net}) =>
    CallController(
      media: m,
      signaling: s,
      sounds: FakeSounds(),
      video: false,
      outgoing: outgoing,
      memberId: 7,
      callId: outgoing ? null : 42,
      reconnectGrace: const Duration(milliseconds: 20),
      reconnectGiveUp: const Duration(milliseconds: 600),
      statusEvery: const Duration(seconds: 30),
      statsEvery: const Duration(seconds: 30),
      restartEvery: const Duration(milliseconds: 100),
      setupRetryDelays: const [Duration.zero, Duration.zero],
      networkEvents: net,
      onSetupFailure: (step, code, id) => _reports.add('$step:$code'),
    );

// ------------------------------------------------- fake presence "server"
/// Two accounts' presence + privacy with the SERVER's visibility rules
/// (core/views_c3_msg._member_entry + circle_privacy.can_see_field).
class _Acct {
  _Acct(this.id);
  final int id;
  String lastSeenPolicy = 'everyone';
  String onlinePolicy = 'everyone';
  final Set<int> saved = {}; // accounts this one saved back (contacts)
  bool online = false;
  DateTime? lastSeen;
  String activity = '';
}

class _Server {
  final a = _Acct(1), b = _Acct(2);
  _Acct other(_Acct x) => identical(x, a) ? b : a;

  bool _allowed(String pol, _Acct owner, _Acct viewer) => switch (pol) {
        'everyone' => true,
        'contacts' => owner.saved.contains(viewer.id),
        _ => false, // nobody (family needs relations; not used here)
      };

  /// What [viewer] sees of the other account (null = hidden).
  Map<String, dynamic> viewOf(_Acct viewer) {
    final o = other(viewer);
    final canLs = _allowed(o.lastSeenPolicy, o, viewer) &&
        viewer.lastSeenPolicy != 'nobody';
    final canOn = _allowed(o.onlinePolicy, o, viewer) &&
        viewer.onlinePolicy != 'nobody';
    final act = o.activity;
    return {
      'online': canOn ? (o.online || act.isNotEmpty) : null,
      'last_seen': canLs ? o.lastSeen?.toUtc().toIso8601String() : null,
      'until': null,
      'activity': act,
      'who': '',
    };
  }
}

class _ViewerTransport implements RealtimeTransport {
  _ViewerTransport(this.server, this.me);
  final _Server server;
  final _Acct me;
  final sent = <(String, Map<String, dynamic>)>[];
  final ctl = StreamController<RealtimeEvent>.broadcast();
  @override
  Future<Map<String, dynamic>> snapshot({required bool online}) async => {
        'chats': {'member:9': server.viewOf(me)}
      };
  @override
  Future<void> send(String topic, Map<String, dynamic> payload) async =>
      sent.add((topic, payload));
  @override
  Stream<RealtimeEvent> get events => ctl.stream;
  @override
  set heartbeat(bool on) {}
  @override
  void close() {}
}

Future<AppLocalizations> _l10n(WidgetTester tester, String lang) async {
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
      return const SizedBox();
    }),
  ));
  await tester.pump();
  return t;
}

void main() {
  setUp(_reports.clear);

  group('silent call-setup retries', () {
    test('rtc config throttled twice, then fine: the call goes ahead',
        () async {
      final s = _Flaky(throttledTimes: 2);
      final c = _mk(FakeCallMedia(), s);
      await c.start();
      expect(s.rtcTries, 3);
      expect(c.setupRetries, 2);
      expect(c.phase, CallPhase.calling);
      expect(c.endReason, CallEndReason.none);
      expect(_reports, isEmpty);
      c.dispose();
    });

    test('throttled 3 times: "Server problem" + reported, never placed',
        () async {
      final s = _Flaky(throttledTimes: 99);
      final c = _mk(FakeCallMedia(), s);
      await c.start();
      expect(s.rtcTries, 3);
      expect(c.endReason, CallEndReason.serverBusy);
      expect(s.eventLog, isEmpty);
      expect(_reports, ['rtc_config:throttled']);
      c.dispose();
    });

    test('POST call 5xx twice then OK: one call, same idempotency key',
        () async {
      final s = _Flaky(placeErrors: [
        ApiException('Something went wrong (502)', 502),
        TimeoutException('slow'),
      ]);
      final c = _mk(FakeCallMedia(), s);
      await c.start();
      expect(s.placeTries, 3);
      expect(s.placeKeys.toSet().length, 1,
          reason: 'the server dedupes repeats by client_call_id');
      expect(c.callId, 42);
      expect(c.phase, CallPhase.calling);
      expect(_reports, isEmpty);
      c.dispose();
    });

    test('no internet on every try: "Weak network" after 3 tries', () async {
      final e = http.ClientException('Failed host lookup');
      final s = _Flaky(placeErrors: [e, e, e]);
      final c = _mk(FakeCallMedia(), s);
      await c.start();
      expect(s.placeTries, 3);
      expect(c.endReason, CallEndReason.network);
      expect(_reports, ['place:network']);
      c.dispose();
    });

    test('server 500 on every try: serverError ("Server problem")', () async {
      final e = ApiException('boom', 500);
      final s = _Flaky(placeErrors: [e, e, e]);
      final c = _mk(FakeCallMedia(), s);
      await c.start();
      expect(c.endReason, CallEndReason.serverError);
      expect(_reports, ['place:server']);
      c.dispose();
    });

    test('a 4xx refusal is final: no retry', () async {
      final s = _Flaky(placeErrors: [ApiException('nope', 403)]);
      final c = _mk(FakeCallMedia(), s);
      await c.start();
      expect(s.placeTries, 1);
      expect(c.isEnded, isTrue);
      expect(_reports, isEmpty);
      c.dispose();
    });

    test('callee: accept times out once, then connects', () async {
      final s = _Flaky(acceptErrors: [TimeoutException('slow')]);
      final c = _mk(FakeCallMedia(), s, outgoing: false);
      await c.start();
      expect(s.acceptTries, 2);
      expect(c.phase, CallPhase.accepted);
      c.dispose();
    });

    test('isTransientSetupError', () {
      expect(CallController.isTransientSetupError(ApiException('x', 503)),
          isTrue);
      expect(CallController.isTransientSetupError(ApiException('x', 429)),
          isTrue);
      expect(CallController.isTransientSetupError(ApiException('x', 404)),
          isFalse);
      expect(CallController.isTransientSetupError(TimeoutException('t')),
          isTrue);
      expect(
          CallController.isTransientSetupError(MediaOpenException(true)),
          isFalse);
    });
  });

  group('network switch (Wi-Fi <-> mobile data)', () {
    Future<(CallController, FakeCallMedia, FakeSignaling,
        StreamController<String>)> live({bool outgoing = true}) async {
      final net = StreamController<String>.broadcast();
      final m = FakeCallMedia(), s = FakeSignaling();
      final c = _mk(m, s, outgoing: outgoing, net: net.stream);
      await c.start();
      m.link.add(MediaLinkState.connected);
      await settle();
      expect(c.phase, CallPhase.connected);
      return (c, m, s, net);
    }

    test('switch -> Reconnecting + ICE restart at once, back -> connected',
        () async {
      final (c, m, s, net) = await live();
      s.signals.clear();
      net.add('cellular');
      await settle();
      expect(c.phase, CallPhase.reconnecting);
      expect(s.signals.map((e) => e.$1), contains('restart_offer'));
      expect(s.eventLog, contains('reconnect'));
      expect(c.isEnded, isFalse, reason: 'never dropped for the switch');
      m.link.add(MediaLinkState.connected);
      await settle();
      expect(c.phase, CallPhase.connected);
      c.dispose();
      await net.close();
    });

    test('network lost: Reconnecting (not ended); new network restarts again',
        () async {
      final (c, m, s, net) = await live();
      net.add('lost');
      await settle();
      expect(c.phase, CallPhase.reconnecting);
      s.signals.clear();
      net.add('wifi');
      await settle();
      expect(s.signals.map((e) => e.$1), contains('restart_offer'));
      c.dispose();
      await net.close();
    });

    test('callee asks the caller for the restart (only the caller offers)',
        () async {
      final (c, m, s, net) = await live(outgoing: false);
      s.signals.clear();
      net.add('wifi');
      await settle();
      expect(c.phase, CallPhase.reconnecting);
      expect(s.signals.map((e) => e.$1), contains('restart_request'));
      expect(m.log, isNot(contains('offer:restart')));
      c.dispose();
      await net.close();
    });

    test('a long outage still ends honestly as lost after the give-up',
        () async {
      final (c, _, __, net) = await live();
      net.add('lost');
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await settle();
      expect(c.endReason, CallEndReason.lost);
      c.dispose();
      await net.close();
    });
  });

  group('honest labels after retries (bn + en)', () {
    for (final lang in ['en', 'bn']) {
      testWidgets(lang, (tester) async {
        final t = await _l10n(tester, lang);
        expect(endReasonLabel(t, CallEndReason.network, outgoing: true),
            t.cpCallWeakNetwork);
        expect(endReasonLabel(t, CallEndReason.serverBusy, outgoing: true),
            t.cpCallServerProblem);
        expect(endReasonLabel(t, CallEndReason.serverError, outgoing: true),
            t.cpCallServerProblem);
        expect(t.cpCallWeakNetwork, isNot(t.cpCallServerProblem));
      });
    }
  });

  group('presence: two accounts, privacy enforced like the server', () {
    final rt = RealtimeChannel.instance;
    setUpAll(() async {
      await initializeDateFormatting('en');
      await initializeDateFormatting('bn');
    });
    setUp(rt.resetForTest);

    // wall clock: Dhaka-like fixed local times (no zone conversion)
    DateTime local(DateTime d) => d;
    final now = DateTime(2026, 10, 24, 22, 5);

    testWidgets('online / typing / recording / last seen today + yesterday',
        (tester) async {
      final t = await _l10n(tester, 'en');
      final srv = _Server();
      rt.useTransport(_ViewerTransport(srv, srv.a)); // the phone of A
      String? header() => presenceLabel(t, rt.stateOf('member', 9),
          lang: 'en', now: now, toLocal: local);

      srv.b.online = true;
      await rt.refresh();
      expect(header(), t.c3Online);

      srv.b.activity = 'typing';
      await rt.refresh();
      expect(header(), t.c3Typing);

      srv.b.activity = 'recording';
      await rt.refresh();
      expect(header(), t.c3Recording);

      srv.b
        ..activity = ''
        ..online = false
        ..lastSeen = DateTime(2026, 10, 24, 21, 40).toUtc();
      await rt.refresh();
      expect(header(), contains('today'));
      expect(header(), contains('9:40'));

      srv.b.lastSeen = DateTime(2026, 10, 23, 8, 15).toUtc();
      await rt.refresh();
      expect(header(), contains('yesterday'));
      expect(header(), contains('8:15'));
    });

    testWidgets('Bangla: Bangla digits + day period, never ASCII digits',
        (tester) async {
      final t = await _l10n(tester, 'bn');
      final s = RtChatState(
          online: false, lastSeen: DateTime(2026, 10, 24, 21, 40));
      final l = presenceLabel(t, s, lang: 'bn', now: now, toLocal: local)!;
      expect(l, contains('৯:৪০'));
      expect(RegExp('[0-9]').hasMatch(l), isFalse);
      final y = presenceLabel(
          t,
          RtChatState(online: false, lastSeen: DateTime(2026, 10, 23, 8, 15)),
          lang: 'bn',
          now: now,
          toLocal: local)!;
      expect(y, contains('৮:১৫'));
      expect(y, t.c3LastSeenYesterday(clockLabel(
          t, DateTime(2026, 10, 23, 8, 15), lang: 'bn')));
    });

    testWidgets('My contacts: hidden until B saves A; Nobody is reciprocal',
        (tester) async {
      final t = await _l10n(tester, 'en');
      final srv = _Server();
      rt.useTransport(_ViewerTransport(srv, srv.a));
      String? header() => presenceLabel(t, rt.stateOf('member', 9),
          lang: 'en', now: now, toLocal: local);
      srv.b
        ..online = true
        ..lastSeen = DateTime(2026, 10, 24, 21, 40).toUtc()
        ..lastSeenPolicy = 'contacts'
        ..onlinePolicy = 'contacts';
      await rt.refresh();
      expect(header(), isNull, reason: 'A is not in B\'s contacts');
      srv.b.saved.add(srv.a.id);
      await rt.refresh();
      expect(header(), t.c3Online);
      // A hides theirs -> A sees nobody's (reciprocal)
      srv.a
        ..lastSeenPolicy = 'nobody'
        ..onlinePolicy = 'nobody';
      await rt.refresh();
      expect(header(), isNull);
      // typing still shows (its own reciprocal switch, not last seen)
      srv.b.activity = 'typing';
      await rt.refresh();
      expect(header(), t.c3Typing);
    });

    test('voice note: "recording" now + every 3 s, "stop" at the end',
        () async {
      final srv = _Server();
      final tr = _ViewerTransport(srv, srv.a);
      rt.useTransport(tr);
      rt.recordingStarted('member', 9);
      await settle();
      expect(tr.sent.last.$1, 'typing.set');
      expect(tr.sent.last.$2['state'], 'recording');
      expect(rt.recordingPulseActive('member', 9), isTrue);
      rt.recordingStopped('member', 9);
      await settle();
      expect(tr.sent.last.$2['state'], 'stop');
      expect(rt.recordingPulseActive('member', 9), isFalse);
      // stopping twice sends nothing more
      final n = tr.sent.length;
      rt.recordingStopped('member', 9);
      expect(tr.sent.length, n);
    });

    testWidgets('recording pulse refreshes every 3 s, stops in background',
        (tester) async {
      final srv = _Server();
      final tr = _ViewerTransport(srv, srv.a);
      rt.useTransport(tr);
      rt.recordingStarted('group', 5);
      await tester.pump();
      final first = tr.sent.length;
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(seconds: 3));
      expect(tr.sent.length - first, 2);
      expect(tr.sent.every((e) => e.$2['chat_kind'] == 'group'), isTrue);
      rt.setForeground(false); // app to background: no pulse, "stop" sent
      await tester.pump();
      expect(rt.recordingPulseActive('group', 5), isFalse);
      final states = tr.sent.map((e) => e.$2['state']).toList();
      expect(states.last, 'stop');
      final n = tr.sent.length;
      await tester.pump(const Duration(seconds: 9));
      expect(tr.sent.length, n, reason: 'nothing sent from the background');
      rt.setForeground(true);
    });
  });

  group('privacy chips', () {
    for (final lang in ['en', 'bn']) {
      testWidgets('last seen: 4 choices wrap at 360 dp x1.5 ($lang)',
          (tester) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        String? picked;
        late AppLocalizations t;
        Widget app(String value) => MaterialApp(
              locale: Locale(lang),
              localizationsDelegates: const [
                AppLocalizations.delegate,
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              supportedLocales: AppLocalizations.supportedLocales,
              home: MediaQuery(
                data: const MediaQueryData(
                    size: Size(360, 800), textScaler: TextScaler.linear(1.5)),
                child: Builder(builder: (ctx) {
                  t = AppLocalizations.of(ctx);
                  return Scaffold(
                    body: ListView(children: [
                      CircleVisibilityRow(
                          field: 'last_seen',
                          value: value,
                          onChanged: (v) => picked = v),
                    ]),
                  );
                }),
              ),
            );
        await tester.pumpWidget(app('everyone'));
        await tester.pump();
        for (final v in ['everyone', 'contacts', 'family', 'nobody']) {
          expect(find.byKey(Key('cp-vis-last_seen-$v')), findsOneWidget);
        }
        expect(find.text(t.cpPrivMyContacts), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'no overflow');
        await tester.tap(find.byKey(const Key('cp-vis-last_seen-contacts')));
        expect(picked, 'contacts');
        expect(find.byKey(const Key('cp-recip-last_seen')), findsNothing);
        await tester.pumpWidget(app('nobody'));
        await tester.pump();
        expect(find.text(t.cpPrivLastSeenReciprocal), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('profile photo keeps the 3-way segmented choice',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
            body: CircleVisibilityRow(
                field: 'profile_photo', value: 'everyone', onChanged: (_) {})),
      ));
      await tester.pump();
      expect(find.byType(SegmentedButton<String>), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNothing);
    });
  });
}
