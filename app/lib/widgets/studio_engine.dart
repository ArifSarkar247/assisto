import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Agent Studio — on-device mirror of `backend/core/logic/agent_studio.py`.
///
/// A deterministic WHEN … IF … THEN rule engine so "Test / Run now", the due
/// decision and run history behave identically offline. The Python file is the
/// source of truth; this is a faithful port (same trigger/condition semantics,
/// same 5-minute schedule grace window, same last_fired dedupe).
///
/// Nothing here calls a model. The one AI-flavoured action ("summarize") is
/// only flagged `aiRequired` — the screen shows an honest mocked preview and
/// says it needs an AI key to run for real.
///
/// Automations are stored on this device (SharedPreferences, JSON). The
/// integration doc lists the endpoints/models the backend would add to persist
/// and actually fire them server-side.

const triggerTypes = ['schedule', 'event', 'keyword', 'incoming'];
const actionTypes = ['remind', 'message', 'log', 'summarize', 'tool'];
const conditionOps = ['==', '!=', '>', '>=', '<', '<=', 'contains'];
const aiActions = ['summarize'];

/// ----------------------------------------------------------------- models

class Trigger {
  String type; // schedule|event|keyword|incoming
  String at; // "HH:MM" (schedule)
  List<int> days; // ISO 1=Mon..7=Sun (schedule)
  int? dayOfMonth; // 1..31 (schedule)
  String event; // event
  List<String> keywords; // keyword
  String from; // incoming

  Trigger({
    this.type = 'schedule',
    this.at = '09:00',
    List<int>? days,
    this.dayOfMonth,
    this.event = '',
    List<String>? keywords,
    this.from = '',
  })  : days = days ?? [1, 2, 3, 4, 5, 6, 7],
        keywords = keywords ?? [];

  Map<String, dynamic> toJson() => {
        'type': type,
        if (type == 'schedule') 'at': at,
        if (type == 'schedule') 'days': days,
        if (type == 'schedule' && dayOfMonth != null) 'day_of_month': dayOfMonth,
        if (type == 'event') 'event': event,
        if (type == 'keyword') 'keywords': keywords,
        if (type == 'incoming') 'from': from,
      };

  factory Trigger.fromJson(Map<String, dynamic> j) => Trigger(
        type: j['type']?.toString() ?? 'schedule',
        at: j['at']?.toString() ?? '09:00',
        days: (j['days'] as List?)?.map((e) => (e as num).toInt()).toList(),
        dayOfMonth: (j['day_of_month'] as num?)?.toInt(),
        event: j['event']?.toString() ?? '',
        keywords:
            (j['keywords'] as List?)?.map((e) => e.toString()).toList() ?? [],
        from: j['from']?.toString() ?? '',
      );
}

class Condition {
  String field;
  String op;
  String value;
  Condition({this.field = '', this.op = '==', this.value = ''});
  Map<String, dynamic> toJson() => {'field': field, 'op': op, 'value': value};
  factory Condition.fromJson(Map<String, dynamic> j) => Condition(
        field: j['field']?.toString() ?? '',
        op: j['op']?.toString() ?? '==',
        value: j['value']?.toString() ?? '',
      );
}

class StudioAction {
  String type; // remind|message|log|summarize|tool
  String text;
  String to; // message
  String source; // summarize
  String tool; // tool
  StudioAction({
    this.type = 'remind',
    this.text = '',
    this.to = 'self',
    this.source = 'today',
    this.tool = '',
  });
  bool get aiRequired => aiActions.contains(type);
  Map<String, dynamic> toJson() => {
        'type': type,
        if (type == 'remind' || type == 'message' || type == 'log')
          'text': text,
        if (type == 'message') 'to': to,
        if (type == 'summarize') 'source': source,
        if (type == 'tool') 'tool': tool,
      };
  factory StudioAction.fromJson(Map<String, dynamic> j) => StudioAction(
        type: j['type']?.toString() ?? 'remind',
        text: j['text']?.toString() ?? '',
        to: j['to']?.toString() ?? 'self',
        source: j['source']?.toString() ?? 'today',
        tool: j['tool']?.toString() ?? '',
      );
}

class RunEntry {
  final String at; // ISO
  final bool manual; // test/run-now vs scheduled
  final List<String> actionTypes;
  final bool usedAiMock;
  RunEntry(
      {required this.at,
      required this.manual,
      required this.actionTypes,
      required this.usedAiMock});
  Map<String, dynamic> toJson() => {
        'at': at,
        'manual': manual,
        'actions': actionTypes,
        'ai_mock': usedAiMock,
      };
  factory RunEntry.fromJson(Map<String, dynamic> j) => RunEntry(
        at: j['at']?.toString() ?? '',
        manual: j['manual'] == true,
        actionTypes:
            (j['actions'] as List?)?.map((e) => e.toString()).toList() ?? [],
        usedAiMock: j['ai_mock'] == true,
      );
}

class Automation {
  String id;
  String name;
  bool enabled;
  List<Trigger> triggers;
  List<Condition> conditions;
  String match; // all|any
  List<StudioAction> actions;
  String? lastFired; // ISO
  List<RunEntry> history;

  Automation({
    required this.id,
    this.name = '',
    this.enabled = true,
    List<Trigger>? triggers,
    List<Condition>? conditions,
    this.match = 'all',
    List<StudioAction>? actions,
    this.lastFired,
    List<RunEntry>? history,
  })  : triggers = triggers ?? [Trigger()],
        conditions = conditions ?? [],
        actions = actions ?? [StudioAction()],
        history = history ?? [];

  bool get needsAi => actions.any((a) => a.aiRequired);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'enabled': enabled,
        'triggers': triggers.map((t) => t.toJson()).toList(),
        'conditions': conditions.map((c) => c.toJson()).toList(),
        'match': match,
        'actions': actions.map((a) => a.toJson()).toList(),
        'last_fired': lastFired,
        'history': history.map((h) => h.toJson()).toList(),
      };

  factory Automation.fromJson(Map<String, dynamic> j) => Automation(
        id: j['id']?.toString() ??
            DateTime.now().microsecondsSinceEpoch.toString(),
        name: j['name']?.toString() ?? '',
        enabled: j['enabled'] != false,
        triggers: (j['triggers'] as List?)
            ?.map((e) => Trigger.fromJson(e as Map<String, dynamic>))
            .toList(),
        conditions: (j['conditions'] as List?)
            ?.map((e) => Condition.fromJson(e as Map<String, dynamic>))
            .toList(),
        match: j['match']?.toString() ?? 'all',
        actions: (j['actions'] as List?)
            ?.map((e) => StudioAction.fromJson(e as Map<String, dynamic>))
            .toList(),
        lastFired: j['last_fired']?.toString(),
        history: (j['history'] as List?)
            ?.map((e) => RunEntry.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Automation copy() =>
      Automation.fromJson(jsonDecode(jsonEncode(toJson())) as Map<String, dynamic>);
}

/// ----------------------------------------------------------------- engine

class StudioEngine {
  StudioEngine._();

  /// Validation problem keys (empty ⇒ valid). Mirrors agent_studio.validate.
  static List<String> validate(Automation a) {
    final problems = <String>[];
    if (a.name.trim().isEmpty) problems.add('name_required');
    if (a.triggers.isEmpty) problems.add('trigger_required');
    for (final t in a.triggers) {
      if (!triggerTypes.contains(t.type)) problems.add('bad_trigger');
      if (t.type == 'schedule' && _parseHm(t.at) == null) {
        problems.add('bad_time');
      }
      if (t.type == 'keyword' &&
          t.keywords.where((k) => k.trim().isNotEmpty).isEmpty) {
        problems.add('keyword_required');
      }
      if (t.type == 'event' && t.event.trim().isEmpty) problems.add('event_required');
      if (t.type == 'incoming' && t.from.trim().isEmpty) problems.add('source_required');
    }
    if (a.actions.isEmpty) problems.add('action_required');
    // de-dupe, keep order
    final seen = <String>{};
    return problems.where((p) => seen.add(p)).toList();
  }

  static bool isDue(Automation a, DateTime now,
      {Map<String, dynamic> ctx = const {}, int graceMinutes = 5}) {
    if (!a.enabled) return false;
    bool armed = false, scheduled = false;
    for (final t in a.triggers) {
      if (_triggerFires(t, now, ctx, graceMinutes)) {
        armed = true;
        if (t.type == 'schedule') scheduled = true;
      }
    }
    if (!armed) return false;
    if (scheduled && _firedThisWindow(a, now, graceMinutes)) return false;
    return conditionsPass(a, ctx);
  }

  /// Due automations with their action plans. Mirrors agent_studio.evaluate.
  static List<Automation> evaluate(List<Automation> list, DateTime now,
      {Map<String, dynamic> ctx = const {}, int graceMinutes = 5}) {
    return list
        .where((a) =>
            isDue(a, now, ctx: ctx, graceMinutes: graceMinutes))
        .toList();
  }

  static bool conditionsPass(Automation a, Map<String, dynamic> ctx) {
    if (a.conditions.isEmpty) return true;
    final results = a.conditions.map((c) => evalCondition(c, ctx)).toList();
    return a.match == 'any' ? results.any((r) => r) : results.every((r) => r);
  }

  static bool evalCondition(Condition c, Map<String, dynamic> ctx) {
    if (!ctx.containsKey(c.field)) return false;
    final got = ctx[c.field];
    switch (c.op) {
      case '==':
        return got.toString() == c.value;
      case '!=':
        return got.toString() != c.value;
      case 'contains':
        return got.toString().toLowerCase().contains(c.value.toLowerCase());
    }
    final gn = _asNum(got), wn = _asNum(c.value);
    if (gn == null || wn == null) return false;
    switch (c.op) {
      case '>':
        return gn > wn;
      case '>=':
        return gn >= wn;
      case '<':
        return gn < wn;
      case '<=':
        return gn <= wn;
    }
    return false;
  }

  static bool _triggerFires(
      Trigger t, DateTime now, Map<String, dynamic> ctx, int grace) {
    switch (t.type) {
      case 'schedule':
        final hm = _parseHm(t.at);
        if (hm == null) return false;
        if (t.days.isNotEmpty && !t.days.contains(now.weekday)) return false;
        if (t.dayOfMonth != null) {
          final dom = t.dayOfMonth!.clamp(1, _lastDay(now.year, now.month));
          if (now.day != dom) return false;
        }
        final start =
            DateTime(now.year, now.month, now.day, hm[0], hm[1]);
        final end = start.add(Duration(minutes: grace < 0 ? 0 : grace));
        return !now.isBefore(start) && now.isBefore(end);
      case 'event':
        final e = ctx['event']?.toString() ?? '';
        return e.isNotEmpty && e == t.event;
      case 'keyword':
        final text = (ctx['text']?.toString() ?? '').toLowerCase();
        return t.keywords.any((k) {
          final kk = k.toLowerCase();
          return kk.isNotEmpty && text.contains(kk);
        });
      case 'incoming':
        final src = (ctx['incoming_from']?.toString() ?? '').toLowerCase();
        return src.isNotEmpty && src == t.from.toLowerCase();
    }
    return false;
  }

  static bool _firedThisWindow(Automation a, DateTime now, int grace) {
    if (a.lastFired == null) return false;
    final last = DateTime.tryParse(a.lastFired!);
    if (last == null) return false;
    return now.difference(last) < Duration(minutes: grace < 1 ? 1 : grace);
  }

  static List<int>? _parseHm(String v) {
    final parts = v.split(':');
    if (parts.length != 2) return null;
    final h = int.tryParse(parts[0]), m = int.tryParse(parts[1]);
    if (h == null || m == null || h < 0 || h > 23 || m < 0 || m > 59) {
      return null;
    }
    return [h, m];
  }

  static int _lastDay(int y, int m) =>
      DateTime(y, m == 12 ? y + 1 : y, m == 12 ? 1 : m + 1, 0)
          .subtract(const Duration(days: 1))
          .day;

  static num? _asNum(Object? v) {
    if (v is bool) return null;
    if (v is num) return v;
    return num.tryParse(v.toString().trim());
  }
}

/// ----------------------------------------------------------------- storage

class StudioStore {
  static const _key = 'agent_studio_automations_v1';

  static Future<List<Automation>> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => Automation.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(List<Automation> list) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, jsonEncode(list.map((a) => a.toJson()).toList()));
  }
}

/// Template seeds — mirror agent_studio.TEMPLATES. `name`/action text is a
/// localisation KEY the UI resolves, never shown raw.
class StudioTemplates {
  static List<Automation> build() => [
        Automation(
          id: 't_bill',
          name: 'studioTplBill',
          triggers: [Trigger(type: 'schedule', at: '09:00', dayOfMonth: 1)],
          actions: [StudioAction(type: 'remind', text: 'studioTplBillText')],
        ),
        Automation(
          id: 't_summary',
          name: 'studioTplSummary',
          triggers: [Trigger(type: 'schedule', at: '21:00')],
          actions: [StudioAction(type: 'summarize', source: 'today')],
        ),
        Automation(
          id: 't_followup',
          name: 'studioTplFollowup',
          triggers: [Trigger(type: 'event', event: 'lead_created')],
          actions: [StudioAction(type: 'remind', text: 'studioTplFollowupText')],
        ),
        Automation(
          id: 't_birthday',
          name: 'studioTplBirthday',
          triggers: [Trigger(type: 'event', event: 'birthday_today')],
          actions: [
            StudioAction(type: 'message', to: 'self', text: 'studioTplBirthdayText')
          ],
        ),
      ];
}
