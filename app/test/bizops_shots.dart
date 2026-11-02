// bizops: gallery states for test/screenshots_test.dart (and the a11y sweep)
// — the morning business card, its honest states and a card tap's run
// (approval card; after approval the WhatsApp button). Fake server only.
import 'package:flutter/material.dart';

import 'package:assisto/screens/agent_core/agent_core_source.dart';
import 'package:assisto/screens/agent_core/biz_brief_screen.dart';

import 'bizops_fakes.dart';

final Map<String, Widget Function(String)> bizopsShots = {
  'bizops_card': (l) =>
      BizBriefScreen(source: FakeBizBrief('data', bn: l == 'bn'), agentSource: BoAgentFake(bn: l == 'bn')),
  'bizops_empty': (l) =>
      BizBriefScreen(source: FakeBizBrief('empty', bn: l == 'bn'), agentSource: BoAgentFake(bn: l == 'bn')),
  'bizops_no_shop': (l) => BizBriefScreen(
      source: FakeBizBrief('no_business', bn: l == 'bn'), agentSource: BoAgentFake(bn: l == 'bn')),
  'bizops_offline': (l) => BizBriefScreen(
      source: FakeBizBrief('offline', bn: l == 'bn'), agentSource: BoAgentFake(bn: l == 'bn')),
  'bizops_run_approval': (l) => BizRunScreen(
      source: BoAgentFake(bn: l == 'bn'),
      run: AcRun.fromJson(boRunJson('waiting_approval', bn: l == 'bn')),
      pollSchedule: const []),
  'bizops_run_whatsapp': (l) => BizRunScreen(
      source: BoAgentFake(bn: l == 'bn'),
      run: AcRun.fromJson(boRunJson('done', bn: l == 'bn')),
      pollSchedule: const []),
};
