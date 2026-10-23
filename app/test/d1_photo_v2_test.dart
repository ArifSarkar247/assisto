// d1-photo v2: queued server jobs (photo worker) are polled honestly, FACE
// LOCK badge only when the check really ran, one-tap templates, free AI
// "gift" funding, consent for other people, "Report this AI image".
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/photo_studio/ps_controller.dart';
import 'package:assisto/photo_studio/ps_models.dart';
import 'package:assisto/screens/photo_studio_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ps1_fakes.dart';

/// The worker answers "queued" first, then "done" with a FACE LOCK report.
class QueueBackend extends FakePsBackend {
  QueueBackend({super.free = false, this.restored = false})
      : super(entryDue: false, restoreReady: true, providerReady: true);
  final bool restored;
  int polls = 0;
  int? queuedId;

  @override
  Future<PsConfig> config() async {
    final base = await super.config();
    return PsConfig(
      plan: base.plan,
      free: base.free,
      features: {
        ...base.features,
        'enhance_server': FeatureQuote(
            ok: true,
            reason: 'ok',
            options: free
                ? const [FundingOption('ads', ads: 1)]
                : const [FundingOption('free')]),
        if (free)
          'prompt_edit': const FeatureQuote(ok: true, reason: 'ok', options: [
            FundingOption('gift', trial: true),
            FundingOption('credits', credits: 9)
          ]),
      },
      providerReady: true,
      templates: const [
        PsTemplate('hd_portrait', PsFeature.enhanceServer, 'HD portrait'),
        PsTemplate('linkedin', PsFeature.promptEdit, 'Professional / LinkedIn'),
      ],
      limits: const {'free_enhance_per_day': 3, 'free_enhance_ads': 1, 'free_gen_lifetime': 2},
      usage: const {'enhance_today': 1, 'gen_lifetime': 0},
      isOwner: base.isOwner,
    );
  }

  Map<String, dynamic> _done(int id) => {
        'id': id,
        'feature': 'enhance_server',
        'status': 'done',
        'preview': '/api/v1/m/p.png',
        'face_lock': {
          'faces': 1,
          'kept': restored ? 0 : 1,
          'restored': restored ? 1 : 0,
          'min_score': 0.97,
          'action': restored ? 'restored_original_face' : 'kept',
        },
      };

  @override
  Future<PsReply> run(int id, {String imageB64 = '', List<List<double>>? faceBoxes}) async {
    queuedId = id;
    return PsReply(202, {
      'ok': true,
      'job': {'id': id, 'feature': 'enhance_server', 'status': 'queued', 'queue_position': 2}
    });
  }

  @override
  Future<PsReply> job(int id) async {
    if (id == queuedId) {
      polls++;
      return PsReply(200, {
        'ok': true,
        'job': polls < 2
            ? {'id': id, 'feature': 'enhance_server', 'status': 'running'}
            : _done(id)
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
  test('queued HD enhance is polled until done; FACE LOCK result kept per version', () async {
    final b = QueueBackend();
    final c = PhotoStudioController(fakeDeps(b))..pollEvery = Duration.zero;
    await c.init();
    await c.pick(camera: false);
    await c.runRestore(PsFeature.enhanceServer, ScriptUi([]));
    expect(b.polls, 2);
    expect(c.session!.edited, isTrue);
    expect(c.currentFaceLock!.locked, isTrue);
    expect(c.currentFaceLock!.score, 0.97);
    expect(c.busy, isFalse);
  });

  test('still running after the wait -> honest notice, no fake result', () async {
    final b = QueueBackend();
    final c = PhotoStudioController(fakeDeps(b))
      ..pollEvery = const Duration(milliseconds: 1)
      ..pollMax = Duration.zero;
    await c.init();
    await c.pick(camera: false);
    await c.runRestore(PsFeature.enhanceServer, ScriptUi([]));
    expect(c.notice, PsNotice.stillWorking);
    expect(c.session!.edited, isFalse);
  });

  test('free AI: the lifetime gift is used first (no ads); consent sent for others', () async {
    final b = QueueBackend(free: true);
    final c = PhotoStudioController(fakeDeps(b))..pollEvery = Duration.zero;
    await c.init();
    await c.pick(camera: false);
    c.setOthers(true);
    c.setConsent(true);
    await c.runTemplate(c.config.templates[1], ScriptUi([]));
    expect(b.lastBody['via'], 'gift');
    expect(b.lastBody['template'], 'linkedin');
    expect(b.lastBody['consent'], isTrue);
  });

  test('report this AI image', () async {
    final b = QueueBackend();
    final c = PhotoStudioController(fakeDeps(b))..pollEvery = Duration.zero;
    await c.init();
    await c.pick(camera: false);
    await c.runRestore(PsFeature.enhanceServer, ScriptUi([]));
    await c.reportCurrent('face_changed');
    expect(b.reports, ['face_changed']);
    expect(c.notice, PsNotice.reported);
  });

  testWidgets('badge + templates + report button on screen', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final b = QueueBackend(restored: true);
    final c = PhotoStudioController(fakeDeps(b))..pollEvery = Duration.zero;
    await tester.runAsync(() async {
      await c.init();
      await c.pick(camera: false);
      await c.runRestore(PsFeature.enhanceServer, ScriptUi([]));
    });
    await tester.pumpWidget(_app(PhotoStudioScreen(controller: c)));
    await tester.pump();
    expect(find.byKey(const Key('psFaceLock')), findsOneWidget);
    expect(find.text('Face Lock: your original face was put back'), findsOneWidget);
    expect(find.byKey(const Key('psReportAi')), findsOneWidget);
    expect(find.byKey(const Key('psTpl_hd_portrait')), findsOneWidget);
    expect(find.byKey(const Key('psTpl_linkedin')), findsOneWidget);
  });
}
