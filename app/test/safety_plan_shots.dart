// safety-plan (board row 49): gallery shots of the family safety plan —
// empty, our plan, a plan shared with me, no internet (saved copy), edit.
// Made-up people and places only.
import 'package:flutter/widgets.dart';

import 'package:assisto/offline/offline_store.dart';
import 'package:assisto/safety_plan/safety_plan_screen.dart';

String _n(bool bn, String en, String b) => bn ? b : en;

Map<String, dynamic> _overview(String l, {bool empty = false}) {
  final bn = l == 'bn';
  final members = [
    {'member_id': 11, 'name': _n(bn, 'Mother', 'আম্মু'), 'relation': 'mother', 'phone': '01711000002', 'on_assisto': true},
    {'member_id': 12, 'name': _n(bn, 'Father', 'আব্বু'), 'relation': 'father', 'phone': '01711000003', 'on_assisto': true},
    {'member_id': 13, 'name': _n(bn, 'Uncle', 'মামা'), 'relation': 'uncle', 'phone': '01711000005', 'on_assisto': false},
  ];
  final defaults = [
    {'number': '999', 'label': _n(bn, 'National emergency (police, fire, ambulance)', 'জাতীয় জরুরি সেবা (পুলিশ, ফায়ার, অ্যাম্বুলেন্স)')},
    {'number': '109', 'label': _n(bn, 'Violence against women & children', 'নারী ও শিশু নির্যাতন প্রতিরোধ')},
    {'number': '1098', 'label': _n(bn, 'Child helpline', 'শিশু সহায়তা')},
  ];
  final plan = {
    'meeting_point': {'name': _n(bn, 'Sample Park main gate', 'নমুনা পার্কের মূল গেট'), 'lat': 23.78, 'lng': 90.40,
      'note': _n(bn, 'by the tea stall', 'চায়ের দোকানের পাশে')},
    'meeting_point_far': {'name': _n(bn, "Uncle's house, Sample Road 5", 'মামার বাসা, নমুনা রোড ৫')},
    'numbers': [defaults[0], defaults[2], {'number': '01711000777', 'label': _n(bn, 'Family doctor', 'পারিবারিক ডাক্তার')}],
    'call_order': [
      {'member_id': 11, 'name': members[0]['name'], 'phone': '01711000002', 'is_you': false},
      {'member_id': 12, 'name': members[1]['name'], 'phone': '01711000003', 'is_you': false},
      {'member_id': 13, 'name': members[2]['name'], 'phone': '01711000005', 'is_you': false},
    ],
    'shared_with': [
      {'member_id': 11, 'name': members[0]['name']},
      {'member_id': 12, 'name': members[1]['name']},
    ],
    'note': '',
    'updated_at': '2026-11-18T08:00:00Z',
  };
  return {
    'mine': empty ? null : plan,
    'shared': empty
        ? []
        : [
            {'owner_id': 7, 'owner_name': _n(bn, 'Rina', 'রিনা'),
              'plan': {...plan, 'shared_with': null, 'call_order': [
                {'member_id': 31, 'name': _n(bn, 'Rina', 'রিনা'), 'phone': '01711000009', 'is_you': false},
              ]}},
          ],
    'members': members,
    'defaults': defaults,
  };
}

Widget _screen(String l, {bool empty = false, bool offline = false}) {
  safetyPlanLoaderOverride = offline
      ? () async => throw Exception('offline')
      : () async => _overview(l, empty: empty);
  if (offline) {
    OfflineStore.instance.currentUid = 1;
    OfflineStore.instance.write(1, kSafetyPlanSlot,
        {'at': '2026-11-18T08:00:00Z', 'data': _overview(l)});
  }
  return const SafetyPlanScreen();
}

Widget _edit(String l) {
  final o = _overview(l);
  return SafetyPlanEditScreen(
      initial: splBodyFrom((o['mine'] as Map).cast<String, dynamic>()),
      members: [for (final m in o['members'] as List) (m as Map).cast<String, dynamic>()],
      defaults: [for (final m in o['defaults'] as List) (m as Map).cast<String, dynamic>()]);
}

final Map<String, Widget Function(String)> safetyPlanShots = {
  'spl_empty': (l) => _screen(l, empty: true),
  'spl_plan': (l) => _screen(l),
  'spl_offline': (l) => _screen(l, offline: true),
  'spl_edit': _edit,
};
