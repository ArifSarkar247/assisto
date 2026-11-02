import 'push_payload.dart';

/// channels (2 Nov) — how a `channel_post` push is DRAWN, in one small
/// function. The server sends title = channel name, body = a short preview
/// (channels are not end-to-end encrypted; their text is public). Muting is
/// per channel on the server (a muted follower gets no push at all), and the
/// newest post replaces the older one (one notification per channel —
/// PushPayload.notificationId 'chpost-<id>').
///
/// agent/notifs is rebuilding message notifications around
/// `buildMessageNotification(...)`; when it lands, switch THIS function over
/// to it — nothing else in the channel path needs to change.
({String title, String body}) channelPostNotificationContent(PushPayload p) {
  final title = p.title.trim().isNotEmpty ? p.title.trim() : 'Assisto';
  var body = p.body.trim();
  if (body.length > 140) body = '${body.substring(0, 137)}…';
  return (title: title, body: body);
}
