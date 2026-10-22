/// NO SHOWPIECES (round 2 item 4) — what My Circle media REALLY works.
///
/// md1 built end-to-end-encrypted media for 1:1 and group CHATS (photo,
/// voice note, document: encrypted on the phone, ciphertext-only blob
/// storage, signed downloads, retention). Only those kinds are switched on
/// ([kCircleChatMediaKinds]); the chat's attach sheet lists exactly them.
///
/// Still hidden (each needs its own real build first):
///   * video — no reliable on-phone encoder / player without a heavy native
///     dependency (see .phaseB/proposals/md1.md),
///   * contact card, live location, static location in chats,
///   * STATUS photo/video and the camera's "send to chats / post as status":
///     [kCircleMediaStorageOn] stays false for those (status media has its
///     own blob path, core/logic/circle.MEDIA_UNLOCKED stays off for it).
bool get kCircleMediaStorageOn => false;

/// md1: chat media kinds that work end to end (server: circle_blobs.CHAT_MEDIA_KINDS).
const Set<String> kCircleChatMediaKinds = {'photo', 'voice', 'document'};
