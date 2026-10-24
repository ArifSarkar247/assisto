// cde-chat (order 6 D + E) — E2E CONTROL messages: a theme change or a
// nickname change travels INSIDE the chat as an ordinary E2E message, so both
// phones see it at once and an offline phone gets it when it comes online.
//
// Text form (theme preset, nickname):
//
//     <readable fallback line>\n⁣CC1:<base64url(JSON)>
//
// exactly like the p3 Assisto cards: notifications, chat previews and older
// app versions show the readable line; this app draws a centred system line
// and folds the change into the chat's DecorStore.
//
// Custom photo theme: a normal md1 PHOTO message whose descriptor JSON also
// carries `"cc1": {...}` — older versions simply show the photo; this app
// uses it as the wallpaper. The file key never leaves the E2E envelope.
import 'dart:convert';

const String kControlMarker = '⁣CC1:';

/// One decoded control event.
class ChatControl {
  /// 'theme' | 'nick'
  final String type;

  /// theme: the theme id ('classic' = none, 'custom' / 'ai' = photo).
  final String themeId;

  /// nick (1:1): 'sender' (the sender named themself) | 'recipient'.
  final String who;

  /// nick (group): the target's user id.
  final int? uid;

  /// nick: the new nickname; '' = removed.
  final String name;

  /// Server time of the write (ms since epoch) — newest wins on every phone.
  final int at;

  const ChatControl._(this.type,
      {this.themeId = '', this.who = '', this.uid, this.name = '', this.at = 0});

  const ChatControl.theme(String id, {int at = 0})
      : this._('theme', themeId: id, at: at);

  const ChatControl.nick({String who = '', int? uid, required String name, int at = 0})
      : this._('nick', who: who, uid: uid, name: name, at: at);

  bool get isTheme => type == 'theme';
  bool get isNick => type == 'nick';
  bool get removed => isNick && name.isEmpty;

  Map<String, dynamic> toJson() => {
        't': type,
        if (isTheme) 'id': themeId,
        if (who.isNotEmpty) 'who': who,
        if (uid != null) 'uid': uid,
        if (isNick) 'n': name,
        'at': at,
      };

  static ChatControl? fromJson(Object? j) {
    if (j is! Map) return null;
    final t = '${j['t'] ?? ''}';
    final at = j['at'] is num ? (j['at'] as num).toInt() : int.tryParse('${j['at']}') ?? 0;
    if (t == 'theme') {
      final id = '${j['id'] ?? ''}';
      if (id.isEmpty || id.length > 24) return null;
      return ChatControl.theme(id, at: at);
    }
    if (t == 'nick') {
      final who = '${j['who'] ?? ''}';
      final uidRaw = j['uid'];
      final uid = uidRaw is num ? uidRaw.toInt() : int.tryParse('${uidRaw ?? ''}');
      if (who != 'sender' && who != 'recipient' && uid == null) return null;
      final n = '${j['n'] ?? ''}';
      return ChatControl.nick(
          who: who, uid: uid, name: n.length > 60 ? n.substring(0, 60) : n, at: at);
    }
    return null; // a newer control this build doesn't know: plain text
  }
}

/// The plaintext to encrypt for [c] ([fallback] = one readable line).
String encodeControl(ChatControl c, String fallback) {
  final line = fallback.replaceAll('\n', ' ').trim();
  final body = base64Url.encode(utf8.encode(jsonEncode(c.toJson())));
  return '$line\n$kControlMarker$body';
}

bool isControlText(String plaintext) => plaintext.contains(kControlMarker);

/// The control inside a decrypted TEXT message, or null.
ChatControl? decodeControl(String plaintext) {
  final i = plaintext.indexOf(kControlMarker);
  if (i < 0) return null;
  try {
    final raw = plaintext.substring(i + kControlMarker.length).trim();
    return ChatControl.fromJson(
        jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(raw)))));
  } catch (_) {
    return null;
  }
}

/// The readable part of a control text (marker + payload removed).
String controlFallback(String plaintext) {
  final i = plaintext.indexOf(kControlMarker);
  if (i < 0) return plaintext;
  return plaintext.substring(0, i).trim();
}

/// A custom-photo theme rides in a photo descriptor: `{"md1":1, ...,
/// "cc1": {"t":"theme","id":"custom","at":..}}`. Returns the control or null.
ChatControl? controlInDescriptor(String descriptorJson) {
  if (!descriptorJson.startsWith('{') || !descriptorJson.contains('"cc1"')) {
    return null;
  }
  try {
    final j = jsonDecode(descriptorJson);
    if (j is! Map) return null;
    final c = ChatControl.fromJson(j['cc1']);
    return (c != null && c.isTheme) ? c : null;
  } catch (_) {
    return null;
  }
}

/// Add the control block to a photo descriptor's JSON.
String withControl(String descriptorJson, ChatControl c) {
  final j = jsonDecode(descriptorJson) as Map<String, dynamic>;
  j['cc1'] = c.toJson();
  return jsonEncode(j);
}
