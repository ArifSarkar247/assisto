// career — the career lane's emulator proof (board rows 28, 29, 32) against
// the throw-away Django with the CI fakes (settings_e2eproof + seed_career;
// .github/workflows/career-proof.yml, REALITY_ONLY=start,career). The AI is
// the CI fake (backend/ci_e2e/fakes.py) — never a real model, never the live
// server.
//
//   cr01  A builds a CV in Bangla in the real UI (name, headline, place,
//         education, experience, skills) -> export screen: CV language
//         Bangla + government style + summary -> the server makes the Bangla
//         PDF; it is saved as evidence (reality_out/device/career_cv_bn.pdf,
//         + the English one) for a shaping / clipping review.
//   cr02  mock interview, Bank officer role, 3 typed answers -> rubric
//         feedback each; AI feedback on Q1 -> charged once (the fake AI is
//         called exactly once; the repeat is the saved feedback, charged 0)
//         -> "End here" -> per-question summary.
//   cr03  certificate: the real claim sheet with a server-signed course
//         result -> card with code + QR -> the PUBLIC page /verify/<code>
//         says valid with the chosen name only; a tampered code says
//         not found.
// Honest limits: no microphone on the CI emulator (voice answers land in the
// same answer box — typed here); the share sheet of "Download PDF" is not
// tapped (an Android chooser would cover the app), so the PDF is fetched
// with the same request the button makes.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:assisto/api.dart';
import 'package:assisto/config.dart';
import 'package:assisto/screens/career/interview_role_screen.dart';
import 'package:assisto/screens/cv_builder_screen.dart';
import 'package:assisto/screens/learn_cert_screen.dart';

import '../support/harness.dart';

const _bnName = 'রিয়েলিটি নাদিয়া ইসলাম';

Future<int> _aiCalls(ApiClient api, double since) async {
  final r = await api.getJson('/ci-e2e/outbox?kind=ai&user=me&since=$since');
  return ((r['rows'] as List?) ?? const []).length;
}

Future<double> _now(ApiClient api) async =>
    ((await api.getJson('/ci-e2e/outbox?kind=none'))['now'] as num).toDouble();

Future<Map<String, dynamic>> _cvRow(ApiClient api) async {
  final rows = await api.listItems('cv');
  if (rows.isEmpty) throw TestFailure('no cv row on the server');
  return rows.first;
}

void registerCareerFlows() {
  realityFlow('cr01_cv_bangla_pdf', 'Career',
      'CV builder: Bangla CV in the UI -> Bangla style/summary -> Bangla A4 PDF (evidence file)',
      (f) async {
    await f.home();
    final api = await f.h.backend();
    await f.step('A fills a Bangla CV in the builder (UI)', () async {
      await f.pushScreen(const CvBuilderScreen());
      if (await f.appears(find.text(f.t.cvStart), seconds: 4)) {
        await f.tap(find.text(f.t.cvStart));
      }
      await f.enter(_bnName, label: f.t.cvFullName);
      await f.enter('জুনিয়র হিসাবরক্ষক · ব্যাংকিং', label: f.t.cvHeadline);
      await f.enter('মিরপুর ১০, ঢাকা', label: f.t.cvLocation);
      await f.tap(find.text(f.t.cvAddEducation));
      await f.enter('বিবিএ (হিসাববিজ্ঞান)', label: f.t.cvDegree);
      await f.enter('ঢাকা কলেজ', label: f.t.cvInstitution);
      await f.enter('২০২২', label: f.t.cvYear);
      await f.tap(find.text(f.t.cvDone).last, settleSeconds: 2);
      await f.tap(find.text(f.t.cvAddExperience));
      await f.enter('হিসাব সহকারী', label: f.t.cvJobTitle);
      await f.enter('র‍্যাব সমবায় সমিতি', label: f.t.cvOrganisation);
      await f.enter('২০২২–২০২৪', label: f.t.cvDates);
      await f.enter('মাসে ৩০০টি ভাউচার মিলিয়ে দেখা\nক্ষুদ্র ঋণের কিস্তি ও ভ্যাট রিটার্ন তৈরি', label: f.t.cvBullets);
      await f.tap(find.text(f.t.cvDone).last, settleSeconds: 2);
      for (final s in ['ট্যালি', 'এক্সেল', 'গ্রাহক সেবা']) {
        await f.tap(find.text(f.t.cvAddSkill));
        await f.enter(s, label: f.t.cvSkillLabel);
        await f.tap(find.text(f.t.cvDone).last, settleSeconds: 2);
      }
      await f.shot('cv_builder_bn');
    });
    await f.step('Export: CV language Bangla + government style + summary (UI, saved)', () async {
      await f.tap(find.text(f.t.crrCvExportAction), settleSeconds: 4);
      await f.waitFor(find.byKey(const ValueKey('crr-lang-bn')), what: 'CV export screen');
      await f.tap(find.text(f.t.crrFmtGovt));
      await f.tap(find.byKey(const ValueKey('crr-lang-bn')));
      await f.tester.enterText(find.byKey(const ValueKey('crr-summary')),
          'প্রত্যেক মাসের হিসাব নির্ভুল রাখি; ক্ষুদ্র ঋণ, ভ্যাট ও গ্রাহক সেবায় দুই বছরের অভিজ্ঞতা।');
      await f.pumpFor(const Duration(milliseconds: 500));
      await f.tap(find.byKey(const ValueKey('crr-save-details')), settleSeconds: 3);
      f.expectHttp('PATCH', '/cv/');
      final row = await f.net(() => _cvRow(api));
      if (row['cv_lang'] != 'bn' || row['format'] != 'govt') {
        throw TestFailure('server row not saved as Bangla/govt: ${row['cv_lang']} ${row['format']}');
      }
      if (row['name'] != _bnName) throw TestFailure('name not saved: ${row['name']}');
      await f.scrollTo(find.byKey(const ValueKey('crr-pdf')));
      await f.shot('cv_export_pdf_button');
    });
    await f.step('Server makes the Bangla A4 PDF (same request as the button) -> evidence', () async {
      final bn = await f.net(() => api.getBytes('/career/cv/pdf?lang=bn'));
      final en = await f.net(() => api.getBytes('/career/cv/pdf?lang=en'));
      final head = String.fromCharCodes(bn.take(5));
      if (head != '%PDF-' || bn.length < 4000) {
        throw TestFailure('not a real PDF: "$head" ${bn.length} bytes');
      }
      final latin = String.fromCharCodes(bn);
      // (the page streams are compressed; the embedded faces + A4 box are not)
      for (final want in ['AssistoAsBn', 'FontFile2', '595.27']) {
        if (!latin.contains(want)) throw TestFailure('PDF misses $want');
      }
      await f.net(() async {
        final d = await f.h.outDir();
        await File('${d.path}/career_cv_bn.pdf').writeAsBytes(bn);
        await File('${d.path}/career_cv_en.pdf').writeAsBytes(en);
      });
      f.note('PDF bn ${bn.length} B, en ${en.length} B saved as career_cv_*.pdf');
    });
  });

  realityFlow('cr02_mock_interview_3q', 'Career',
      'Mock interview: Bank officer, 3 typed answers -> feedback; AI feedback charged once (CI fake AI)',
      (f) async {
    await f.home();
    final api = await f.h.backend();
    final t0 = await f.net(() => _now(api));
    // the server's Bank officer order: bk1 why a bank, bk2 KYC, bk3 angry customer
    const answers = [
      'I want to work in a bank because I like finance and serving customers. Trust is the base of '
          'banking and I want to build a long career here. As a result of my internship I know the basics.',
      'KYC means know your customer: we check identity with the NID and other papers. It stops money '
          'laundering and fraud, and the risk review is updated every year for each customer.',
      'I listen to the customer calmly, say sorry for the trouble, find a solution with a clear '
          'timeline and follow up the next day. For example, I solved 20 card complaints in one week.',
    ];
    await f.step('Open the role interview -> Bank officer (UI)', () async {
      await f.pushScreen(const InterviewRoleScreen());
      await f.tap(find.byKey(const ValueKey('crr-role-bank')), settleSeconds: 3);
      f.expectHttp('GET', '/career/interview/roles/bank');
      await f.waitFor(find.byKey(const ValueKey('crr-answer')), what: 'question 1');
      await f.shot('interview_q1');
    });
    for (var i = 0; i < 3; i++) {
      await f.step('Q${i + 1}: typed answer -> rubric feedback (UI)', () async {
        final since = f.h.recorder.hits.length;
        await f.tester.enterText(find.byKey(const ValueKey('crr-answer')), answers[i]);
        await f.pumpFor(const Duration(milliseconds: 400));
        await f.tap(find.byKey(const ValueKey('crr-submit')), settleSeconds: 3);
        f.expectHttp('POST', '/career/interview/feedback', since: since);
        await f.waitFor(find.byKey(const ValueKey('crr-next')), what: 'feedback for Q${i + 1}');
        await f.waitFor(find.textContaining(RegExp(r'^Score: \d+ out of 100$')), what: 'score');
        if (i == 0) {
          await f.tap(find.byKey(const ValueKey('crr-ai')), settleSeconds: 4);
          await f.waitFor(find.byKey(const ValueKey('crr-ai-cost')), seconds: 25, what: 'AI feedback + cost line');
          await f.shot('interview_ai_feedback');
          // a retry of the SAME answer (dropped network / second tap) must not
          // call (= charge) the AI again
          final again = await f.net(() => api.postJson('/career/interview/feedback',
              {'qid': 'bk1', 'answer': answers[0], 'lang': 'en', 'ai': true}));
          final ai = (again['ai'] as Map?) ?? const {};
          if (ai['cached'] != true || ai['charged'] != 0) {
            throw TestFailure('repeat was charged again: $ai');
          }
          final calls = await f.net(() => _aiCalls(api, t0));
          if (calls != 1) throw TestFailure('fake AI called $calls times for one answer (want 1)');
          f.note('AI feedback: 1 fake-AI call for 2 requests; repeat cached, charged 0');
        } else {
          await f.shot('interview_q${i + 1}_feedback');
        }
        if (i < 2) await f.tap(find.byKey(const ValueKey('crr-next')), settleSeconds: 2);
      });
    }
    await f.step('End here -> summary with the 3 questions and their scores (UI)', () async {
      await f.tap(find.byKey(const ValueKey('crr-end')), settleSeconds: 2);
      await f.waitFor(find.byKey(const ValueKey('crr-done-avg')), what: 'summary');
      final rows = find.textContaining(RegExp(r'^Question [123]: \d+ out of 100$'));
      if (rows.evaluate().length != 3) {
        throw TestFailure('summary shows ${rows.evaluate().length} question rows (want 3)');
      }
      await f.shot('interview_summary');
    });
  });

  realityFlow('cr03_certificate_verify', 'Career',
      'Certificate: claim sheet -> card with code + QR -> public verify page valid; tampered code invalid',
      (f) async {
    await f.home();
    final api = await f.h.backend();
    late String code;
    const chosen = 'Reality Nadia';
    await f.step('A claims the certificate for a server-signed result (UI sheet)', () async {
      final tok = await f.net(() => api.postJson('/ci-e2e/learncert-token',
          {'course': 'lang_en', 'level': 'B1', 'score': 78}));
      final ctx = f.tester.element(find.byType(Scaffold).first);
      unawaited(courseResult(ctx, course: 'lang_en', level: 'B1', score: 78, token: '${tok['token']}'));
      await f.waitFor(find.text(f.t.lcEarnedTitle), what: 'claim sheet');
      await f.enter(chosen, label: f.t.lcNameLabel);
      await f.shot('cert_claim_sheet');
      await f.tap(find.text(f.t.lcGetCert), settleSeconds: 4);
      f.expectHttp('POST', '/learn/certs/claim');
      final list = await f.net(() => api.getJson('/learn/certs'));
      final items = ((list['items'] as List?) ?? const []).cast<Map>();
      final mine = items.firstWhere((x) => x['name'] == chosen,
          orElse: () => throw TestFailure('no certificate named "$chosen": $items'));
      code = '${mine['code']}';
      await f.waitFor(find.textContaining(code), what: 'card with the verify code');
      await f.shot('cert_card_qr');
    });
    await f.step('Public page /verify/<code> says VALID, only the chosen name', () async {
      final r = await f.net(() => http.get(Uri.parse('${AppConfig.apiBase}/verify/$code?lang=en')));
      if (r.statusCode != 200) throw TestFailure('verify answered ${r.statusCode}');
      final body = r.body;
      for (final want in ['genuine and valid', chosen]) {
        if (!body.contains(want)) throw TestFailure('verify page misses "$want"');
      }
      for (final leak in [Seed.phoneA, '78/100']) {
        if (body.contains(leak)) throw TestFailure('verify page leaks "$leak"');
      }
      f.note('verify $code -> 200 valid');
    });
    await f.step('A tampered code says NOT FOUND (and never shows the name)', () async {
      final last = code.substring(code.length - 1);
      final bad = code.substring(0, code.length - 1) + (last == 'A' ? 'B' : 'A');
      final r = await f.net(() => http.get(Uri.parse('${AppConfig.apiBase}/verify/$bad?lang=en')));
      if (r.statusCode != 404) throw TestFailure('tampered code answered ${r.statusCode}');
      if (!r.body.contains('No certificate was found') || r.body.contains(chosen)) {
        throw TestFailure('tampered page is not an honest "not found"');
      }
      f.note('tampered $bad -> 404 not found');
    });
  });
}
