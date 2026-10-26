import '../../api.dart';

/// booking-bot (big-week item I): every server call the booking screens make,
/// behind one seam so widget tests / the screenshot gallery inject a fake.
/// Shapes mirror backend/core/booking_views.py (flag `booking_bot`).
abstract class BookingSource {
  // business
  Future<Map<String, dynamic>> page();
  Future<Map<String, dynamic>> savePage(Map<String, dynamic> body);
  Future<Map<String, dynamic>> addService(Map<String, dynamic> body);
  Future<Map<String, dynamic>> updateService(int id, Map<String, dynamic> body);
  Future<void> deleteService(int id);
  Future<Map<String, dynamic>> addStaff(String name);
  Future<void> deleteStaff(int id);
  Future<Map<String, dynamic>> bookings(String scope, {String? day});
  Future<Map<String, dynamic>> booking(int id);
  Future<Map<String, dynamic>> act(int id, String action, {String? start});
  Future<Map<String, dynamic>> bizSlots(int serviceId, String day, {int? exclude});
  Future<Map<String, dynamic>> addManual(Map<String, dynamic> body);
  Future<Map<String, dynamic>> block(String phone, bool blocked);
  // customer
  Future<Map<String, dynamic>> mine();
  Future<Map<String, dynamic>> myAct(int id, String action, {String? start});
  Future<Map<String, dynamic>> mySlots(int id, String day);
  Future<Map<String, dynamic>> publicPage(String slug);
  Future<Map<String, dynamic>> publicSlots(String slug, int serviceId, String day);
  Future<Map<String, dynamic>> book(String slug, int serviceId, String start, String note);
}

class ApiBookingSource implements BookingSource {
  final ApiClient api;
  ApiBookingSource(this.api);

  @override
  Future<Map<String, dynamic>> page() => api.getJson('/booking/biz');
  @override
  Future<Map<String, dynamic>> savePage(Map<String, dynamic> body) =>
      api.postJson('/booking/biz', body);
  @override
  Future<Map<String, dynamic>> addService(Map<String, dynamic> body) =>
      api.postJson('/booking/biz/services', body);
  @override
  Future<Map<String, dynamic>> updateService(int id, Map<String, dynamic> body) =>
      api.patchJson('/booking/biz/services/$id', body);
  @override
  Future<void> deleteService(int id) async {
    await api.deleteJson('/booking/biz/services/$id');
  }

  @override
  Future<Map<String, dynamic>> addStaff(String name) =>
      api.postJson('/booking/biz/staff', {'name': name});
  @override
  Future<void> deleteStaff(int id) async {
    await api.deleteJson('/booking/biz/staff/$id');
  }

  @override
  Future<Map<String, dynamic>> bookings(String scope, {String? day}) =>
      api.getJson('/booking/biz/bookings?scope=$scope${day != null ? '&day=$day' : ''}');
  @override
  Future<Map<String, dynamic>> booking(int id) => api.getJson('/booking/biz/bookings/$id');
  @override
  Future<Map<String, dynamic>> act(int id, String action, {String? start}) =>
      api.postJson('/booking/biz/bookings/$id/action',
          {'action': action, if (start != null) 'start': start});
  @override
  Future<Map<String, dynamic>> bizSlots(int serviceId, String day, {int? exclude}) =>
      api.getJson('/booking/biz/slots?service=$serviceId&day=$day'
          '${exclude != null ? '&exclude=$exclude' : ''}');
  @override
  Future<Map<String, dynamic>> addManual(Map<String, dynamic> body) =>
      api.postJson('/booking/biz/bookings', body);
  @override
  Future<Map<String, dynamic>> block(String phone, bool blocked) =>
      api.postJson('/booking/biz/blocks', {'phone': phone, 'blocked': blocked});
  @override
  Future<Map<String, dynamic>> mine() => api.getJson('/booking/mine');
  @override
  Future<Map<String, dynamic>> myAct(int id, String action, {String? start}) =>
      api.postJson('/booking/mine/$id/action', {'action': action, if (start != null) 'start': start});
  @override
  Future<Map<String, dynamic>> mySlots(int id, String day) =>
      api.getJson('/booking/mine/$id/slots?day=$day');
  @override
  Future<Map<String, dynamic>> publicPage(String slug) => api.getJson('/booking/p/$slug');
  @override
  Future<Map<String, dynamic>> publicSlots(String slug, int serviceId, String day) =>
      api.getJson('/booking/p/$slug/slots?service=$serviceId&day=$day');
  @override
  Future<Map<String, dynamic>> book(String slug, int serviceId, String start, String note) =>
      api.postJson('/booking/p/$slug/book', {'service': serviceId, 'start': start, 'note': note});
}

/// A server error's `detail` (already in the user's language), else null.
String? bkError(Object e) {
  if (e is ApiException && e.message.isNotEmpty && !e.message.startsWith('Error ')) {
    return e.message;
  }
  return null;
}

int? bkStatus(Object e) => e is ApiException ? e.status : null;

/// No HTTP answer at all (no internet / server unreachable).
bool bkOffline(Object e) => e is! ApiException;

const _bnZero = 0x09E6;

/// Digits in the UI language (Bangla digits in bn). No Bangla literal here:
/// the language gate keeps Bangla text in the ARB files only.
String bkDigits(String lang, Object v) {
  final s = v.toString();
  if (lang != 'bn') return s;
  final b = StringBuffer();
  for (final c in s.codeUnits) {
    b.writeCharCode(c >= 0x30 && c <= 0x39 ? _bnZero + (c - 0x30) : c);
  }
  return b.toString();
}

List<Map<String, dynamic>> bkList(Object? v) =>
    v is List ? v.whereType<Map>().map((m) => m.cast<String, dynamic>()).toList() : const [];

Map<String, dynamic> bkMap(Object? v) =>
    v is Map ? v.cast<String, dynamic>() : <String, dynamic>{};

String bkIsoDay(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Extracts the booking-page slug from a pasted link ("lifeassisto.com/b/x",
/// "https://…/b/x?lang=en") or a bare slug. Null when it can't be one.
String? bkSlugFrom(String raw) {
  var s = raw.trim().toLowerCase();
  final i = s.indexOf('/b/');
  if (i >= 0) s = s.substring(i + 3);
  s = s.split(RegExp(r'[/?#\s]')).first;
  return RegExp(r'^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$').hasMatch(s) ? s : null;
}
