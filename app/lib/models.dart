class AppUser {
  final int id;
  final String name;
  final String? phone;
  final String? email;
  final int autonomyLevel;
  final String language;
  final bool elderlyMode;
  final bool fallDetect;
  final int fallCountdownSec;

  AppUser({
    required this.id,
    required this.name,
    this.phone,
    this.email,
    required this.autonomyLevel,
    required this.language,
    this.elderlyMode = false,
    this.fallDetect = false,
    this.fallCountdownSec = 120,
  });

  factory AppUser.fromJson(Map<String, dynamic> j) => AppUser(
        id: j['id'] as int,
        name: (j['name'] ?? '') as String,
        phone: j['phone'] as String?,
        email: j['email'] as String?,
        autonomyLevel: (j['autonomy_level'] ?? 2) as int,
        language: (j['language'] ?? 'bn') as String,
        elderlyMode: (j['elderly_mode'] ?? false) as bool,
        fallDetect: (j['fall_detect'] ?? false) as bool,
        fallCountdownSec: (j['fall_countdown_sec'] ?? 120) as int,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'phone': phone,
        'email': email,
        'autonomy_level': autonomyLevel,
        'language': language,
      };
}

/// A "What AI knows" memory item. Stored locally (offline-first) and synced to the
/// backend. [source] marks AI-captured vs user-written (spec design #1).
class MemoryItem {
  final String localId; // stable local key
  int? serverId; // backend id once synced
  String category;
  String title;
  String detail;
  String source; // 'manual' | 'ai'
  bool needsReview;
  DateTime updatedAt;
  // sync state
  String pendingOp; // 'none' | 'create' | 'update' | 'delete'

  MemoryItem({
    required this.localId,
    this.serverId,
    this.category = '',
    required this.title,
    this.detail = '',
    this.source = 'manual',
    this.needsReview = false,
    required this.updatedAt,
    this.pendingOp = 'none',
  });

  bool get isAi => source == 'ai';

  Map<String, dynamic> toRow() => {
        'local_id': localId,
        'server_id': serverId,
        'category': category,
        'title': title,
        'detail': detail,
        'source': source,
        'needs_review': needsReview ? 1 : 0,
        'updated_at': updatedAt.toIso8601String(),
        'pending_op': pendingOp,
      };

  factory MemoryItem.fromRow(Map<String, dynamic> r) => MemoryItem(
        localId: r['local_id'] as String,
        serverId: r['server_id'] as int?,
        category: (r['category'] ?? '') as String,
        title: (r['title'] ?? '') as String,
        detail: (r['detail'] ?? '') as String,
        source: (r['source'] ?? 'manual') as String,
        needsReview: (r['needs_review'] ?? 0) == 1,
        updatedAt:
            DateTime.tryParse((r['updated_at'] ?? '') as String) ?? DateTime.now(),
        pendingOp: (r['pending_op'] ?? 'none') as String,
      );

  Map<String, dynamic> toServerJson() => {
        'category': category,
        'title': title,
        'detail': detail,
      };
}

class AuditEntry {
  final String action;
  final DateTime createdAt;
  final Map<String, dynamic> detail;
  AuditEntry({required this.action, required this.createdAt, required this.detail});

  factory AuditEntry.fromJson(Map<String, dynamic> j) => AuditEntry(
        action: (j['action'] ?? '') as String,
        createdAt: DateTime.tryParse((j['created_at'] ?? '') as String) ??
            DateTime.now(),
        detail: (j['detail'] ?? <String, dynamic>{}) as Map<String, dynamic>,
      );
}
