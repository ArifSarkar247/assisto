import '../../api.dart';

/// bizops: the morning BUSINESS card's two server calls, behind one seam so
/// widget tests / the screenshot gallery inject a fake. Shapes mirror
/// backend/core/agentcore/bizops.py (flags agent_core + business; 403
/// feature_off otherwise).
abstract class BizBriefSource {
  /// GET agent-core/biz-brief -> the card
  Future<Map<String, dynamic>> brief();

  /// POST agent-core/biz-brief/act {kind, ...} -> run (detail)
  Future<Map<String, dynamic>> act(Map<String, dynamic> body);
}

class ApiBizBriefSource implements BizBriefSource {
  final ApiClient api;
  ApiBizBriefSource(this.api);

  @override
  Future<Map<String, dynamic>> brief() => api.getJson('/agent-core/biz-brief');
  @override
  Future<Map<String, dynamic>> act(Map<String, dynamic> body) =>
      api.postJson('/agent-core/biz-brief/act', body);
}

String _s(Object? v) => v == null ? '' : '$v';

class BoLine {
  final String key, text;
  const BoLine(this.key, this.text);
}

class BoAction {
  final String kind, target, label;
  final bool approval;
  final Map<String, dynamic> args;
  const BoAction(
      {required this.kind,
      required this.target,
      required this.label,
      required this.approval,
      this.args = const {}});
}

class BoQuestion {
  final String key, text;
  const BoQuestion(this.key, this.text);
}

class BoCard {
  final bool hasBusiness, empty, aiReady;
  final String shop, date;
  final List<BoLine> lines;
  final List<BoAction> actions;
  final List<BoQuestion> questions;
  final List<String> suppliers, costLines;
  const BoCard(
      {required this.hasBusiness,
      required this.empty,
      this.aiReady = false,
      this.shop = '',
      this.date = '',
      this.lines = const [],
      this.actions = const [],
      this.questions = const [],
      this.suppliers = const [],
      this.costLines = const []});

  factory BoCard.fromJson(Map<String, dynamic> j) {
    final cost = j['cost'] is Map ? j['cost'] as Map : const {};
    return BoCard(
      hasBusiness: j['has_business'] == true,
      empty: j['empty'] == true,
      aiReady: j['ai_ready'] == true,
      shop: _s(j['shop']),
      date: _s(j['date']),
      lines: [
        for (final l in (j['lines'] as List? ?? const []))
          if (l is Map && _s(l['text']).isNotEmpty) BoLine(_s(l['key']), _s(l['text'])),
      ],
      actions: [
        for (final a in (j['actions'] as List? ?? const []))
          if (a is Map)
            BoAction(
                kind: _s(a['kind']),
                target: _s(a['target']),
                label: _s(a['label']),
                approval: a['approval'] == true,
                args: a['args'] is Map ? Map<String, dynamic>.from(a['args'] as Map) : const {}),
      ],
      questions: [
        for (final q in (j['questions'] as List? ?? const []))
          if (q is Map) BoQuestion(_s(q['key']), _s(q['text'])),
      ],
      suppliers: [for (final x in (j['suppliers'] as List? ?? const [])) _s(x)],
      costLines: [for (final x in (cost['lines'] as List? ?? const [])) _s(x)],
    );
  }
}
