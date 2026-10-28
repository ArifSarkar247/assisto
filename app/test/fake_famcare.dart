// famcare: gallery / FakeApi GET stubs for Family Care — the server's real
// response shapes (core/famcare.py), so the screenshots show honest states.

Map<String, dynamic>? fakeFamCareGet(String path, {required bool bn, required bool empty}) {
  if (path == '/family/limits') {
    final used = empty ? 0 : 2;
    return {'limit': 5, 'used': used, 'left': 5 - used, 'safety_free': true, 'free_floor': 5};
  }
  if (path == '/family/circle-pick') {
    return {
      'results': empty
          ? const []
          : [
              {'circle_id': 1, 'name': bn ? 'আম্মা' : 'Mother', 'relation': 'mother',
               'custom_label': '', 'phone': '01710000000', 'family_id': 1},
              {'circle_id': 2, 'name': bn ? 'রাফি' : 'Rafi', 'relation': 'brother',
               'custom_label': '', 'phone': '01810000000', 'family_id': null},
            ],
      'limit': 5, 'used': empty ? 0 : 2,
    };
  }
  if (path == '/family/reminders') {
    return {
      'assigned_by_me': empty
          ? const []
          : [
              {'id': 11, 'title': bn ? 'আম্মার ওষুধ কেনা' : "Buy Mother's medicine",
               'due_at': '2026-10-29T18:00:00', 'done': false, 'to_name': bn ? 'রাফি' : 'Rafi'},
              {'id': 12, 'title': bn ? 'বিদ্যুৎ বিল দেওয়া' : 'Pay the electricity bill',
               'due_at': '2026-10-27T10:00:00', 'done': true, 'to_name': bn ? 'আম্মা' : 'Mother'},
            ],
      'assigned_to_me': const [],
    };
  }
  if (path == '/family/shopping') {
    return {
      'lists': [
        {
          'owner_id': 1, 'owner_name': bn ? 'রহিম' : 'Rahim', 'mine': true,
          'shared_with': empty ? 0 : 1,
          'items': empty
              ? const []
              : [
                  {'id': 1, 'text': bn ? 'চাল' : 'Rice', 'qty': bn ? '৫ কেজি' : '5 kg', 'done': false,
                   'added_by': bn ? 'আম্মা' : 'Mother', 'done_by': ''},
                  {'id': 2, 'text': bn ? 'ডিম' : 'Eggs', 'qty': bn ? '১২টা' : '12', 'done': true,
                   'added_by': bn ? 'রহিম' : 'Rahim', 'done_by': bn ? 'রাফি' : 'Rafi'},
                ],
        }
      ]
    };
  }
  if (path == '/family/docs') {
    return {
      'shared_by_me': empty
          ? const []
          : [
              {'id': 3, 'document_id': 9, 'title': bn ? 'আম্মার পাসপোর্ট' : "Mother's passport",
               'doc_type': 'passport', 'recipient_name': bn ? 'রাফি' : 'Rafi', 'active': true,
               'opens': 2, 'has_file': true},
            ],
      'shared_with_me': const [],
    };
  }
  // the accounting tab (server: m1 reality, integer poisha)
  if (path.startsWith('/family/accounting/summary')) {
    return empty
        ? {'total_poisha': 0, 'members': const [], 'settlements': const [], 'pool': const {}}
        : {
            'total_poisha': 240000,
            'members': [
              {'member': 'self', 'paid_poisha': 240000, 'share_poisha': 120000, 'net_poisha': 120000},
              {'member': 1, 'paid_poisha': 0, 'share_poisha': 120000, 'net_poisha': -120000},
            ],
            'settlements': [
              {'from': 1, 'to': 'self', 'amount_poisha': 120000},
            ],
            'pool': {'target': 500000, 'collected': 200000, 'remaining': 300000, 'pct': 40},
          };
  }
  if (path.startsWith('/family/accounting/expenses')) {
    return {
      'expenses': empty
          ? const []
          : [
              {'id': 1, 'total_poisha': 240000, 'note': bn ? 'বাজার' : 'Groceries', 'payer': 'self',
               'payer_name': bn ? 'আমি' : 'Me',
               'shares': [
                 {'member': 'self', 'share_poisha': 120000},
                 {'member': 1, 'share_poisha': 120000},
               ]},
            ],
    };
  }
  return null;
}
