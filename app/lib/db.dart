import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'models.dart';

/// Offline-first local store. Memory items live here first; sync is additive.
class LocalDb {
  static final LocalDb instance = LocalDb._();
  LocalDb._();
  Database? _db;

  Future<Database> get db async {
    _db ??= await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final dir = await getDatabasesPath();
    final path = p.join(dir, 'assisto.db');
    return openDatabase(
      path,
      version: 2,
      onCreate: (d, v) async {
        await d.execute('''
          CREATE TABLE memory(
            local_id TEXT PRIMARY KEY,
            server_id INTEGER,
            category TEXT,
            title TEXT,
            detail TEXT,
            source TEXT,
            needs_review INTEGER,
            updated_at TEXT,
            pending_op TEXT
          )
        ''');
        await _createRecords(d);
      },
      onUpgrade: (d, oldV, newV) async {
        if (oldV < 2) await _createRecords(d);
      },
    );
  }

  Future<void> _createRecords(dynamic d) async {
    // generic offline store for reminders/notes/todos (data = JSON string)
    await d.execute('''
      CREATE TABLE records(
        entity TEXT,
        local_id TEXT,
        server_id INTEGER,
        data TEXT,
        updated_at TEXT,
        pending_op TEXT,
        PRIMARY KEY(entity, local_id)
      )
    ''');
  }

  // ---- generic records (reminders / notes / todos) ----
  Future<List<Map<String, dynamic>>> recAll(String entity) async {
    final d = await db;
    return d.query('records',
        where: "entity = ? AND pending_op != 'delete'",
        whereArgs: [entity], orderBy: 'updated_at DESC');
  }

  Future<List<Map<String, dynamic>>> recPending(String entity) async {
    final d = await db;
    return d.query('records',
        where: "entity = ? AND pending_op != 'none'", whereArgs: [entity]);
  }

  Future<void> recUpsert(String entity, Map<String, dynamic> row) async {
    final d = await db;
    row['entity'] = entity;
    await d.insert('records', row, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> recHardDelete(String entity, String localId) async {
    final d = await db;
    await d.delete('records',
        where: 'entity = ? AND local_id = ?', whereArgs: [entity, localId]);
  }

  Future<void> recReplaceSynced(String entity, List<Map<String, dynamic>> rows) async {
    final d = await db;
    await d.transaction((txn) async {
      await txn.delete('records',
          where: "entity = ? AND pending_op = 'none'", whereArgs: [entity]);
      for (final row in rows) {
        row['entity'] = entity;
        final existing = await txn.query('records',
            where: 'entity = ? AND server_id = ? AND pending_op != ?',
            whereArgs: [entity, row['server_id'], 'none']);
        if (existing.isEmpty) {
          await txn.insert('records', row, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
    });
  }

  Future<List<MemoryItem>> allMemory() async {
    final d = await db;
    final rows = await d.query('memory',
        where: "pending_op != 'delete'", orderBy: 'updated_at DESC');
    return rows.map((r) => MemoryItem.fromRow(r)).toList();
  }

  Future<List<MemoryItem>> pendingMemory() async {
    final d = await db;
    final rows = await d.query('memory', where: "pending_op != 'none'");
    return rows.map((r) => MemoryItem.fromRow(r)).toList();
  }

  Future<void> upsert(MemoryItem m) async {
    final d = await db;
    await d.insert('memory', m.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> hardDelete(String localId) async {
    final d = await db;
    await d.delete('memory', where: 'local_id = ?', whereArgs: [localId]);
  }

  /// Replace all synced (pending_op == 'none') rows with the server set, keeping
  /// local unsynced edits intact.
  Future<void> replaceSynced(List<MemoryItem> serverItems) async {
    final d = await db;
    await d.transaction((txn) async {
      await txn.delete('memory', where: "pending_op = 'none'");
      for (final m in serverItems) {
        // don't clobber an item that still has a pending local edit
        final existing = await txn.query('memory',
            where: 'server_id = ? AND pending_op != ?',
            whereArgs: [m.serverId, 'none']);
        if (existing.isEmpty) {
          await txn.insert('memory', m.toRow(),
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
    });
  }

  Future<void> clearAll() async {
    final d = await db;
    await d.delete('memory');
  }
}
