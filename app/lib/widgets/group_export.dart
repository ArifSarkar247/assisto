/// GROUP EXPORT — the device half of `GET /circle/groups/<id>/export`.
///
/// The server builds a JSON file of what it legitimately holds (group name,
/// members, and per message: time, sender, type and the caller's OWN
/// ciphertext envelope) and hands back a SIGNED, expiring link. This file
/// turns that JSON into the readable .txt the user shares: every body is
/// decrypted HERE with the caller's key — plaintext never goes back to the
/// server. Pure + injectable so it is unit-tested without crypto or network.
library;

/// Labels the caller passes from AppLocalizations (no copy lives here).
class GroupExportLabels {
  final String header; // e.g. "Exported from Assisto"
  final String unreadable; // body we could not decrypt on this device
  final String deleted; // "This message was deleted"
  final String media; // non-text item placeholder
  final String you; // the caller's own name in the transcript
  const GroupExportLabels({
    required this.header,
    required this.unreadable,
    required this.deleted,
    required this.media,
    required this.you,
  });
}

/// Decrypts one envelope `{ciphertext, nonce, peer_member_id?}` sent by
/// [senderId] (a User id); returns null when it cannot.
typedef ExportDecrypt = String? Function(
    Map<String, dynamic> envelope, int senderId, String senderKeyId);

String _two(int n) => n.toString().padLeft(2, '0');

String _stamp(String iso) {
  final d = DateTime.tryParse(iso)?.toLocal();
  if (d == null) return iso;
  return '${d.year}-${_two(d.month)}-${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}';
}

/// Build the shareable transcript. [myUserId] marks the caller's own rows.
String buildGroupExportText(
  Map<String, dynamic> export, {
  required ExportDecrypt decrypt,
  required GroupExportLabels labels,
  required int myUserId,
}) {
  final group = (export['group'] as Map?)?.cast<String, dynamic>() ?? const {};
  final out = StringBuffer()
    ..writeln('${group['name'] ?? ''}')
    ..writeln('${labels.header} · ${_stamp('${export['exported_at'] ?? ''}')}')
    ..writeln();
  for (final raw in (export['messages'] as List? ?? const [])) {
    if (raw is! Map) continue;
    final m = raw.cast<String, dynamic>();
    final sid = (m['sender_id'] as num?)?.toInt() ?? 0;
    final who = sid == myUserId ? labels.you : '${m['sender_name'] ?? ''}';
    String body;
    if (m['deleted'] == true) {
      body = labels.deleted;
    } else if ('${m['type'] ?? 'text'}' != 'text') {
      body = labels.media;
    } else {
      final env = (m['envelope'] as Map?)?.cast<String, dynamic>();
      body = (env == null
              ? null
              : decrypt(env, sid, '${m['sender_key_id'] ?? ''}')) ??
          labels.unreadable;
    }
    out.writeln('[${_stamp('${m['at'] ?? ''}')}] $who: $body');
  }
  return out.toString();
}

/// A safe file name for the share sheet.
String exportFileName(String groupName) {
  final cleaned = groupName
      .replaceAll(RegExp(r'[\\/:*?"<>|\n\r\t]'), ' ')
      .trim();
  return '${cleaned.isEmpty ? 'group' : cleaned}.txt';
}
