// gap-lp: Language Partner on the emulator, through the UI, against the
// in-runner Django (seed_reality allow-lists demo user A for language_packs
// and runs lp_seed = Assisto's own original IELTS mocks; nothing from any
// book). Start page -> IELTS -> one Reading section (the real timer) ->
// Submit asks first (Keep going stays) -> Submit -> the SERVER marks it ->
// result with the practice label; the free weekly section is used up on the
// server. AI scoring / the certificate need Premium + AI — widget + backend
// tests cover them (app/test/gaplp_test.dart, backend/core/tests_gaplp.py).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/api.dart';

import '../support/harness.dart';

Finder _keyLike(bool Function(String k) test) => find.byWidgetPredicate((w) {
      final k = w.key;
      return k is ValueKey<String> && test(k.value);
    });

void registerLpFlows() {
  realityFlow('lp1_ielts_section', 'Language Partner',
      'Start -> IELTS -> Reading section -> Submit asks first -> server marks -> result', (f) async {
    await f.home();
    await f.step('open Language Partner (start page)', () async {
      await f.openFeature(f.t.lpTitle, 'language_partner');
      await f.waitFor(find.byKey(const Key('lp2-ielts')), what: 'the IELTS card');
      await f.waitFor(find.byKey(const Key('lp2-life')), what: 'the Life English card');
      await f.shot('lp-start');
    });
    await f.step('IELTS -> mock list from the server', () async {
      final mark = f.httpMark;
      await f.tap(find.text(f.t.lp2MockTests), settleSeconds: 3);
      final sec = _keyLike((k) => k.startsWith('lp2-sec-') && k.endsWith('-reading'));
      await f.scrollTo(sec);
      await f.waitFor(sec, what: 'a Reading section button (lp_seed mocks)');
      f.expectHttp('GET', '/lp/mocks', since: mark);
      await f.shot('lp-hub');
    });
    await f.step('open one Reading section (real timer)', () async {
      final sec = _keyLike((k) => k.startsWith('lp2-sec-') && k.endsWith('-reading'));
      await f.tap(sec, settleSeconds: 4);
      await f.waitFor(find.text(f.t.lp2PracticeMode), what: 'section practice runner');
      await f.waitFor(find.byKey(const Key('lp2-submit')));
      await f.shot('lp-reading');
    });
    await f.step('Submit asks first; Keep going stays on the section', () async {
      await f.tap(find.byKey(const Key('lp2-submit')));
      await f.waitFor(find.text(f.t.lp2gSubmitTitle), what: 'the submit confirm sheet');
      await f.shot('lp-submit-confirm');
      await f.tap(find.text(f.t.lp2KeepGoing));
      await f.waitFor(find.text(f.t.lp2PracticeMode));
    });
    await f.step('Submit -> marked by the server -> result + practice label', () async {
      final mark = f.httpMark;
      await f.tap(find.byKey(const Key('lp2-submit')));
      await f.tap(find.byKey(const Key('lp2-submit-confirm')), settleSeconds: 5);
      await f.waitFor(find.text(f.t.lp2ResultTitle), seconds: 25, what: 'the result screen');
      f.expectHttp('POST', '/lp/mocks/', since: mark);
      await f.shot('lp-result');
      final api = ApiClient.detached(f.app.api.token ?? '');
      await f.eventually('the free weekly section is used on the server', () async {
        final r = await api.getJson('/lp/mocks?kind=academic');
        return r['premium'] == true || (r['free_sections_left_week'] as num?) == 0;
      });
    });
  });
}
