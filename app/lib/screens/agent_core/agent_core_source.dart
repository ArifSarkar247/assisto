import '../../api.dart';

/// agent-core WP-APP: every server call the agent screens make, behind one
/// seam so widget tests / the screenshot gallery inject a fake. Shapes mirror
/// backend/core/agentcore/views.py (flag `agent_core`, default OFF: every
/// endpoint answers 403 feature_off).
abstract class AgentCoreSource {
  /// GET agent-core/tools -> {version, estimate, topics, tools}
  Future<Map<String, dynamic>> tools();

  /// POST agent-core/goals -> run (detail)
  Future<Map<String, dynamic>> startGoal(String text, {required String clientId});
  Future<Map<String, dynamic>> runs();
  Future<Map<String, dynamic>> run(int id);
  Future<Map<String, dynamic>> cancel(int id);
  Future<Map<String, dynamic>> feedback(int id, int value, String note);
  Future<Map<String, dynamic>> approvals();

  /// POST agent-core/approvals/<id> {decision} -> {approval, run}
  Future<Map<String, dynamic>> decide(int id, String decision);
}

class ApiAgentCoreSource implements AgentCoreSource {
  final ApiClient api;
  ApiAgentCoreSource(this.api);

  static const _p = '/agent-core';

  @override
  Future<Map<String, dynamic>> tools() => api.getJson('$_p/tools');
  @override
  Future<Map<String, dynamic>> startGoal(String text, {required String clientId}) =>
      api.postJson('$_p/goals', {'text': text, 'channel': 'chat', 'client_id': clientId});
  @override
  Future<Map<String, dynamic>> runs() => api.getJson('$_p/runs');
  @override
  Future<Map<String, dynamic>> run(int id) => api.getJson('$_p/runs/$id');
  @override
  Future<Map<String, dynamic>> cancel(int id) => api.postJson('$_p/runs/$id/cancel');
  @override
  Future<Map<String, dynamic>> feedback(int id, int value, String note) =>
      api.postJson('$_p/runs/$id/feedback', {'value': value, 'note': note});
  @override
  Future<Map<String, dynamic>> approvals() => api.getJson('$_p/approvals');
  @override
  Future<Map<String, dynamic>> decide(int id, String decision) =>
      api.postJson('$_p/approvals/$id', {'decision': decision});
}

int _i(Object? v) => v is int ? v : (v is num ? v.toInt() : int.tryParse('$v') ?? 0);
String _s(Object? v) => v == null ? '' : '$v';
DateTime? _t(Object? v) => v == null ? null : DateTime.tryParse('$v')?.toLocal();

/// The credit cost shown BEFORE a goal runs (owner rule).
class AcEstimate {
  final int planCredits, typicalCredits, maxCredits, runsPerDay, runsLeftToday;
  const AcEstimate(
      {required this.planCredits,
      required this.typicalCredits,
      required this.maxCredits,
      required this.runsPerDay,
      required this.runsLeftToday});

  factory AcEstimate.fromJson(Map<String, dynamic>? j) {
    final m = j ?? const {};
    return AcEstimate(
        planCredits: _i(m['plan_credits']),
        typicalCredits: _i(m['typical_credits']),
        maxCredits: _i(m['max_credits']),
        runsPerDay: _i(m['runs_per_day']),
        runsLeftToday: _i(m['runs_left_today']));
  }
}

/// tool name -> its bilingual label (the "source" a result came from).
class AcTools {
  final Map<String, ({String bn, String en})> labels;
  final AcEstimate estimate;
  const AcTools(this.labels, this.estimate);

  factory AcTools.fromJson(Map<String, dynamic> j) {
    final out = <String, ({String bn, String en})>{};
    for (final t in (j['tools'] as List? ?? const [])) {
      if (t is Map) {
        out[_s(t['name'])] = (bn: _s(t['label_bn']), en: _s(t['label_en']));
      }
    }
    return AcTools(out, AcEstimate.fromJson(j['estimate'] as Map<String, dynamic>?));
  }

  String label(String tool, bool bn) {
    final l = labels[tool];
    if (l == null) return tool;
    final v = bn ? l.bn : l.en;
    return v.isEmpty ? tool : v;
  }
}

class AcStep {
  final int no;
  final String kind, tool, state, risk, summary, error;
  final int credits;
  const AcStep(this.no, this.kind, this.tool, this.state, this.risk, this.summary,
      this.credits, this.error);

  factory AcStep.fromJson(Map j) => AcStep(_i(j['no']), _s(j['kind']), _s(j['tool']),
      _s(j['state']), _s(j['risk']), _s(j['summary']), _i(j['credits']), _s(j['error']));
}

class AcApproval {
  final int id, run, credits;
  final String risk, status, title, tool, toolLabel, goal;
  final DateTime? expiresAt;
  final List<({String key, String value})> details;
  const AcApproval(
      {required this.id,
      required this.run,
      required this.risk,
      required this.status,
      required this.title,
      required this.expiresAt,
      this.tool = '',
      this.toolLabel = '',
      this.credits = 0,
      this.goal = '',
      this.details = const []});

  factory AcApproval.fromJson(Map j) => AcApproval(
        id: _i(j['id']),
        run: _i(j['run']),
        risk: _s(j['risk']),
        status: _s(j['status']),
        title: _s(j['title']),
        expiresAt: _t(j['expires_at']),
        tool: _s(j['tool']),
        toolLabel: _s(j['tool_label']),
        credits: _i(j['credits']),
        goal: _s(j['goal']),
        details: [
          for (final d in (j['details'] as List? ?? const []))
            if (d is Map) (key: _s(d['key']), value: _s(d['value'])),
        ],
      );

  bool expired(DateTime now) => expiresAt != null && now.isAfter(expiresAt!);

  /// The server shows phone / account numbers partly hidden with '•'.
  bool get hasMasked => details.any((d) => d.value.contains('•'));
}

class AcRun {
  final int id, credits, steps;
  final int? feedback;
  final String state, topic, topicLabel, goal, answer, error, errorText;
  final DateTime? createdAt, finishedAt;
  final List<AcStep> trail;
  final List<AcApproval> approvals;
  const AcRun(
      {required this.id,
      required this.state,
      this.topic = '',
      this.topicLabel = '',
      this.goal = '',
      this.answer = '',
      this.error = '',
      this.errorText = '',
      this.credits = 0,
      this.steps = 0,
      this.createdAt,
      this.finishedAt,
      this.feedback,
      this.trail = const [],
      this.approvals = const []});

  factory AcRun.fromJson(Map<String, dynamic> j) => AcRun(
        id: _i(j['id']),
        state: _s(j['state']),
        topic: _s(j['topic']),
        topicLabel: _s(j['topic_label']),
        goal: _s(j['goal']),
        answer: _s(j['answer']),
        error: _s(j['error']),
        errorText: _s(j['error_text']),
        credits: _i(j['credits']),
        steps: _i(j['steps']),
        createdAt: _t(j['created_at']),
        finishedAt: _t(j['finished_at']),
        feedback: j['feedback'] == null ? null : _i(j['feedback']),
        trail: [
          for (final s in (j['trail'] as List? ?? const []))
            if (s is Map) AcStep.fromJson(s),
        ],
        approvals: [
          for (final a in (j['approvals'] as List? ?? const []))
            if (a is Map) AcApproval.fromJson(a),
        ],
      );

  static const openStates = {'queued', 'running', 'waiting_approval'};
  bool get isOpen => openStates.contains(state);

  /// The server is still working on it (poll); waiting_approval waits on
  /// the user, so polling stops there.
  bool get isWorking => state == 'queued' || state == 'running';

  bool get outOfCredits => error == 'credits' || error == 'ai_credits';
  bool get aiNotSetUp => error == 'ai_no_key';

  /// Tool steps that finished: the "sources" of the result.
  List<AcStep> get sources =>
      [for (final s in trail) if (s.kind == 'tool' && s.state == 'done') s];
}
