import 'dart:convert';
import 'dart:typed_data';

import '../crypto/e2e.dart';
import 'msg_ticks.dart';

/// What the chat-list row shows under the name.
enum PreviewKind {
  /// Decrypted text in [ChatPreview.text].
  text,

  /// A media message (photo/voice/…) — label from [ChatPreview.contentType].
  media,

  /// "This message was deleted".
  deleted,

  /// A message exists but this phone can't decrypt it (key changed / missing):
  /// a lock label — NEVER "No messages yet".
  encrypted,

  /// The chat really has no messages.
  empty,
}

/// c3-msg — the chat-list preview, built ON THE DEVICE from the row's `last`
/// ciphertext envelope.
///
/// ROOT CAUSE of the owner's "No messages yet" bug: GET /circle/chats always
/// sends `last_text: ""` (E2E: the server has no plaintext) and the list
/// rendered `last_text`, so every chat looked empty. The row also carries
/// `last` (ciphertext + nonce + key hint); we decrypt THAT here. ECDH is
/// symmetric, so my own last message decrypts with the peer's key too.
class ChatPreview {
  final PreviewKind kind;
  final String text;
  final bool mine;
  final String senderName;
  final String contentType;
  final MsgTick? tick;
  final DateTime? at;
  final bool isGroup;

  const ChatPreview({
    required this.kind,
    this.text = '',
    this.mine = false,
    this.senderName = '',
    this.contentType = 'text',
    this.tick,
    this.at,
    this.isGroup = false,
  });

  static Uint8List? _b64(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      return Uint8List.fromList(base64Decode(s));
    } catch (_) {
      return null;
    }
  }

  /// Build from one /circle/chats row. [identity] null = keys not loaded yet
  /// (still not "empty": a message exists → encrypted label).
  static ChatPreview fromRow(Map<String, dynamic> row,
      {required IdentityKeyPair? identity, E2E? e2e}) {
    final isGroup = row['is_group'] == true || row['kind'] == 'group';
    final last = (row['last'] as Map?)?.cast<String, dynamic>();
    final at = DateTime.tryParse('${row['at'] ?? last?['created_at'] ?? ''}')
        ?.toLocal();
    if (last == null) {
      // Legacy server text (never set by the E2E relay) still wins if present.
      final legacy = '${row['last_text'] ?? ''}'.trim();
      if (legacy.isNotEmpty) {
        return ChatPreview(
            kind: PreviewKind.text, text: legacy, at: at, isGroup: isGroup);
      }
      return ChatPreview(kind: PreviewKind.empty, isGroup: isGroup);
    }
    final mine = last['mine'] == true;
    final sender = '${last['sender_name'] ?? ''}';
    final ct = '${last['content_type'] ?? 'text'}';
    final tick = mine ? tickFrom('${last['status'] ?? 'sent'}') : null;
    ChatPreview of(PreviewKind k, [String text = '']) => ChatPreview(
        kind: k,
        text: text,
        mine: mine,
        senderName: sender,
        contentType: ct,
        tick: tick,
        at: at,
        isGroup: isGroup);

    final deleted = '${last['deleted'] ?? ''}';
    if (deleted == 'everyone') return of(PreviewKind.deleted);
    if (ct != 'text') return of(PreviewKind.media);
    final self = identity;
    final peer = _b64('${last['peer_public_key'] ?? ''}') ??
        _b64('${((row['member'] as Map?) ?? const {})['public_key'] ?? ''}');
    final cipher = '${last['ciphertext'] ?? ''}';
    if (self == null || peer == null || cipher.isEmpty) {
      return of(PreviewKind.encrypted);
    }
    final engine = e2e ?? SoftwareE2E();
    final pt = engine.decrypt(
      self: self,
      senderPublicKey: peer,
      ct: Ciphertext(
        scheme: '${last['scheme'] ?? engine.scheme}',
        ciphertextB64: cipher,
        nonceB64: '${last['nonce'] ?? ''}',
        senderKeyId: '${last['sender_key_id'] ?? ''}',
      ),
    );
    if (pt == null) return of(PreviewKind.encrypted);
    return of(PreviewKind.text, pt.replaceAll('\n', ' ').trim());
  }

  /// Unread count for the row: the server count, or 1 for a manual
  /// "Mark as unread" (shown as a dot-badge), 0 once opened locally.
  static int unreadOf(Map<String, dynamic> row) {
    final n = (row['unread'] is int)
        ? row['unread'] as int
        : int.tryParse('${row['unread'] ?? 0}') ?? 0;
    if (n > 0) return n;
    return row['marked_unread'] == true ? 1 : 0;
  }
}
