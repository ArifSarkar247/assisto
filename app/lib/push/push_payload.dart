import 'dart:convert';

/// Pure (no Flutter, no plugins) model of an Assisto FCM data payload.
///
/// Backend contract (backend/core/push.py `push_to_user`): every value is a
/// STRING. Always present: `kind, title, body, lang, channel, sent_at`. Extras
/// per kind, e.g. call: `call_id, caller_id, caller_name, video, chat_id,
/// route`; message: `message_id, chat_kind, chat_id, sender_id, sender_name,
/// route`; reminder: `reminder_id, due_at, route`; sos: `from_user_id,
/// from_name, lat, lng, silent, route`.
///
/// Calls / call_cancel / SOS arrive DATA-ONLY (the app draws the UI itself).
class PushChannels {
  PushChannels._();

  static const messages = 'messages';
  static const calls = 'calls';
  static const reminders = 'reminders';
  static const alerts = 'alerts';
  static const sos = 'sos';
  static const missedCalls = 'missed_calls'; // c2-calls
  static const offers = 'offers'; // p2-money: brand offers (opt-in, max 2/day)

  static const all = [messages, calls, reminders, alerts, sos, missedCalls, offers];

  /// kind -> channel (mirror of push.CHANNELS; used when `channel` is absent).
  static const byKind = {
    'message': messages,
    'call': calls,
    'call_cancel': calls,
    'reminder': reminders,
    'family_alert': alerts,
    'owner_alert': alerts,
    'shop_alert': alerts,
    'sos': sos,
    'missed_call': missedCalls,
    'message_request': messages, // mr1
    'offer': offers, // p2-money
    'meter_low': alerts, // remmeter: prepaid meter running low
    'agent_approval': alerts, // agent-core WP-APP: Approve / Reject actions
    'agent_nudge': alerts, // agent-proactive (Agent Core nudge / brief)
  };
}

class PushPayload {
  PushPayload(Map<String, String> data) : data = Map.unmodifiable(data);

  final Map<String, String> data;

  /// Accepts the raw FCM `RemoteMessage.data` map (values may be non-strings
  /// in tests); every value is stringified, nulls dropped.
  factory PushPayload.fromData(Map<dynamic, dynamic>? raw) {
    final out = <String, String>{};
    (raw ?? const {}).forEach((k, v) {
      if (k == null || v == null) return;
      out['$k'] = '$v';
    });
    return PushPayload(out);
  }

  /// Payload stored on a local notification (tap / action round-trip).
  static PushPayload? decode(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      final m = jsonDecode(s);
      if (m is Map) return PushPayload.fromData(m);
    } catch (_) {}
    return null;
  }

  String encode() => jsonEncode(data);

  String _s(String k) => (data[k] ?? '').trim();

  String get kind => _s('kind');
  String get title => _s('title');
  String get body => _s('body');
  String get lang => _s('lang') == 'en' ? 'en' : 'bn';
  String get route => _s('route');
  String get channel {
    final c = _s('channel');
    if (PushChannels.all.contains(c)) return c;
    return PushChannels.byKind[kind] ?? PushChannels.alerts;
  }

  String get callId => _s('call_id');
  String get chatId => _s('chat_id');
  String get callerName => _s('caller_name');
  String get callerPhoto => _s('caller_photo'); // x1-calls (signed URL)
  String get callerId => _s('caller_id');

  /// x1-calls: FCM "call_signal" nudge — poll the call queue now (no UI).
  bool get isCallNudge => kind == 'call_signal';
  bool get isVideo => _s('video') == 'true';
  bool get silent => _s('silent') == 'true';

  bool get isKnownKind => PushChannels.byKind.containsKey(kind);
  bool get isCall => kind == 'call';
  bool get isCallCancel => kind == 'call_cancel';
  bool get isMissedCall => kind == 'missed_call'; // c2-calls
  bool get isSos => kind == 'sos';
  bool get isAgentApproval => kind == 'agent_approval'; // agent-core WP-APP

  /// Calls and SOS take over the screen (full-screen intent).
  bool get wantsFullScreen => isCall || isSos;

  /// The backend marks these data-only, so the app must draw them itself even
  /// when it is in the background.
  bool get isDataOnly => isCall || isCallCancel || isSos;

  /// Stable Android notification id. A call and its cancel share the id so a
  /// cancel can dismiss the ringing; messages from one chat collapse into one.
  int get notificationId {
    String key;
    if ((isCall || isCallCancel) && callId.isNotEmpty) {
      key = 'call-$callId';
    } else if (isMissedCall && _s('group_key').isNotEmpty) {
      // x1-calls A1-g: ONE "T Shanto BD (6)" notification per caller
      key = 'missed-${_s('group_key')}';
    } else if (isMissedCall && callId.isNotEmpty) {
      key = 'missed-$callId';
    } else if (kind == 'message_request' && _s('sender_id').isNotEmpty) {
      // mr1: ONE notification per sender (a new message replaces it)
      key = 'msgreq-${_s('sender_id')}';
    } else if (kind == 'message' && chatId.isNotEmpty) {
      key = 'chat-${_s('chat_kind')}-$chatId';
    } else if (kind == 'agent_approval' && _s('approval_id').isNotEmpty) {
      // agent-core: one notification per approval (Reject removes it)
      key = 'agentap-${_s('approval_id')}';
    } else if (kind == 'reminder' && _s('reminder_id').isNotEmpty) {
      key = 'rem-${_s('reminder_id')}';
    } else {
      key = '$kind-${_s('sent_at')}-${_s('message_id')}${_s('event_id')}';
    }
    return stableHash(key);
  }

  /// FNV-1a 31-bit — identical across isolates/launches (String.hashCode is
  /// not guaranteed stable between runs, and the background isolate must
  /// compute the same id as the UI isolate to cancel a ring).
  static int stableHash(String s) {
    var h = 0x811c9dc5;
    for (final c in utf8.encode(s)) {
      h ^= c;
      h = (h * 0x01000193) & 0xffffffff;
    }
    return h & 0x7fffffff;
  }
}

/// Where a tapped push should land. [chatNavRoute] is a key of
/// `ChatNav.routes`; [openIncomingCall] means "open the My Circle call screen
/// for this call (incoming)".
class PushTarget {
  const PushTarget({this.chatNavRoute, this.openIncomingCall = false});
  final String? chatNavRoute;
  final bool openIncomingCall;

  @override
  String toString() =>
      'PushTarget(route: $chatNavRoute, call: $openIncomingCall)';
}

class PushRouting {
  PushRouting._();

  /// backend `route` value -> ChatNav route key.
  static const routeMap = {
    'circle/chat': 'messages',
    'circle/group': 'messages',
    'circle/requests': 'messages', // mr1
    'circle/call': 'circle_calls',
    'circle/calls': 'circle_calls',
    'reminders': 'reminders',
    'alerts': 'notifications',
    // family100: SOS + family alerts open the family alerts screen
    'safety/sos': 'family_alerts',
    'family/alerts': 'family_alerts',
    'security/lost-phone': 'my_lost_phone',
    // journey100: Safe Journey pushes
    'journey': 'journey', // the traveller: Are you OK? / routine
    'journey/watch': 'journey_watch', // a watcher: started/late/arrived...
    'journey/wellness': 'journey_settings', // a parent: Is everything OK?
    'business/shop-box': 'shop_box',
    'watchman': 'watchman', // cctv1
    'retention_inbox': 'retention_inbox', // retention1 (customer)
    'retention_auto': 'retention_auto', // retention1 (owner: a reply)
    'business': 'business',
    'owner': 'analytics',
    'account/delete': 'account_delete', // dl1
    'prepaid_meter': 'prepaid_meter', // remmeter
    'agent/approval': 'agent_approvals', // agent-core WP-APP
    'agent': 'agent_core', // agent-proactive nudge / brief -> the agent screen
  };

  /// kind -> fallback route when `route` is missing/unknown.
  static const kindMap = {
    'message': 'messages',
    'message_request': 'messages', // mr1
    'call_cancel': 'circle_calls',
    'missed_call': 'circle_calls',
    'reminder': 'reminders',
    'family_alert': 'notifications',
    'owner_alert': 'notifications',
    'shop_alert': 'shop_box',
    'sos': 'family_alerts',
    'meter_low': 'prepaid_meter', // remmeter
    'agent_approval': 'agent_approvals', // agent-core WP-APP
    'agent_nudge': 'agent_core', // agent-proactive (flag-gated route)
  };

  /// [action] is the local-notification action id ('accept' / 'decline' /
  /// null for a plain tap). Decline never opens anything.
  static PushTarget? targetFor(PushPayload p, {String? action}) {
    if (action == 'decline') return null;
    if (p.isCall) {
      if (p.chatId.isEmpty) {
        return const PushTarget(chatNavRoute: 'circle_calls');
      }
      return const PushTarget(openIncomingCall: true);
    }
    final r = routeMap[p.route] ?? kindMap[p.kind];
    if (r == null) return null;
    return PushTarget(chatNavRoute: r);
  }
}
