// mktengine: gallery states for test/screenshots_test.dart (and therefore the
// launch Bangla sweep, a11y sweep and dead-button sweep) — Marketing Engine.
import 'package:flutter/material.dart';

import 'package:assisto/screens/mktengine/mkt_engine_screen.dart';
import 'package:assisto/screens/mktengine/mkt_questionnaire.dart';

import 'mktengine_fakes.dart';

FakeMkt _f(String mode, String l) => FakeMkt(mode, l == 'bn');

final Map<String, Widget Function(String)> mktengineShots = {
  'mkt_welcome': (l) => MktEngineScreen(source: _f('empty', l)),
  'mkt_welcome_started': (l) => MktEngineScreen(source: _f('started', l)),
  'mkt_plan_content': (l) => MktEngineScreen(source: _f('data', l)),
  'mkt_plan_campaign': (l) => MktEngineScreen(source: _f('data', l), initialSection: 'campaign'),
  'mkt_plan_conversion': (l) => MktEngineScreen(source: _f('data', l), initialSection: 'conversion'),
  'mkt_plan_no_retention': (l) => MktEngineScreen(source: _f('noretention', l), initialSection: 'conversion'),
  'mkt_feature_off': (l) => MktEngineScreen(source: _f('off', l)),
  'mkt_load_error': (l) => MktEngineScreen(source: _f('fail', l)),
  'mkt_q_single': (l) {
    final f = _f('empty', l);
    return MktQuestionnaireScreen(source: f, questions: f.questions);
  },
  'mkt_q_text': (l) {
    final f = _f('empty', l);
    return MktQuestionnaireScreen(source: f, questions: f.questions, initialStep: 1);
  },
  'mkt_q_multi': (l) {
    final f = _f('empty', l);
    return MktQuestionnaireScreen(
        source: f, questions: f.questions, answers: const {'channels': ['facebook']}, initialStep: 2);
  },
};
