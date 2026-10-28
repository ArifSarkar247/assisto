import '../../api.dart';

/// agentmem (WP-MEMORY): every server call of the life-graph memory screen,
/// behind one seam so widget tests / the screenshot gallery inject a fake.
/// Shapes mirror backend/core/agentcore/memory_views.py (flag `agent_core`,
/// default OFF: every endpoint answers 403 feature_off).
abstract class LifeGraphSource {
  /// GET agent-core/memory?type=&status= -> {facts, counts, total, suggestions, prefs, types}
  Future<Map<String, dynamic>> list({String type = '', String status = 'active'});
  Future<Map<String, dynamic>> create(Map<String, dynamic> fact);
  Future<Map<String, dynamic>> update(int id, Map<String, dynamic> fields);
  Future<void> delete(int id);
  Future<Map<String, dynamic>> approve(int id);
  Future<void> reject(int id);
  Future<Map<String, dynamic>> confirm(int id);

  /// POST agent-core/memory/delete-all {confirm: DELETE} -> {deleted}
  Future<int> deleteAll();

  /// GET agent-core/memory/export -> the JSON file bytes (the user's own copy).
  Future<List<int>> exportBytes();
  Future<Map<String, dynamic>> setPrefs(Map<String, dynamic> prefs);
}

class ApiLifeGraphSource implements LifeGraphSource {
  final ApiClient api;
  ApiLifeGraphSource(this.api);

  static const _p = '/agent-core/memory';

  @override
  Future<Map<String, dynamic>> list({String type = '', String status = 'active'}) =>
      api.getJson('$_p?status=$status${type.isEmpty ? '' : '&type=$type'}');
  @override
  Future<Map<String, dynamic>> create(Map<String, dynamic> fact) => api.postJson(_p, fact);
  @override
  Future<Map<String, dynamic>> update(int id, Map<String, dynamic> fields) =>
      api.patchJson('$_p/$id', fields);
  @override
  Future<void> delete(int id) async => api.deleteJson('$_p/$id');
  @override
  Future<Map<String, dynamic>> approve(int id) => api.postJson('$_p/$id/approve');
  @override
  Future<void> reject(int id) async => api.postJson('$_p/$id/reject');
  @override
  Future<Map<String, dynamic>> confirm(int id) => api.postJson('$_p/$id/confirm');
  @override
  Future<int> deleteAll() async {
    final j = await api.postJson('$_p/delete-all', {'confirm': 'DELETE'});
    final d = j['deleted'];
    return d is int ? d : 0;
  }

  @override
  Future<List<int>> exportBytes() => api.getBytes('$_p/export');
  @override
  Future<Map<String, dynamic>> setPrefs(Map<String, dynamic> prefs) =>
      api.postJson('$_p/prefs', prefs);
}

int _i(Object? v) => v is int ? v : (v is num ? v.toInt() : int.tryParse('$v') ?? 0);
String _s(Object? v) => v == null ? '' : '$v';
DateTime? _t(Object? v) => v == null ? null : DateTime.tryParse('$v')?.toLocal();

/// The six fact types, in display order (server keys).
const kLgTypes = ['person', 'place', 'routine', 'preference', 'date', 'business'];

class LgFact {
  final int id;
  final String type, label, value, relation, when, status, origin;
  final bool sensitive, useInAi, stillRight;
  final int? replaces;
  final DateTime? createdAt, updatedAt;
  const LgFact({
    required this.id,
    required this.type,
    this.label = '',
    this.value = '',
    this.relation = '',
    this.when = '',
    this.status = 'active',
    this.origin = 'user',
    this.sensitive = false,
    this.useInAi = true,
    this.stillRight = false,
    this.replaces,
    this.createdAt,
    this.updatedAt,
  });

  factory LgFact.fromJson(Map j) => LgFact(
        id: _i(j['id']),
        type: _s(j['type']),
        label: _s(j['label']),
        value: _s(j['value']),
        relation: _s(j['relation']),
        when: _s(j['when']),
        status: _s(j['status']),
        origin: _s(j['origin']),
        sensitive: j['sensitive'] == true,
        useInAi: j['use_in_ai'] != false,
        stillRight: j['still_right'] == true,
        replaces: j['replaces'] == null ? null : _i(j['replaces']),
        createdAt: _t(j['created_at']),
        updatedAt: _t(j['updated_at']),
      );

  bool get isSuggestion => status == 'suggested';
}

class LgPrefs {
  final bool learningPaused;
  final int retentionMonths;
  final List<int> retentionChoices;
  const LgPrefs(
      {this.learningPaused = false,
      this.retentionMonths = 18,
      this.retentionChoices = const [6, 12, 18, 24]});

  factory LgPrefs.fromJson(Map? j) {
    final m = j ?? const {};
    final ch = [for (final c in (m['retention_choices'] as List? ?? const [])) _i(c)];
    return LgPrefs(
        learningPaused: m['learning_paused'] == true,
        retentionMonths: m['retention_months'] == null ? 18 : _i(m['retention_months']),
        retentionChoices: ch.isEmpty ? const [6, 12, 18, 24] : ch);
  }
}

class LgListing {
  final List<LgFact> facts;
  final Map<String, int> counts;
  final int total, suggestions;
  final LgPrefs prefs;
  const LgListing(
      {this.facts = const [],
      this.counts = const {},
      this.total = 0,
      this.suggestions = 0,
      this.prefs = const LgPrefs()});

  factory LgListing.fromJson(Map<String, dynamic> j) => LgListing(
        facts: [
          for (final f in (j['facts'] as List? ?? const []))
            if (f is Map) LgFact.fromJson(f),
        ],
        counts: {
          for (final e in ((j['counts'] as Map?) ?? const {}).entries) '${e.key}': _i(e.value),
        },
        total: _i(j['total']),
        suggestions: _i(j['suggestions']),
        prefs: LgPrefs.fromJson(j['prefs'] as Map?),
      );
}
