// booking1: an in-memory BookingSource for the gallery + widget tests. Shapes
// mirror backend/core/booking_views.py (page, services, staff, bookings,
// actions, slots, mine, public page, book).
import 'package:assisto/api.dart';
import 'package:assisto/screens/booking/booking_source.dart';

class FakeBooking implements BookingSource {
  /// 'empty' (first run, nothing set up), 'data' (set up + bookings),
  /// 'off' (feature flag hidden), 'fail' (server error), 'offline' (no net),
  /// 'staff' (a staff member of a business the owner has not set up).
  final String mode;
  FakeBooking([this.mode = 'data']);

  final List<String> calls = [];
  final List<Map<String, dynamic>> saved = [];
  late List<Map<String, dynamic>> services = mode == 'data' || mode == 'mine'
      ? [
          {'id': 1, 'name': 'Haircut', 'duration_min': 30, 'buffer_min': 10, 'price_bdt': 300, 'staff_ids': [], 'active': true},
          {'id': 2, 'name': 'Facial', 'duration_min': 60, 'buffer_min': 0, 'price_bdt': 800, 'staff_ids': [], 'active': true},
        ]
      : [];
  late Map<int, Map<String, dynamic>> _b = {
    for (final b in _seed()) b['id'] as int: b,
  };

  static String iso(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}T${two(d.hour)}:${two(d.minute)}:00+06:00';
  }

  static DateTime dhakaToday() {
    final l = DateTime.now().toUtc().add(const Duration(hours: 6));
    return DateTime(l.year, l.month, l.day);
  }

  static Map<String, dynamic> row(int id, String status,
          {int hour = 10, int dayOffset = 0, String name = 'Karim Ahmed', String channel = 'web',
          List<String>? can, int? thread}) =>
      {
        'id': id, 'service': 'Haircut', 'service_id': 1, 'staff': '', 'staff_id': null,
        'start': iso(dhakaToday().add(Duration(days: dayOffset, hours: hour))),
        'end': iso(dhakaToday().add(Duration(days: dayOffset, hours: hour, minutes: 30))),
        'status': status, 'when': 'Tue 27 Oct, 10:00 AM', 'channel': channel,
        'customer_name': name, 'customer_phone': '+8801810000002', 'note': '',
        'thread_id': thread, 'is_app_user': true, 'blocked': false, 'stopped': false,
        'reminders_sent': 0, 'reschedules': 0,
        'business': {'id': 1, 'name': 'Rupa Salon', 'slug': 'rupa-salon'},
        'can': can ?? (status == 'requested'
            ? ['confirmed', 'cancelled', 'reschedule']
            : status == 'confirmed' ? ['cancelled', 'reschedule'] : []),
        'cancel_hours': 2,
      };

  List<Map<String, dynamic>> _seed() => mode == 'data' || mode == 'mine'
      ? [
          row(1, 'confirmed', hour: 10),
          row(2, 'requested', hour: 12, name: 'Nadia', channel: 'whatsapp_cloud', thread: 9),
          row(3, 'confirmed', hour: 11, dayOffset: 2, name: 'Sumon'),
        ]
      : [];

  Never _boom() {
    if (mode == 'off') throw ApiException('This feature is not available yet.', 403);
    if (mode == 'offline') throw Exception('SocketException: no route');
    throw ApiException('Error 500', 500);
  }

  bool get _broken => mode == 'off' || mode == 'fail' || mode == 'offline';

  @override
  Future<Map<String, dynamic>> page() async {
    calls.add('page');
    if (_broken) _boom();
    final setUp = services.isNotEmpty;
    return {
      'slug': 'rupa-salon', 'enabled': setUp, 'title': 'Rupa Salon', 'about': '', 'address': '',
      'weekly_hours': setUp ? {for (var d = 0; d < 7; d++) if (d != 4) '$d': [['10:00', '20:00']]} : {},
      'days_off': <String>[], 'capacity': 1, 'step_min': 30, 'min_notice_min': 60,
      'max_days_ahead': 30, 'cancel_hours': 2, 'auto_confirm': false,
      'services': services, 'public_url': 'https://lifeassisto.com/b/rupa-salon',
      'max_pending_per_phone': 2, 'chat_bot': true, 'sms_reminders': false,
      'staff': <Map<String, dynamic>>[], 'ready_problems': setUp ? [] : ['no_services', 'no_hours'],
      'plan_ok': true, 'sms_available': false, 'is_owner': mode != 'staff',
      'counts': {'today': 2, 'pending': 1, 'upcoming': 3},
    };
  }

  @override
  Future<Map<String, dynamic>> savePage(Map<String, dynamic> body) async {
    calls.add('savePage');
    saved.add(body);
    return page();
  }

  @override
  Future<Map<String, dynamic>> addService(Map<String, dynamic> body) async {
    calls.add('addService');
    final s = {'id': 10 + services.length, 'staff_ids': [], 'active': true, ...body};
    services = [...services, s];
    return s;
  }

  @override
  Future<Map<String, dynamic>> updateService(int id, Map<String, dynamic> body) async =>
      services.firstWhere((s) => s['id'] == id);
  @override
  Future<void> deleteService(int id) async {
    calls.add('deleteService:$id');
    services = services.where((s) => s['id'] != id).toList();
  }

  @override
  Future<Map<String, dynamic>> addStaff(String name) async {
    calls.add('addStaff');
    return {'id': 50, 'name': name, 'active': true};
  }

  @override
  Future<void> deleteStaff(int id) async => calls.add('deleteStaff:$id');

  @override
  Future<Map<String, dynamic>> bookings(String scope, {String? day}) async {
    calls.add('bookings:$scope');
    if (_broken) _boom();
    final today = dhakaToday();
    final rows = _b.values.where((b) {
      final d = DateTime.parse(b['start'] as String).toUtc().add(const Duration(hours: 6));
      final dd = DateTime(d.year, d.month, d.day);
      if (scope == 'today') return dd == today;
      if (scope == 'day') return day != null && bkIsoDay(dd) == day;
      return ['requested', 'confirmed'].contains(b['status']);
    }).toList();
    return {'scope': scope, 'bookings': rows};
  }

  @override
  Future<Map<String, dynamic>> booking(int id) async {
    if (_broken) _boom();
    return _b[id]!;
  }

  @override
  Future<Map<String, dynamic>> act(int id, String action, {String? start}) async {
    calls.add('act:$id:$action');
    final b = Map<String, dynamic>.from(_b[id]!);
    if (action == 'reschedule') {
      b['start'] = start;
    } else {
      b['status'] = action;
      b['can'] = action == 'confirmed' ? ['cancelled', 'reschedule'] : <String>[];
    }
    _b[id] = b;
    return b;
  }

  Map<String, dynamic> _slots(String day) {
    final d = DateTime.parse(day);
    return {
      'day': day,
      'slots': [
        for (final h in [10, 11, 15])
          {'start': iso(DateTime(d.year, d.month, d.day, h)), 'label': '$h:00', 'staff_ids': []},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> bizSlots(int serviceId, String day, {int? exclude}) async => _slots(day);
  @override
  Future<Map<String, dynamic>> addManual(Map<String, dynamic> body) async {
    calls.add('addManual');
    saved.add(body);
    return row(99, 'confirmed', channel: 'manual');
  }

  @override
  Future<Map<String, dynamic>> block(String phone, bool blocked) async {
    calls.add('block:$blocked');
    return {'phone': phone, 'blocked': blocked};
  }

  @override
  Future<Map<String, dynamic>> mine() async {
    calls.add('mine');
    if (_broken) _boom();
    if (mode == 'empty') return {'upcoming': [], 'past': []};
    return {
      'upcoming': [row(1, 'confirmed', dayOffset: 1)],
      'past': [row(4, 'done', dayOffset: -3)],
    };
  }

  @override
  Future<Map<String, dynamic>> myAct(int id, String action, {String? start}) async {
    calls.add('myAct:$id:$action');
    return row(id, action == 'cancelled' ? 'cancelled' : 'requested', dayOffset: 1);
  }

  @override
  Future<Map<String, dynamic>> mySlots(int id, String day) async => _slots(day);
  @override
  Future<Map<String, dynamic>> publicPage(String slug) async {
    calls.add('publicPage:$slug');
    if (slug != 'rupa-salon') throw ApiException('Not found.', 404);
    return {
      'slug': slug, 'title': 'Rupa Salon', 'about': 'Hair and beauty, Dhanmondi', 'address': 'Road 7, Dhanmondi',
      'services': [
        {'id': 1, 'name': 'Haircut', 'duration_min': 30, 'buffer_min': 10, 'price_bdt': 300, 'active': true},
        {'id': 2, 'name': 'Facial', 'duration_min': 60, 'buffer_min': 0, 'price_bdt': 800, 'active': true},
      ],
      'taking_bookings': true, 'cancel_hours': 2, 'needs_otp': false, 'public_url': '',
    };
  }

  @override
  Future<Map<String, dynamic>> publicSlots(String slug, int serviceId, String day) async => _slots(day);
  @override
  Future<Map<String, dynamic>> book(String slug, int serviceId, String start, String note) async {
    calls.add('book:$serviceId:$start');
    return {...row(7, 'requested', dayOffset: 1), 'start': start};
  }
}
