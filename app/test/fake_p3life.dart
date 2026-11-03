// p3life gallery/test fakes: the user's OWN entries for the new travel,
// wedding and food collections (what a user would type; nothing fetched).

List<Map<String, dynamic>>? fakeP3LifeList(String path, {required bool bn}) {
  final now = DateTime.now();
  String d(int days) {
    final x = now.add(Duration(days: days));
    return '${x.year.toString().padLeft(4, '0')}-${x.month.toString().padLeft(2, '0')}-${x.day.toString().padLeft(2, '0')}';
  }

  final month = d(0).substring(0, 7);
  switch (path) {
    case 'travel/days':
      return [
        {'id': 1, 'trip_id': 1, 'day': 1, 'title': bn ? 'চা বাগান' : 'Tea gardens',
         'activities': [{'what': bn ? 'হাঁটা' : 'Walk', 'place': bn ? 'লাউয়াছড়া' : 'Lawachara', 'time': '10:00'}]},
      ];
    case 'travel/legs':
      return [
        {'id': 1, 'trip_id': 1, 'mode': 'train', 'from': bn ? 'ঢাকা' : 'Dhaka', 'to': bn ? 'শ্রীমঙ্গল' : 'Sreemangal',
         'date': d(20), 'time': '06:40', 'ref': bn ? 'পারাবত' : 'Parabat'},
        {'id': 2, 'trip_id': 1, 'mode': 'launch', 'from': bn ? 'সদরঘাট' : 'Sadarghat', 'to': bn ? 'বরিশাল' : 'Barishal',
         'date': d(23), 'time': '20:30', 'ref': ''},
        {'id': 3, 'trip_id': 1, 'mode': 'bus', 'from': bn ? 'বরিশাল' : 'Barishal', 'to': bn ? 'ঢাকা' : 'Dhaka',
         'date': d(25), 'time': '', 'ref': ''},
      ];
    case 'travel/docs':
      return [
        {'id': 1, 'trip_id': 1, 'kind': 'passport', 'label': '', 'expiry': d(90)},
        {'id': 2, 'trip_id': 1, 'kind': 'nid', 'label': '', 'expiry': ''},
        {'id': 3, 'trip_id': 1, 'kind': 'ticket', 'label': '', 'expiry': d(400)},
      ];
    case 'wedding/schedule':
      return [
        {'id': 1, 'title': bn ? 'গায়ে হলুদ' : 'Gaye holud', 'date': d(30), 'time': '17:00', 'place': bn ? 'বাসার ছাদ' : 'Home rooftop'},
        {'id': 2, 'title': bn ? 'বিয়ে' : 'Wedding', 'date': d(31), 'time': '19:00', 'place': bn ? 'সেনাকুঞ্জ' : 'Senakunja'},
      ];
    case 'wedding/vendors':
      return [
        {'id': 1, 'name': bn ? 'রঙিন ডেকোরেটর' : 'Rongin Decorators', 'service': 'decor', 'phone': '01700000001', 'quote': 8000000, 'paid': 3000000},
        {'id': 2, 'name': bn ? 'হাজী বাবুর্চি' : 'Haji Cook', 'service': 'cook', 'phone': '', 'quote': 25000000, 'paid': 25000000},
      ];
    case 'wedding/gifts':
      return [
        {'id': 1, 'giver': bn ? 'বড় মামা' : 'Big uncle', 'gift': bn ? 'সোনার আংটি' : 'Gold ring', 'amount': 0, 'occasion': bn ? 'বিয়ে' : 'Wedding', 'thanked': true},
        {'id': 2, 'giver': bn ? 'রিনা খালা' : 'Aunt Rina', 'gift': '', 'amount': 500000, 'occasion': bn ? 'হলুদ' : 'Holud', 'thanked': false, 'phone': '01700000002'},
      ];
    case 'food/orders':
      return [
        {'id': 1, 'date': '$month-02', 'provider': 'foodpanda', 'what': bn ? 'বিরিয়ানি' : 'Biryani', 'amount': 45000},
        {'id': 2, 'date': '$month-01', 'provider': 'pathao_food', 'what': bn ? 'বার্গার' : 'Burger', 'amount': 38000},
        {'id': 3, 'date': '$month-01', 'provider': 'restaurant', 'what': '', 'amount': 120000},
      ];
  }
  return null;
}

Map<String, dynamic>? fakeP3LifePost(String path) {
  if (path == '/life/share') return {'url': 'https://lifeassisto.com/p/example', 'kind': 'trip'};
  if (path == '/life/share/revoke') return {'ok': true};
  return null;
}
