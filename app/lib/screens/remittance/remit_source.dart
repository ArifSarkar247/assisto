import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../api.dart';
import '../../crypto/key_service.dart';
import '../../messaging/broadcast_send.dart';
import '../../notifications.dart';
import '../../state.dart';

/// budget-remittance (flag `budget_remittance`): every server / device call
/// the screens make, behind ONE seam so widget tests and the screenshot
/// gallery inject a fake. Shapes mirror backend/core/remittance_views.py.
abstract class RemitSource {
  Future<Map<String, dynamic>> overview(String month);
  Future<Map<String, dynamic>> createEntry(Map<String, dynamic> body);
  Future<Map<String, dynamic>> updateEntry(int id, Map<String, dynamic> body);
  Future<void> deleteEntry(int id);
  Future<Map<String, dynamic>> saveSettings(Map<String, dynamic> body);
  Future<Map<String, dynamic>> savePlan(Map<String, String> lines);
  Future<Map<String, dynamic>> spend(Map<String, dynamic> body);
  Future<Map<String, dynamic>> saveGoal(String title, String target);
  Future<Map<String, dynamic>> addToGoal(String clientId, String amount);
  Future<Map<String, dynamic>> addBill(Map<String, dynamic> body);
  Future<Map<String, dynamic>> updateBill(int id, Map<String, dynamic> body);
  Future<Map<String, dynamic>> deleteBill(int id);
  Future<Map<String, dynamic>> billPaid(int id, String month, String clientId);
  Future<Map<String, dynamic>> report(String month, String lang);
  Future<Map<String, dynamic>> year(int year);
  Future<Map<String, dynamic>> export(String fmt);
  Future<void> deleteAll();

  /// Accepted My Circle members ({id, name, relation, public_key}).
  Future<List<Map<String, dynamic>>> members();

  /// Send [text] to ONE My Circle member as a normal end-to-end encrypted
  /// message. Called ONLY from the Share button — never automatically.
  Future<void> shareToMember(Map<String, dynamic> member, String text);

  /// A monthly reminder in the user's normal Reminders (no WorkManager):
  /// returns its local id.
  Future<String?> addMonthlyReminder(String title, DateTime first);
  Future<void> removeReminder(String localId);

  /// Local notifications for the expected-remittance check.
  Future<void> scheduleNote(String key, String title, String body, DateTime when);
  Future<void> cancelNote(String key);
  Future<void> showNote(String key, String title, String body);

  /// Small device store (offline queue, guide seen, last channel ...).
  Future<String?> getPref(String key);
  Future<void> setPref(String key, String value);
}

class ApiRemitSource implements RemitSource {
  final ApiClient api;
  final AppState? app;
  ApiRemitSource(this.api, {this.app});

  @override
  Future<Map<String, dynamic>> overview(String month) => api.getJson('/remit/overview?month=$month');
  @override
  Future<Map<String, dynamic>> createEntry(Map<String, dynamic> body) => api.postJson('/remit/entries', body);
  @override
  Future<Map<String, dynamic>> updateEntry(int id, Map<String, dynamic> body) =>
      api.patchJson('/remit/entries/$id', body);
  @override
  Future<void> deleteEntry(int id) async {
    await api.deleteJson('/remit/entries/$id');
  }

  @override
  Future<Map<String, dynamic>> saveSettings(Map<String, dynamic> body) => api.postJson('/remit/settings', body);
  @override
  Future<Map<String, dynamic>> savePlan(Map<String, String> lines) => api.postJson('/remit/plan', {'lines': lines});
  @override
  Future<Map<String, dynamic>> spend(Map<String, dynamic> body) => api.postJson('/remit/spend', body);
  @override
  Future<Map<String, dynamic>> saveGoal(String title, String target) =>
      api.postJson('/remit/goal', {'title': title, 'target': target});
  @override
  Future<Map<String, dynamic>> addToGoal(String clientId, String amount) =>
      api.postJson('/remit/goal/add', {'client_id': clientId, 'amount': amount});
  @override
  Future<Map<String, dynamic>> addBill(Map<String, dynamic> body) => api.postJson('/remit/bills', body);
  @override
  Future<Map<String, dynamic>> updateBill(int id, Map<String, dynamic> body) => api.patchJson('/remit/bills/$id', body);
  @override
  Future<Map<String, dynamic>> deleteBill(int id) => api.deleteJson('/remit/bills/$id');
  @override
  Future<Map<String, dynamic>> billPaid(int id, String month, String clientId) =>
      api.postJson('/remit/bills/$id/paid', {'month': month, 'client_id': clientId});
  @override
  Future<Map<String, dynamic>> report(String month, String lang) =>
      api.getJson('/remit/report?month=$month&lang=$lang');
  @override
  Future<Map<String, dynamic>> year(int year) => api.getJson('/remit/year?year=$year');
  @override
  Future<Map<String, dynamic>> export(String fmt) => api.getJson('/remit/export?fmt=$fmt&as=json');
  @override
  Future<void> deleteAll() async {
    await api.postJson('/remit/delete-all', {'confirm': true});
  }

  @override
  Future<List<Map<String, dynamic>>> members() async {
    final r = await api.getJson('/circle/members');
    return rmList(r['results'] ?? r['members']).where((m) => '${m['state'] ?? 'accepted'}' == 'accepted').toList();
  }

  @override
  Future<void> shareToMember(Map<String, dynamic> member, String text) async {
    final id = int.tryParse('${member['id']}') ?? 0;
    final me = await KeyService.instance.identity();
    final r = await sendBroadcastText(api, me, [id], text, members: [member]);
    if (r.delivered == 0) throw StateError('share: not sent');
  }

  @override
  Future<String?> addMonthlyReminder(String title, DateTime first) async {
    final a = app;
    if (a == null) return null;
    final created = await a.reminders.add({
      'title': title,
      'notes': '',
      'due_at': first.toUtc().toIso8601String(),
      'recurrence': 'monthly',
      'date_only': false,
      'done': false,
      'source': 'remit',
    });
    final lid = created['localId'] as String?;
    if (lid != null) await Notifications.schedule(lid, title, '', first);
    return lid;
  }

  @override
  Future<void> removeReminder(String localId) async {
    final a = app;
    if (a == null || localId.isEmpty) return;
    await Notifications.cancel(localId);
    for (final it in a.reminders.items) {
      if (it['localId'] == localId) {
        await a.reminders.remove(it);
        break;
      }
    }
  }

  @override
  Future<void> scheduleNote(String key, String title, String body, DateTime when) =>
      Notifications.schedule(key, title, body, when);
  @override
  Future<void> cancelNote(String key) => Notifications.cancel(key);
  @override
  Future<void> showNote(String key, String title, String body) =>
      Notifications.show(Notifications.idFor(key), title, body);
  @override
  Future<String?> getPref(String key) => Settings.getString(key);
  @override
  Future<void> setPref(String key, String value) => Settings.setString(key, value);
}

// ------------------------------------------------------------------ queue
/// Offline entry: anything written with no connection waits here (on this
/// phone) and goes up later with the SAME client id, so a retry can never
/// make a double entry (the server is idempotent on it).
class RemitQueue extends ChangeNotifier {
  static const prefsKey = 'remit_queue_v1';
  final RemitSource src;
  RemitQueue(this.src);

  List<Map<String, dynamic>> items = [];
  bool _flushing = false;

  Future<void> load() async {
    try {
      final raw = await src.getPref(prefsKey);
      items = raw == null || raw.isEmpty ? [] : rmList(jsonDecode(raw));
    } catch (_) {
      items = [];
    }
  }

  Future<void> _save() async {
    try {
      await src.setPref(prefsKey, jsonEncode(items));
    } catch (_) {}
    notifyListeners();
  }

  /// kind: entry | spend | goal | bill_paid
  Future<void> add(String kind, Map<String, dynamic> body) async {
    items.add({'kind': kind, 'body': body, 'at': DateTime.now().toIso8601String()});
    await _save();
  }

  Future<void> clear() async {
    items = [];
    await _save();
  }

  List<Map<String, dynamic>> get pendingEntries => [
    for (final i in items)
      if (i['kind'] == 'entry') rmMap(i['body']),
  ];

  /// Send what waits, oldest first. Stops at the first "no connection";
  /// a refused item (4xx) is dropped and returned so the UI can say so.
  Future<({int sent, List<Map<String, dynamic>> refused, bool offline})> flush() async {
    if (_flushing || items.isEmpty) return (sent: 0, refused: <Map<String, dynamic>>[], offline: false);
    _flushing = true;
    var sent = 0;
    final refused = <Map<String, dynamic>>[];
    var offline = false;
    try {
      while (items.isNotEmpty) {
        final it = items.first;
        final b = rmMap(it['body']);
        try {
          switch (it['kind']) {
            case 'entry':
              await src.createEntry(b);
            case 'spend':
              await src.spend(b);
            case 'goal':
              await src.addToGoal('${b['client_id']}', '${b['amount']}');
            case 'bill_paid':
              await src.billPaid(int.tryParse('${b['id']}') ?? 0, '${b['month']}', '${b['client_id']}');
          }
          sent++;
          items.removeAt(0);
        } catch (e) {
          if (rmOffline(e) || (rmStatus(e) ?? 0) >= 500 || rmStatus(e) == 429) {
            offline = rmOffline(e);
            break; // try again later
          }
          refused.add(it);
          items.removeAt(0);
        }
      }
    } finally {
      _flushing = false;
      await _save();
    }
    return (sent: sent, refused: refused, offline: offline);
  }
}

// ------------------------------------------------------------------ helpers
String rmClientId() {
  final r = Random();
  final s = List.generate(10, (_) => r.nextInt(36).toRadixString(36)).join();
  return 'a${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}$s';
}

String? rmError(Object e) {
  if (e is ApiException && e.message.isNotEmpty && !e.message.startsWith('Error ')) {
    return e.message;
  }
  return null;
}

int? rmStatus(Object e) => e is ApiException ? e.status : null;

/// No HTTP answer at all (no internet / server unreachable / timeout).
bool rmOffline(Object e) => e is! ApiException && e is! StateError;

List<Map<String, dynamic>> rmList(Object? v) =>
    v is List ? v.whereType<Map>().map((m) => m.cast<String, dynamic>()).toList() : <Map<String, dynamic>>[];

Map<String, dynamic> rmMap(Object? v) => v is Map ? v.cast<String, dynamic>() : <String, dynamic>{};

double rmNum(Object? v) => double.tryParse('${v ?? ''}'.replaceAll(',', '')) ?? 0;

String rmIsoDay(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String rmMonthKey(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';

/// A plain number string for the API ("20000", "32.5").
String rmPlain(double v) {
  if (v == v.roundToDouble()) return v.toInt().toString();
  return v.toStringAsFixed(4).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}
