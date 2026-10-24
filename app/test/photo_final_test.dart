// photo-final: Natural/Strong + portrait blur sent to the server, free
// enhances left, Ultra HD only when the server says it works, honest "in
// queue (budget)" message, capability parsing — never a dead button.
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/photo_studio/ps_controller.dart';
import 'package:assisto/photo_studio/ps_models.dart';
import 'package:assisto/screens/photo_studio_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ps1_fakes.dart';

class FinalBackend extends FakePsBackend {
  FinalBackend({super.free = true, this.blurCap = true, this.ultra = false, this.budgetWait = false})
      : super(entryDue: false, restoreReady: true, providerReady: false);
  final bool blurCap, ultra, budgetWait;
  int? queuedId;

  @override
  Future<PsConfig> config() async {
    final base = await super.config();
    return PsConfig.fromJson({
      'plan': free ? 'free' : 'premium',
      'free': free,
      'features': {
        'enhance_server': {
          'ok': true,
          'reason': 'ok',
          'free_left': 2,
          'options': [
            {'via': 'gift'}
          ],
        },
        'ultra_hd': ultra
            ? {
                'ok': true,
                'reason': 'ok',
                'left_month': 4,
                'options': [
                  {'via': 'free'}
                ]
              }
            : {'ok': false, 'reason': free ? 'premium_only' : 'provider_missing', 'options': []},
      },
      'enhance': {
        'bg_blur': blurCap,
        'face_lock': true,
        'face_restore': false,
        'providers': <String>[],
        'ultra_hd': {'available': ultra}
      },
      'is_owner': base.isOwner,
    });
  }

  int _id = 500;

  /// The server decided "free (gift)" — the job comes back already funded.
  @override
  Future<PsReply> createJob(Map<String, dynamic> body) async {
    lastBody = body;
    final id = _id++;
    return PsReply(201, {
      'ok': true,
      'job': {'id': id, 'feature': body['feature'], 'status': 'funded', 'funding': body['via'] ?? 'free'}
    });
  }

  @override
  Future<PsReply> run(int id, {String imageB64 = '', List<List<double>>? faceBoxes}) async {
    queuedId = id;
    return PsReply(202, {
      'ok': true,
      'job': {
        'id': id,
        'feature': 'enhance_server',
        'status': 'queued',
        'queue_position': 1,
        if (budgetWait) 'flags': {'waiting': 'spend_cap'},
      }
    });
  }

  @override
  Future<PsReply> job(int id) async {
    if (id == queuedId) {
      return PsReply(200, {
        'ok': true,
        'job': budgetWait
            ? {'id': id, 'feature': 'enhance_server', 'status': 'queued', 'flags': {'waiting': 'spend_cap'}}
            : {'id': id, 'feature': 'enhance_server', 'status': 'done', 'preview': '/api/v1/m/p.png'}
      });
    }
    return super.job(id);
  }
}

Widget _app(Widget home) => MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );

void main() {
  test('capability + free-left + ultra quota parse defensively', () {
    final c = PsConfig.fromJson({
      'features': {
        'enhance_server': {'ok': true, 'reason': 'ok', 'free_left': 3},
        'ultra_hd': {'ok': true, 'reason': 'ok', 'left_month': 5},
      },
      'enhance': {
        'bg_blur': true,
        'face_lock': true,
        'providers': ['replicate'],
        'ultra_hd': {'available': true}
      },
    });
    expect(c.quote(PsFeature.enhanceServer).freeLeft, 3);
    expect(c.quote(PsFeature.ultraHd).leftMonth, 5);
    expect(c.enhanceCap.bgBlur, isTrue);
    expect(c.enhanceCap.ultraAvailable, isTrue);
    expect(c.enhanceCap.providers, ['replicate']);
    expect(PsConfig.fromJson(const {}).enhanceCap.bgBlur, isFalse);
    expect(PsFeatureWire.fromWire('ultra_hd'), PsFeature.ultraHd);
  });

  test('Strong + portrait blur are sent; a free enhance goes as a gift', () async {
    final b = FinalBackend();
    final c = PhotoStudioController(fakeDeps(b))..pollEvery = Duration.zero;
    await c.init();
    await c.pick(camera: false);
    c.setStrength(EditStrength.strong);
    c.setPortraitBlur(true);
    await c.runRestore(PsFeature.enhanceServer, ScriptUi([]));
    expect(b.lastBody['feature'], 'enhance_server');
    expect(b.lastBody['strength'], 'strong');
    expect(b.lastBody['bg_blur'], isTrue);
    expect(b.lastBody['via'], 'gift');
    expect(c.session!.edited, isTrue);
  });

  test('portrait blur is never sent when the server cannot do it', () async {
    final b = FinalBackend(blurCap: false);
    final c = PhotoStudioController(fakeDeps(b))..pollEvery = Duration.zero;
    await c.init();
    await c.pick(camera: false);
    c.setPortraitBlur(true);
    await c.runRestore(PsFeature.enhanceServer, ScriptUi([]));
    expect(b.lastBody['bg_blur'], isFalse);
  });

  test('waiting for tomorrow\'s budget -> honest queue notice, no fake result', () async {
    final b = FinalBackend(budgetWait: true);
    final c = PhotoStudioController(fakeDeps(b))..pollEvery = Duration.zero;
    await c.init();
    await c.pick(camera: false);
    await c.runRestore(PsFeature.enhanceServer, ScriptUi([]));
    expect(c.notice, PsNotice.queuedBudget);
    expect(c.session!.edited, isFalse);
  });

  testWidgets('HD enhance card: presets, blur switch, free left; Ultra only when offered',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 3200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final b = FinalBackend();
    final c = PhotoStudioController(fakeDeps(b));
    await tester.runAsync(() async {
      await c.init();
      await c.pick(camera: false);
    });
    await tester.pumpWidget(_app(PhotoStudioScreen(controller: c)));
    await tester.pump();
    expect(find.byKey(const Key('pfPreset')), findsOneWidget);
    expect(find.byKey(const Key('pfBlur')), findsOneWidget);
    expect(find.byKey(const Key('pfEnhance')), findsOneWidget);
    expect(find.text('2 free HD enhances left'), findsOneWidget);
    expect(find.byKey(const Key('pfUltra')), findsNothing); // free user: no Ultra button
  });

  testWidgets('Premium with fal.ai connected sees Ultra HD with the monthly count', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 3200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final b = FinalBackend(free: false, ultra: true);
    final c = PhotoStudioController(fakeDeps(b));
    await tester.runAsync(() async {
      await c.init();
      await c.pick(camera: false);
    });
    await tester.pumpWidget(_app(PhotoStudioScreen(controller: c)));
    await tester.pump();
    expect(find.byKey(const Key('pfUltra')), findsOneWidget);
    expect(find.text('Ultra HD (4 left this month)'), findsOneWidget);
  });
}
