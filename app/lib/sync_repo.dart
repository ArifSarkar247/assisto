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

  Future<void> add(Map<String, dynamic> data) async {
    final m = {'localId': _newId(), 'serverId': null, 'data': data, 'pendingOp': 'create'};
    await db.recUpsert(entity, _toRow(m));
    await load();
    await sync();
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

  Future<void> sync() async {
    if (api.token == null || syncing) return;
    syncing = true;
    notifyListeners();
    try {
      for (final row in await db.recPending(entity)) {
        final m = _fromRow(row);
        final op = m['pendingOp'];
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
      }
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
