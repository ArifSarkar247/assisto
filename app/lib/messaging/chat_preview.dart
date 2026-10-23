import 'dart:convert';
import 'dart:typed_data';

import '../crypto/e2e.dart';
import 'media/media_descriptor.dart';
import 'msg_ticks.dart';
import '../p3/assisto_card.dart' show cardFallback;

/// md2: the decrypted detail a media preview shows after its icon + label:
/// a photo's caption, a document's file name ('' = just the label).
String mediaPreviewDetail(String contentType, String plaintext) {
  final d = MediaDescriptor.tryParse(plaintext);
  if (d == null) return '';
  final v = switch (contentType) {
    'photo' || 'image' => d.caption,
    'document' => d.name,
    _ => '',
  };
  return v.replaceAll('\n', ' ').trim();
}

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
  ///
  /// a1-circle ROOT CAUSE of "Encrypted message" (owner, build 202): the row
  /// was decrypted ONLY with the peer's CURRENT key; after the peer
  /// reinstalled (new key) the last message — sent under the OLD key —
  /// failed. Now every key this phone knows for the peer is tried: the
  /// current one, the server's `last.peer_key_history`, and [extraPeerKeys]
  /// (this phone's PeerKeyBook history). Only when all fail, [cachedText]
  /// (the plaintext this phone already showed for that message id) is used;
  /// only then the honest lock label.
  static ChatPreview fromRow(Map<String, dynamic> row,
      {required IdentityKeyPair? identity,
      E2E? e2e,
      List<Uint8List> extraPeerKeys = const [],
      String? cachedText}) {
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
    final isMedia = ct != 'text';
    final self = identity;
    final keys = candidateKeys(row, extraPeerKeys);
    final cipher = '${last['ciphertext'] ?? ''}';
    String? pt;
    if (self != null && keys.isNotEmpty && cipher.isNotEmpty) {
      final engine = e2e ?? SoftwareE2E();
      final ctx = Ciphertext(
        scheme: '${last['scheme'] ?? engine.scheme}',
        ciphertextB64: cipher,
        nonceB64: '${last['nonce'] ?? ''}',
        senderKeyId: '${last['sender_key_id'] ?? ''}',
      );
      for (final k in keys) {
        try {
          pt = engine.decrypt(self: self, senderPublicKey: k, ct: ctx);
        } catch (_) {
          pt = null;
        }
        if (pt != null) break;
      }
    }
    if (isMedia) {
      // md2: a photo's caption / a document's NAME (decrypted here - the
      // server never has it); the label + icon otherwise. Never the
      // descriptor itself (it carries the file key).
      return of(PreviewKind.media, pt == null ? '' : mediaPreviewDetail(ct, pt));
    }
    if (pt == null) {
      final c = (cachedText ?? '').trim();
      return c.isNotEmpty ? of(PreviewKind.text, c) : of(PreviewKind.encrypted);
    }
    // p3: an Assisto card previews as its readable first line
    return of(PreviewKind.text, cardFallback(pt).replaceAll('\n', ' ').trim());
  }

  /// Every public key this phone knows for the row's peer, current first,
  /// de-duplicated: last.peer_public_key, member.public_key, the server's
  /// last.peer_key_history, then [extra] (local PeerKeyBook history).
  static List<Uint8List> candidateKeys(
      Map<String, dynamic> row, List<Uint8List> extra) {
    final last = (row['last'] as Map?) ?? const {};
    final member = (row['member'] as Map?) ?? const {};
    final seen = <String>{};
    final out = <Uint8List>[];
    void add(Uint8List? k) {
      if (k == null || k.isEmpty) return;
      if (seen.add(base64Encode(k))) out.add(k);
    }

    add(_b64('${last['peer_public_key'] ?? ''}'));
    add(_b64('${member['public_key'] ?? ''}'));
    final hist = last['peer_key_history'];
    if (hist is List) {
      for (final h in hist) {
        if (h is Map) add(_b64('${h['public_key'] ?? ''}'));
      }
    }
    for (final k in extra) {
      add(k);
    }
    return out;
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
