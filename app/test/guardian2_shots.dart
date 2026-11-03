// guardian2 (PART 6 two guardians) gallery shots — real screens, fixed data:
//   g2_guardians       the Guardians page: who can see me (since when), a
//                      request that can NOT see yet, a request to approve,
//                      a co-guardian (remove), join with a code
//   g2_sos_responding  an SOS card on the other guardian's phone:
//                      "<name> is responding" + I'm responding
import 'package:flutter/material.dart';

import 'package:assisto/screens/circle_guardians_screen.dart';
import 'package:assisto/screens/family_alerts_screen.dart';
import 'package:assisto/screens/guardian2_panel.dart';

String _n(bool bn, String en, String b) => bn ? b : en;

Widget _guardians(String l) {
  final bn = l == 'bn';
  final mom = _n(bn, 'Mom', 'আম্মু'), dad = _n(bn, 'Dad', 'আব্বু');
  final rina = _n(bn, 'Rina', 'রিনা'), nanu = _n(bn, 'Nanu', 'নানু');
  guardiansLoaderOverride = (path) async {
    if (path.endsWith('mine')) {
      return {
        'guardians': [
          {'id': 10, 'name': mom, 'removable': false, 'since': '2026-09-01T08:00:00+00:00',
            'sources': [{'kind': 'school_mode', 'removable': false, 'set_up_by': mom}]},
          {'id': 11, 'name': dad, 'removable': false, 'since': '2026-11-03T08:00:00+00:00',
            'sources': [{'kind': 'co_guardian', 'removable': false, 'set_up_by': mom}]},
        ],
        'pending': [
          {'id': 7, 'name': _n(bn, 'Uncle', 'চাচা'), 'requested_at': '2026-11-03T09:00:00+00:00'}
        ],
      };
    }
    return {
      'children': [
        {'key': 'u3', 'name': rina, 'child_user_id': 3,
          'sources': [{'kind': 'school_mode'}], 'co_guardians': [{'id': 11, 'name': dad}]},
      ]
    };
  };
  guardian2ApiOverride = (method, path, body) async => {
        'to_approve': [
          {'id': 5, 'state': 'pending', 'child_id': 3, 'child_name': rina,
            'guardian_id': 13, 'guardian_name': nanu, 'max': 2}
        ],
        'invites': [],
        'co_guardians': [
          {'id': 6, 'state': 'approved', 'child_id': 3, 'child_name': rina,
            'guardian_id': 11, 'guardian_name': dad, 'approved_at': '2026-11-03T08:00:00+00:00'}
        ],
        'my_requests': [],
      };
  return const CircleGuardiansScreen();
}

Widget _sos(String l) {
  final bn = l == 'bn';
  return FamilyAlertsScreen(
    pushEnabled: () async => true,
    load: () async => {
      'received': [
        {'id': 41, 'kind': 'sos', 'at': DateTime.now().toIso8601String(),
          'title': _n(bn, 'SOS: Rina needs help', 'জরুরি: রিনার সাহায্য দরকার'),
          'body': _n(bn, 'Call now. Tap to see where she is.', 'এখনই ফোন করুন। কোথায় আছে দেখতে ট্যাপ করুন।'),
          'from_name': _n(bn, 'Rina', 'রিনা'), 'lat': 23.75, 'lng': 90.39,
          'seen': false, 'status': 'sent', 'active': true, 'responding': false,
          'responders': [
            {'name': _n(bn, 'Dad', 'আব্বু'), 'me': false}
          ]},
      ],
      'sent': [],
    },
  );
}

final Map<String, Widget Function(String)> guardian2Shots = {
  'g2_guardians': _guardians,
  'g2_sos_responding': _sos,
};
