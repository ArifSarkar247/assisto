import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'api.dart';
import 'db.dart';

/// Offline-first repository for a synced collection (reminders / notes / todos).
/// Each in-memory item is a map: {localId, serverId, data: {...}, pendingOp}.
class SyncedRepo extends ChangeNotifier {
  final String entity; // 'reminder' | 'note' | 'todo'
  final String path; // api path, e.g. 'reminders'
  final ApiClient api;
  final LocalDb db;
  List<Map<String, dynamic>> items = [];
  bool syncing = false;

  SyncedRepo(this.entity, this.path, this.api, this.db);

  Map<String, dynamic> _fromRow(Map<String, dynamic> r) => {
        'localId': r['local_id'],
        'serverId': r['server_id'],
        'data': jsonDecode((r['data'] ?? '{}') as String) as Map<String, dynamic>,
        'pendingOp': r['pending_op'],
      };

  Map<String, dynamic> _toRow(Map<String, dynamic> m) => {
        'local_id': m['localId'],
        'server_id': m['serverId'],
        'data': jsonEncode(m['data']),
        'updated_at': DateTime.now().toIso8601String(),
        'pending_op': m['pendingOp'],
      };

  String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}';

  Future<void> load() async {
    final rows = await db.recAll(entity);
    items = rows.map(_fromRow).toList();
    notifyListeners();
  }

  /// Creates a new item and returns it (including its client-generated
  /// `localId`). Callers that schedule an OS notification MUST use the
  /// returned item's `localId`: after [sync] the in-memory list is reordered
  /// by `updated_at DESC`, so `items.first` is not reliably the new item.
  Future<Map<String, dynamic>> add(Map<String, dynamic> data) async {
    final m = {'localId': _newId(), 'serverId': null, 'data': data, 'pendingOp': 'create'};
    await db.recUpsert(entity, _toRow(m));
    await load();
    await sync();
    return m;
  }

  Future<void> update(Map<String, dynamic> item, Map<String, dynamic> data) async {
    item['data'] = {...item['data'] as Map<String, dynamic>, ...data};
    item['pendingOp'] = item['pendingOp'] == 'create' ? 'create' : 'update';
    await db.recUpsert(entity, _toRow(item));
    await load();
    await sync();
  }

  Future<void> remove(Map<String, dynamic> item) async {
    if (item['serverId'] == null) {
      await db.recHardDelete(entity, item['localId'] as String);
    } else {
      item['pendingOp'] = 'delete';
      await db.recUpsert(entity, _toRow(item));
    }
    await load();
    await sync();
  }

  /// remnotes: the server's own words when it REFUSED one queued write
  /// (an abuse cap, a bad request). Null when the last sync had none. The
  /// screens show it honestly instead of the item silently never syncing.
  String? refusal;

  /// A refusal that will not fix itself by retrying right away (4xx other
  /// than auth / timeout). Network errors and 5xx keep aborting the sync.
  static bool _refused(Object e) {
    if (e is! ApiException) return false;
    final s = e.status ?? 0;
    return s >= 400 && s < 500 && s != 401 && s != 408;
  }

  Future<void> sync() async {
    if (api.token == null || syncing) return;
    syncing = true;
    notifyListeners();
    try {
      String? refused;
      for (final row in await db.recPending(entity)) {
        final m = _fromRow(row);
        final op = m['pendingOp'];
        try {
          if (op == 'create') {
            final j = await api.createItem(path, Map<String, dynamic>.from(m['data']));
            m['serverId'] = j['id'];
            m['pendingOp'] = 'none';
            await db.recUpsert(entity, _toRow(m));
          } else if (op == 'update' && m['serverId'] != null) {
            await api.updateItem(path, m['serverId'] as int, Map<String, dynamic>.from(m['data']));
            m['pendingOp'] = 'none';
            await db.recUpsert(entity, _toRow(m));
          } else if (op == 'delete' && m['serverId'] != null) {
            await api.deleteItem(path, m['serverId'] as int);
            await db.recHardDelete(entity, m['localId'] as String);
          }
        } catch (e) {
          // remnotes: one refused write (e.g. today's cap) used to abort the
          // whole sync, so every LATER edit and the server refresh never ran.
          if (!_refused(e)) rethrow;
          if (op == 'delete' && (e as ApiException).status == 404) {
            await db.recHardDelete(entity, m['localId'] as String); // already gone
          } else {
            refused = (e as ApiException).message;
          }
        }
      }
      refusal = refused;
      final server = await api.listItems(path);
      final rows = server
          .map((j) => {
                'local_id': 'srv-${j['id']}',
                'server_id': j['id'],
                'data': jsonEncode(j),
                'updated_at': (j['updated_at'] ?? DateTime.now().toIso8601String()),
                'pending_op': 'none',
              })
          .toList();
      await db.recReplaceSynced(entity, rows);
      await load();
    } catch (_) {
      // offline — keep local
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  Future<void> clear() async {
    for (final it in List<Map<String, dynamic>>.from(items)) {
      await db.recHardDelete(entity, it['localId'] as String);
    }
    items = [];
    notifyListeners();
  }
}
