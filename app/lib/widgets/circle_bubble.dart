import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'circle_message_actions.dart';
import '../messaging/msg_ticks.dart';
import '../messaging/media/media_bubble.dart';
import '../messaging/media/media_descriptor.dart';
import '../messaging/media/media_outbox.dart';
import '../messaging/view_once.dart';
import '../messaging/share/share_flow.dart' show shareBubbleBody; // mc-media2
import '../messaging/share/share_payload.dart' show decodeShare, kShareKinds;

/// One decrypted message in the circle chat. The plaintext here NEVER came from
/// the server — it was decrypted on-device (see crypto/e2e.dart). The server
/// only ever held the ciphertext.
class CircleMessage {
  final String id;
  final String text; // decrypted on-device; null/empty if decryption failed
  final bool mine;
  final DateTime at;
  final String status; // sent | delivered | read (sender view)
  final bool decryptFailed;

  // M1 enrichments (all derived from decrypted / routing state).
  final String? replyToId; // routing id; preview resolved from local cache
  final String? replyPreview; // locally-resolved quoted text (never from server)
  final Map<String, int> reactions; // {emoji: count}
  final bool edited;
  final String deleted; // '' | 'me' | 'everyone'
  final bool forwarded;
  final int forwardHops;
  final bool starred;
  final bool pinned;
  final bool pending; // offline-queued, not yet relayed
  final String contentType; // text | photo | video | voice | document | contact | location
  final String? mediaCaption; // decrypted caption for a media bubble
  final bool mediaGated; // media kind not yet unlocked
  // md1: a decrypted E2E media descriptor (photo / voice / document), or a
  // send still on its way (progress ring + cancel).
  final MediaDescriptor? media;
  final MediaJob? mediaJob;

  /// e-gaps: a view-once photo; [viewOnceOpened] = the receiver opened it
  /// (server state or this phone's own record) — it can't be opened again.
  final bool viewOnce;
  final bool viewOnceOpened;

  const CircleMessage({
    required this.id,
    required this.text,
    required this.mine,
    required this.at,
    this.status = 'sent',
    this.decryptFailed = false,
    this.replyToId,
    this.replyPreview,
    this.reactions = const {},
    this.edited = false,
    this.deleted = '',
    this.forwarded = false,
    this.forwardHops = 0,
    this.starred = false,
    this.pinned = false,
    this.pending = false,
    this.contentType = 'text',
    this.mediaCaption,
    this.mediaGated = false,
    this.media,
    this.mediaJob,
    this.viewOnce = false,
    this.viewOnceOpened = false,
  });

  CircleMessage copyWith({
    String? status,
    Map<String, int>? reactions,
    bool? edited,
    String? deleted,
    bool? starred,
    bool? pinned,
    bool? pending,
    String? text,
    String? replyPreview,
    bool? viewOnceOpened,
  }) =>
      CircleMessage(
        id: id,
        text: text ?? this.text,
        mine: mine,
        at: at,
        status: status ?? this.status,
        decryptFailed: decryptFailed,
        replyToId: replyToId,
        replyPreview: replyPreview ?? this.replyPreview,
        reactions: reactions ?? this.reactions,
        edited: edited ?? this.edited,
        deleted: deleted ?? this.deleted,
        forwarded: forwarded,
        forwardHops: forwardHops,
        starred: starred ?? this.starred,
        pinned: pinned ?? this.pinned,
        pending: pending ?? this.pending,
        contentType: contentType,
        mediaCaption: mediaCaption,
        mediaGated: mediaGated,
        media: media,
        mediaJob: mediaJob,
        viewOnce: viewOnce,
        viewOnceOpened: viewOnceOpened ?? this.viewOnceOpened,
      );
}

/// wa-polish2: the bubble shape — the first bubble of a run has the "tail"
/// (a sharp top corner on the sender's side), the rest are fully rounded.
BorderRadius bubbleRadius({required bool mine, required bool continued}) {
  const round = Radius.circular(Radii.lg);
  const tail = Radius.zero; // a crisp corner reads as the tail
  return BorderRadius.only(
    topLeft: !mine && !continued ? tail : round,
    topRight: mine && !continued ? tail : round,
    bottomLeft: round,
    bottomRight: round,
  );
}

/// e2e-recover: the one grey line for a message this phone can't open yet.
String e2rWaitingText(AppLocalizations t, String name) =>
    name.trim().isEmpty ? t.e2rWaitingGeneric : t.e2rWaiting(name.trim());

class CircleBubble extends StatelessWidget {
  final CircleMessage msg;
  final VoidCallback? onLongPress;
  final VoidCallback? onTapMedia;

  /// md1: open a decrypted media file (photo viewer / document sheet).
  final void Function(File file, MediaDescriptor desc)? onOpenFile;

  /// c3-msg: tap the quoted reply → jump to + highlight the original.
  final VoidCallback? onTapReply;

  /// c3-msg: briefly tinted after a jump-to-original.
  final bool highlighted;

  /// e-gaps: open a received view-once photo (null = can't from here).
  final VoidCallback? onOpenViewOnce;

  /// e2e-recover: who to ask when this phone cannot open the message yet
  /// ('' = "the sender").
  final String waitingName;

  /// wa-polish: resend MY failed message (null = no retry line).
  final VoidCallback? onRetry;

  /// wa-polish2: this bubble continues a run of messages from the same
  /// sender (see messaging/bubble_grouping.dart) — tight spacing and no
  /// tail; only the run's first bubble has the tail.
  final bool continued;
  const CircleBubble(
      {super.key,
      required this.msg,
      this.continued = false,
      this.waitingName = '',
      this.onRetry,
      this.onLongPress,
      this.onTapMedia,
      this.onOpenFile,
      this.onTapReply,
      this.highlighted = false,
      this.onOpenViewOnce});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final mine = msg.mine;
    // x2-ticks: my bubble is a calm WhatsApp-like neutral green / teal so
    // grey ✓✓ and blue ✓✓ are unmistakable (MsgPalette, WCAG-checked).
    final bg = mine ? MsgPalette.outBubble(context) : scheme.surfaceContainerHighest;
    final fg = mine ? MsgPalette.outText(context) : scheme.onSurface;
    final deleted = msg.deleted == 'everyone';

    return AnimatedContainer(
      duration: const Duration(milliseconds: 350),
      color: highlighted
          ? scheme.primary.withValues(alpha: 0.18)
          : Colors.transparent,
      child: Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: deleted ? null : onLongPress,
        child: Container(
          // wa-polish2: a run's bubbles sit close together; a new run
          // (other sender / a few minutes later) gets air above it.
          margin: EdgeInsets.fromLTRB(
              Gap.sm, continued ? Gap.xxs / 2 : Gap.sm, Gap.sm, Gap.xxs / 2),
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
          child: Column(
            crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.md),
                decoration: BoxDecoration(
                  // qa2: a message this device can't read is not an error
                  // the user caused — normal bubble + lock line (WhatsApp),
                  // not a saturated red block.
                  color: bg,
                  // wa-polish2: WhatsApp's tail — the sharp top corner on
                  // the sender's side, on the FIRST bubble of a run only.
                  borderRadius: bubbleRadius(mine: mine, continued: continued),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (msg.forwarded && !deleted) _forwardedLabel(context, t, mine, scheme),
                    if (msg.replyPreview != null && !deleted) _replyPreview(context, mine, scheme),
                    if (!deleted && msg.contentType != 'text') _mediaBody(context, t, fg),
                    _bodyText(context, t, fg, deleted),
                    const SizedBox(height: Gap.xs),
                    _metaRow(context, mine, scheme),
                  ],
                ),
              ),
              if (msg.reactions.isNotEmpty && !deleted)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: CircleReactionChips(counts: msg.reactions, onTap: onLongPress),
                ),
              // wa-polish: WhatsApp's visible "not sent — tap to retry"
              // (was only reachable by a long-press nobody discovers).
              if (mine && msg.status == 'failed' && !deleted && onRetry != null)
                _retryLine(context, t, scheme),
            ],
          ),
        ),
      ),
      ),
    );
  }

  Widget _retryLine(BuildContext context, AppLocalizations t, ColorScheme scheme) =>
      Semantics(
        button: true,
        child: InkWell(
          key: ValueKey('wa-retry-${msg.id}'),
          borderRadius: BorderRadius.circular(Radii.sm),
          onTap: onRetry,
          child: ConstrainedBox(
            constraints:
                const BoxConstraints(minHeight: kMinInteractiveDimension),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.xs),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.error_rounded, size: 18, color: scheme.error),
                const SizedBox(width: Gap.xs),
                Flexible(
                  child: Text(t.waNotSentRetry,
                      style: AType.labelMedium.copyWith(
                          color: scheme.error, fontWeight: FontWeight.w600)),
                ),
              ]),
            ),
          ),
        ),
      );

  Widget _bodyText(BuildContext context, AppLocalizations t, Color fg, bool deleted) {
    final show = deleted
        ? t.circleDeletedPlaceholder
        : msg.decryptFailed
            // e2e-recover: never a raw error — the other phone re-shares it
            // (resend request) once it opens Assisto.
            ? e2rWaitingText(t, waitingName)
            : msg.text;
    if (show.isEmpty && msg.contentType != 'text') return const SizedBox.shrink();
    // mc-media2: a location / contact card draws itself (no raw text)
    if (!deleted && !msg.decryptFailed && kShareKinds.contains(msg.contentType) &&
        decodeShare(msg.text) != null) {
      return const SizedBox.shrink();
    }
    if (msg.decryptFailed && !deleted) {
      final muted = Theme.of(context).colorScheme.onSurfaceVariant;
      return Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.lock_outline_rounded, size: 16, color: muted),
        const SizedBox(width: Gap.xs),
        Flexible(
          child: Text(show,
              style: TextStyle(
                  color: muted, fontStyle: FontStyle.italic, height: 1.4)),
        ),
      ]);
    }
    return Text(
      show,
      style: TextStyle(
        color: (msg.decryptFailed || deleted)
            ? Theme.of(context).colorScheme.onSurfaceVariant
            : fg,
        fontStyle: (msg.decryptFailed || deleted) ? FontStyle.italic : FontStyle.normal,
        height: 1.4,
      ),
    );
  }

  Widget _mediaBody(BuildContext context, AppLocalizations t, Color fg) {
    // mc-media2: location / live location / contact card
    final share = msg.decryptFailed
        ? null
        : shareBubbleBody(msg.contentType, msg.text,
            mine: msg.mine, fg: fg, messageId: msg.pending ? null : msg.id);
    if (share != null) {
      return Padding(padding: const EdgeInsets.only(bottom: Gap.xs), child: share);
    }
    if (msg.viewOnce && msg.mediaJob == null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: Gap.xs),
        child: ViewOnceTile(
          key: ValueKey('e-vo-${msg.id}'),
          mine: msg.mine,
          opened: msg.viewOnceOpened,
          fg: fg,
          onOpen: (msg.mine || msg.viewOnceOpened || msg.media == null)
              ? null
              : onOpenViewOnce,
        ),
      );
    }
    if (msg.media != null || msg.mediaJob != null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: Gap.xs),
        child: MediaBubbleBody(
          key: ValueKey('md1-${msg.media?.ref ?? msg.mediaJob?.id}'),
          desc: msg.media,
          job: msg.mediaJob,
          mine: msg.mine,
          fg: fg,
          onOpen: onOpenFile,
        ),
      );
    }
    final icon = {
      'photo': Icons.photo_rounded,
      'video': Icons.videocam_rounded,
      'voice': Icons.mic_none_rounded,
      'document': Icons.insert_drive_file_rounded,
      'contact': Icons.contact_page_rounded,
      'location': Icons.location_on_rounded,
    }[msg.contentType] ?? Icons.attachment_rounded;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.xs),
      child: InkWell(
        onTap: msg.mediaGated ? null : onTapMedia,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: fg),
            const SizedBox(width: Gap.sm),
            Flexible(
              child: Text(
                // mr1: an honest label, never "available when storage is
                // enabled" (not tappable while gated).
                msg.mediaGated
                    ? '${_mediaLabel(t)} · ${t.mr1MediaNotShown}'
                    : _mediaLabel(t),
                style: TextStyle(color: fg, fontSize: 13),
              ),
            ),
            if (msg.mediaGated) ...[
              const SizedBox(width: Gap.xs),
              Icon(Icons.lock_clock_rounded, size: 14, color: fg),
            ],
          ],
        ),
      ),
    );
  }

  String _mediaLabel(AppLocalizations t) {
    if ((msg.mediaCaption ?? '').isNotEmpty) return msg.mediaCaption!;
    switch (msg.contentType) {
      case 'photo':
        return t.circlePhoto;
      case 'video':
        return t.circleVideo;
      case 'voice':
        return t.circleVoiceNote;
      case 'document':
        return t.circleAttachDocument;
      case 'contact':
        return t.circleAttachContact;
      case 'location':
        return t.circleAttachLocation;
      default:
        return t.circleAttach;
    }
  }

  Widget _forwardedLabel(
      BuildContext context, AppLocalizations t, bool mine, ColorScheme scheme) {
    final color = mine
        ? MsgPalette.outMeta(context)
        : scheme.onSurfaceVariant.withValues(alpha: 0.8);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.forward_rounded, size: 13, color: color),
          const SizedBox(width: Gap.xs),
          Text(
            msg.forwardHops >= 5 ? t.circleForwardedMany : t.circleForwarded,
            style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic, color: color),
          ),
        ],
      ),
    );
  }

  Widget _replyPreview(BuildContext context, bool mine, ColorScheme scheme) {
    final stripe = mine ? MsgPalette.outMeta(context) : scheme.primary;
    final txt = (mine ? MsgPalette.outText(context) : scheme.onSurface)
        .withValues(alpha: 0.85);
    return GestureDetector(
      key: ValueKey('c3-quote-${msg.id}'),
      onTap: onTapReply,
      child: Container(
      margin: const EdgeInsets.only(bottom: Gap.xs),
      padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.xs, Gap.sm, Gap.xs),
      decoration: BoxDecoration(
        color: (mine ? MsgPalette.outText(context) : scheme.primary)
            .withValues(alpha: mine ? 0.07 : 0.12),
        border: Border(left: BorderSide(color: stripe, width: 3)),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Text(
        msg.replyPreview!,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: txt),
      ),
    ),
    );
  }

  Widget _metaRow(BuildContext context, bool mine, ColorScheme scheme) {
    final t = AppLocalizations.of(context);
    final metaColor = mine
        ? MsgPalette.outMeta(context)
        : scheme.onSurfaceVariant.withValues(alpha: 0.8);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (msg.pinned) ...[
          Icon(Icons.push_pin_rounded, size: 12, color: metaColor),
          const SizedBox(width: 3),
        ],
        if (msg.starred) ...[
          Icon(Icons.star_rounded, size: 12, color: metaColor),
          const SizedBox(width: 3),
        ],
        if (msg.edited) ...[
          Text(t.circleEdited, style: TextStyle(fontSize: 10, color: metaColor)),
          const SizedBox(width: 4),
        ],
        Text(DateFormat.Hm(Localizations.localeOf(context).languageCode).format(msg.at),
            style: TextStyle(fontSize: 11, color: metaColor)),
        if (mine) ...[
          const SizedBox(width: Gap.xs),
          // c3-msg: ✓ sent → ✓✓ delivered → blue ✓✓ read.
          TickIcon(
            tick: tickFrom(msg.status, pending: msg.pending),
            baseColor: metaColor,
            onMyBubble: true,
          ),
        ],
      ],
    );
  }
}

/// The small reassurance banner shown at the top of every circle chat: messages
/// are end-to-end encrypted; the server (and its AI) cannot read them.
class CircleEncryptionBanner extends StatelessWidget {
  const CircleEncryptionBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.all(Gap.sm),
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(
        children: [
          Icon(Icons.lock_outline_rounded, size: 16, color: scheme.onSecondaryContainer),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(
              t.circleE2eBanner,
              style: TextStyle(fontSize: 12, color: scheme.onSecondaryContainer, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }
}

/// The reply/edit composer banner shown above the input when the user is
/// replying to or editing a message.
class CircleComposerContext extends StatelessWidget {
  final String preview;
  final bool isEdit;
  final VoidCallback onCancel;
  const CircleComposerContext({
    super.key,
    required this.preview,
    required this.onCancel,
    this.isEdit = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.sm, Gap.sm),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        border: Border(left: BorderSide(color: scheme.primary, width: 3)),
      ),
      child: Row(
        children: [
          Icon(isEdit ? Icons.edit_rounded : Icons.reply_rounded,
              size: 16, color: scheme.primary),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(isEdit ? t.circleEditing : t.circleReplyingTo,
                    style: TextStyle(fontSize: 11, color: scheme.primary, fontWeight: FontWeight.w600)),
                Text(preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 18),
            onPressed: onCancel,
          ),
        ],
      ),
    );
  }
}
