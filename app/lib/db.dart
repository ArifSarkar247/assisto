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
      version: 1,
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
      },
    );
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
