import 'api.dart';

/// HOME (Assisto chat) screen API surface — the top-bar badges and the
/// dynamic suggestion cards driven by the backend rule-engine.
///
/// Implemented as an EXTENSION on [ApiClient] built ONLY on its public helpers
/// ([ApiClient.getJson] / [ApiClient.postJson]) so this ships WITHOUT editing
/// the shared api.dart core. The integrator SHOULD later fold these into
/// ApiClient proper — the signatures and paths below are authoritative.
///
/// Localisation: ApiClient already sends `Accept-Language: bn|en`; on top of
/// that `homeSuggestions` passes an explicit `?lang=` so the engine returns
/// prompts in the ACTIVE language ONLY (strict — never mixed).
extension HomeApi on ApiClient {
  /// GET /home/badges -> { my_circle_unread: int, notif_unseen: int }.
  ///
  /// Both counts drive the top-right badge bubbles. Missing / non-int values
  /// are coerced to 0 so a partial response never crashes the bar.
  Future<HomeBadges> homeBadges() async {
    final j = await getJson('/home/badges');
    return HomeBadges(
      myCircleUnread: _asInt(j['my_circle_unread']),
      notifUnseen: _asInt(j['notif_unseen']),
    );
  }

  /// GET /home/suggestions?lang=<locale> -> { suggestions: [ {key,text,route?,
  /// prompt?,icon?}, ... ] } — the rule-engine returns up to 4 RANKED prompts
  /// in the active language only. New users get onboarding prompts (the engine
  /// decides). The prompt TEXT is authoritative from the server; never
  /// hard-coded client-side.
  ///
  /// [lang] is the current locale code ('bn' | 'en').
  Future<List<HomeSuggestion>> homeSuggestions(String lang) async {
    final j = await getJson('/home/suggestions?lang=${Uri.encodeQueryComponent(lang)}');
    final raw = (j['suggestions'] ?? j['items'] ?? j['prompts'] ?? const []) as List;
    return raw
        .whereType<Map>()
        .map((m) => HomeSuggestion.fromJson(m.cast<String, dynamic>()))
        .where((s) => s.text.isNotEmpty)
        .take(4)
        .toList();
  }

  /// POST /home/suggestions/dismiss { key } — long-press "Don't show this".
  /// The engine stops surfacing this prompt key for the user.
  Future<void> homeSuggestionDismiss(String key) =>
      postJson('/home/suggestions/dismiss', {'key': key});

  static int _asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('${v ?? ''}') ?? 0;
  }
}

/// The two unread/unseen counts shown as top-bar badges.
class HomeBadges {
  final int myCircleUnread;
  final int notifUnseen;
  const HomeBadges({this.myCircleUnread = 0, this.notifUnseen = 0});
  static const empty = HomeBadges();
}

/// One ranked home prompt card from the engine. [text] is the already-localised
/// label to render. [route] (if set) navigates; otherwise [prompt] (falling
/// back to [text]) is sent to the agent. [key] identifies it for dismissal.
class HomeSuggestion {
  final String key;
  final String text;
  final String? route;
  final String? prompt;
  final String? icon;
  const HomeSuggestion({
    required this.key,
    required this.text,
    this.route,
    this.prompt,
    this.icon,
  });

  /// The text actually sent to the agent when there is no route.
  String get sendText => (prompt != null && prompt!.trim().isNotEmpty)
      ? prompt!.trim()
      : text;

  factory HomeSuggestion.fromJson(Map<String, dynamic> m) => HomeSuggestion(
        key: (m['key'] ?? m['id'] ?? m['text'] ?? '').toString(),
        text: (m['text'] ?? m['title'] ?? m['label'] ?? '').toString().trim(),
        route: (m['route'] as String?)?.trim().isEmpty == true
            ? null
            : m['route'] as String?,
        prompt: m['prompt'] as String?,
        icon: m['icon'] as String?,
      );

  Map<String, dynamic> toCache() => {
        'key': key,
        'text': text,
        if (route != null) 'route': route,
        if (prompt != null) 'prompt': prompt,
        if (icon != null) 'icon': icon,
      };
}
