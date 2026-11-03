// p2plan: FakeApi stubs for the AI daily planner, shared task lists and the
// estimator templates (gallery + widget tests). Real shapes from
// backend/core/views_p2plan.py.

Map<String, dynamic> fakeDayPlan({bool bn = true}) => {
      'date': '2026-11-03',
      'window': {'start': '08:00', 'end': '22:00'},
      'prayer': true,
      'empty': false,
      'free_min': 95,
      'polish_credits': 2,
      'prefs': {'day_start': '08:00', 'day_end': '22:00', 'prayer': true},
      'counts': {'meetings': 1, 'reminders': 1, 'prayers': 2, 'tasks_planned': 3,
        'tasks_unscheduled': 1, 'bills': 1},
      'blocks': [
        {'start': '09:00', 'end': '09:30', 'kind': 'task', 'title': bn ? 'বিদ্যুৎ বিল দেওয়া' : 'Pay the power bill',
          'src': {'kind': 'task', 'id': 1}, 'priority': 'urgent', 'overdue': true, 'past': false, 'clash': false},
        {'start': '09:30', 'end': '09:45', 'kind': 'reminder', 'title': bn ? 'আম্মুর ওষুধ' : "Mum's medicine",
          'src': {'kind': 'reminder', 'id': 3}, 'past': false, 'clash': false, 'overdue': false},
        {'start': '11:00', 'end': '12:00', 'kind': 'meeting', 'title': bn ? 'ব্যাংকে মিটিং' : 'Bank meeting',
          'src': {'kind': 'schedule', 'id': 9}, 'past': false, 'clash': false, 'overdue': false},
        {'start': '12:05', 'end': '12:25', 'kind': 'prayer', 'title': 'Dhuhr', 'title_bn': 'যোহর', 'title_en': 'Dhuhr',
          'src': {'kind': 'prayer', 'id': 'dhuhr'}, 'past': false, 'clash': false, 'overdue': false},
        {'start': '12:25', 'end': '13:25', 'kind': 'task', 'title': bn ? 'দোকানের হিসাব মেলানো' : 'Reconcile shop accounts',
          'src': {'kind': 'task', 'id': 2}, 'priority': 'high', 'past': false, 'clash': false, 'overdue': false},
      ],
      'unscheduled': [
        {'title': bn ? 'বাসা রং-এর দাম নেওয়া' : 'Get paint quotes', 'minutes': 120,
          'src': {'kind': 'task', 'id': 5}, 'priority': 'normal', 'overdue': false},
      ],
      'bills': [
        {'bn': 'DESCO — ৳১,২০০ (আজ)', 'en': 'DESCO — ৳1,200 (today)', 'src': {'kind': 'bill_bill', 'id': 4}},
      ],
      'tips': [
        {'bn': 'প্রথম কাজ ০৯:০০-এ: বিদ্যুৎ বিল দেওয়া', 'en': 'First task at 09:00: Pay the power bill'},
        {'bn': '১টি কাজ আজ আঁটছে না — অন্য দিনে সরান বা সময় কমান।',
          'en': "1 task(s) don't fit today — move them or shorten them."},
      ],
    };

Map<String, dynamic> fakeDayPlanEmpty() => {
      'date': '2026-11-03', 'window': {'start': '08:00', 'end': '22:00'}, 'prayer': false,
      'empty': true, 'free_min': 0, 'polish_credits': 2, 'blocks': <dynamic>[],
      'unscheduled': <dynamic>[], 'bills': <dynamic>[], 'tips': <dynamic>[],
      'counts': <String, dynamic>{}, 'prefs': {'day_start': '08:00', 'day_end': '22:00', 'prayer': false},
    };

Map<String, dynamic>? fakeP2planGet(String path, {bool empty = false, bool bn = true}) {
  final p = path.split('?').first;
  if (p == '/planner/today') return empty ? fakeDayPlanEmpty() : fakeDayPlan(bn: bn);
  if (p == '/planner/prefs') return {'day_start': '08:00', 'day_end': '22:00', 'prayer': true};
  if (p == '/tasks/shared') {
    return {
      'lists': empty
          ? <dynamic>[]
          : [
              {'id': 501, 'name': bn ? 'বাসা রং' : 'Paint the flat', 'description': '', 'color': '',
                'role': 'member', 'owner': {'uid': 7, 'name': bn ? 'রিনা' : 'Rina'},
                'people': [
                  {'uid': 7, 'name': bn ? 'রিনা' : 'Rina', 'role': 'owner'},
                  {'uid': 8, 'name': bn ? 'করিম' : 'Karim', 'role': 'member'},
                ],
                'summary': {'total': 2, 'todo': 1, 'doing': 0, 'done': 1, 'overdue': 0, 'percent_done': 50}},
            ],
    };
  }
  if (p.startsWith('/tasks/lists/')) {
    return {
      'id': 501, 'name': bn ? 'বাসা রং' : 'Paint the flat', 'role': 'member',
      'owner': {'uid': 7, 'name': bn ? 'রিনা' : 'Rina'},
      'people': [
        {'uid': 7, 'name': bn ? 'রিনা' : 'Rina', 'role': 'owner'},
        {'uid': 8, 'name': bn ? 'করিম' : 'Karim', 'role': 'member'},
      ],
      'tasks': [
        {'id': 601, 'project_id': 501, 'title': bn ? 'রং কেনা' : 'Buy paint', 'status': 'todo',
          'priority': 'high', 'assignee': bn ? 'করিম' : 'Karim', 'assignee_uid': 8, 'repeat': '', 'est_min': 60},
        {'id': 602, 'project_id': 501, 'parent_id': 601, 'title': bn ? 'দোকানে দাম জানা' : 'Ask prices',
          'status': 'done'},
      ],
    };
  }
  if (p == '/estimate/templates') {
    return {
      'templates': [
        {'id': 'home', 'title': bn ? 'বাসা মেরামত ও রং' : 'Home repair & paint', 'icon': 'home_repair_service',
          'owner_rates': 0,
          'questions': [
            {'key': 'paint_sqft', 'label': bn ? 'কত বর্গফুট দেয়াল রং করবেন?' : 'Wall area to paint?',
              'unit': bn ? 'বর্গফুট' : 'sq ft', 'default': 0},
          ]},
        {'id': 'event', 'title': bn ? 'অনুষ্ঠান (বিয়ে/জন্মদিন)' : 'Event (wedding/birthday)', 'icon': 'celebration',
          'owner_rates': 0, 'questions': <dynamic>[]},
      ],
    };
  }
  return null;
}

Map<String, dynamic>? fakeP2planPost(String path, Map<String, dynamic> body, {bool bn = true}) {
  final p = path.split('?').first;
  if (p == '/planner/today/polish') {
    return {'ok': true, 'ai': true, 'charged': 2, 'balance': 40,
      'advice': [bn ? 'জরুরি বিলটা আগে দিন।' : 'Pay the urgent bill first.']};
  }
  if (p == '/planner/prefs') return {'day_start': '08:00', 'day_end': '22:00', 'prayer': true, ...body};
  if (p == '/tasks/parse') {
    return {'title': bn ? 'বাজার করা' : 'Groceries', 'due': '2026-11-07T08:00:00', 'date_only': false,
      'repeat': 'weekly', 'priority': 'urgent', 'confidence': 0.8};
  }
  if (p.startsWith('/estimate/templates/')) {
    return {
      'template': 'home', 'title': bn ? 'বাসা মেরামত ও রং' : 'Home repair & paint', 'estimate': true,
      'missing_rates': 1,
      'note': bn ? 'এটি অনুমান — দরপত্র বা কোটেশন নয়।' : 'This is an estimate — not a quote.',
      'lines': [
        {'id': 'paint', 'name': bn ? 'রং (উপকরণ + মিস্ত্রি)' : 'Paint (material + labour)', 'unit': bn ? 'বর্গফুট' : 'sq ft',
          'qty': 1200, 'unit_cost': 28, 'minutes': null,
          'rate_src': {'kind': 'owner', 'source': 'PWD Schedule of Rates 2022 (rev. Feb 2023)', 'date': '2023-02-23'},
          'time_src': {'kind': 'none'}},
        {'id': 'cleanup', 'name': bn ? 'পরিষ্কার ও মালামাল সরানো' : 'Clean-up', 'unit': bn ? 'বার' : 'job',
          'qty': 1, 'unit_cost': null, 'minutes': null, 'rate_src': {'kind': 'none'}, 'time_src': {'kind': 'none'}},
      ],
    };
  }
  return null;
}
