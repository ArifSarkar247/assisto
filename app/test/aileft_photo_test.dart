// aileft (owner 3 Nov 23:25 PART 7): Photo Studio
//  * a result whose face changed is never used AND the server is told so it
//    refunds (credits back, export blocked);
//  * AI content edits carry a visible "AI edited" mark on the exported file
//    (every plan), enhance does not;
//  * "Send to My Circle" / "Add to catalog" take the same gated full-quality
//    file as Share without going to the share sheet;
//  * NID size preset (sourced passport size).
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/photo_studio/ps_controller.dart';
import 'package:assisto/photo_studio/ps_edit.dart';
import 'package:assisto/photo_studio/ps_models.dart';

import 'ps1_fakes.dart';

void main() {
  test('face changed -> result dropped + reported for the refund', () async {
    final b = FakePsBackend(free: false, entryDue: false);
    final c = PhotoStudioController(
        fakeDeps(b, landmarks: FakeLandmarks(shiftAfter: 30)));
    await c.init();
    await c.pick(camera: false);
    await c.runPrompt('change the background to a beach', ScriptUi([]));
    expect(c.notice, PsNotice.identityFailed);
    expect(c.session!.versions.length, 1);
    expect(b.reports, ['face_changed']);
  });

  test('AI content edit: "AI edited" mark on export, even on Premium', () async {
    final b = FakePsBackend(free: false, entryDue: false);
    final sink = FakeSink();
    final r = FakeRenderer();
    final c = PhotoStudioController(fakeDeps(b, sink: sink, renderer: r));
    await c.init();
    await c.pick(camera: false);
    await c.runPrompt('make the sky blue', ScriptUi([]));
    expect(c.session!.versions.length, 2);
    expect(c.aiMarkFor(c.session!.current), isTrue);
    expect(b.reports, isEmpty);
    // in-app exit: the file comes back, nothing goes to the share sheet
    final f = await c.exportFile(ScriptUi([]));
    expect(f, isNotNull);
    expect(f!.$1, isNotEmpty);
    expect(f.$2, endsWith('.png'));
    expect(sink.delivered, isEmpty);
    expect(r.marks, [true]);
  });

  test('plain enhance keeps a clean Premium export (no AI mark)', () async {
    final b = FakePsBackend(free: false, entryDue: false);
    final r = FakeRenderer();
    final c = PhotoStudioController(fakeDeps(b, renderer: r));
    await c.init();
    await c.pick(camera: false);
    await c.runEnhance();
    expect(c.aiMarkFor(c.session!.current), isFalse);
  });

  test('NID preset = the sourced passport size, white, 300 dpi', () {
    final nid = PsIdPreset.builtIn.firstWhere((p) => p.id == 'nid_bd');
    expect((nid.wMm, nid.hMm, nid.pxW, nid.pxH, nid.dpi), (45, 55, 531, 650, 300));
    expect(nid.source, startsWith('https://bhclondon.org.uk/nid'));
    expect(PsIdPreset.builtIn.first.id, 'passport_bd');
  });
}
