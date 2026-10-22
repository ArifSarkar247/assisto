import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../crypto/e2e.dart';
import '../crypto/identity_vault.dart';
import '../l10n/app_localizations.dart';
import '../screens/circle_chat_screen.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/loading_gate.dart';
import '../widgets/msgr_avatar.dart';
import '../widgets/msgr_hub_chat_list.dart' show chatListTime, mediaPreviewLabel;
import 'chat_preview.dart';

/// mr1 — My Circle MESSAGE REQUESTS (WhatsApp-like).
///
///   * anyone found by phone can be messaged at once:
///     POST /circle/message-request/start {phone | to_user_id} -> the chat;
///   * the RECIPIENT sees a "Message requests" section at the top of the
///     chat list ([MsgRequestRow]); opening one shows the conversation
///     read-only with Accept / Block / Report / Delete ([MsgRequestActionBar]);
///   * the SENDER sees the chat normally with a small neutral line
///     ([MsgRequestWaitingLine]) and, after the pre-accept limit, a note
///     instead of the composer ([MsgRequestLimitNote]);
///   * calls appear only once accepted (no dead buttons before).
/// Keys stay invisible: the chat screen's normal outbox / key_request path
/// sends a message the moment the peer key exists.

extension MsgRequestApi on ApiClient {
  Future<Map<String, dynamic>> startMessageRequest({int? toUserId, String? phone}) =>
      loadGuard(postJson('/circle/message-request/start', {
        if (toUserId != null) 'to_user_id': toUserId,
        if (toUserId == null && phone != null) 'phone': phone,
      }));
}

/// A server refusal sentence (bilingual `detail`) as-is; else a plain line.
String msgRequestErrorText(AppLocalizations t, Object e) {
  if (e is ApiException) {
    final m = e.message.trim();
    if (m.contains(' ') && !m.startsWith('{')) return m;
    if ((e.status ?? 0) == 429) return t.c1SearchLimited;
  }
  if (e is TimeoutException) return t.m3ErrTimeout;
  return t.mr1StartFailed;
}

/// Open the 1:1 chat with [toUserId] (or the number [phone]) — a normal chat
/// when already connected, a message request otherwise. Failures say why.
Future<bool> openMessageRequestChat(BuildContext context,
    {int? toUserId, String? phone}) async {
  final t = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final nav = Navigator.of(context);
  final api = context.read<AppState>().api;
  try {
    final r = await api.startMessageRequest(toUserId: toUserId, phone: phone);
    final m = (r['member'] as Map?)?.cast<String, dynamic>();
    if (m == null || m['id'] == null) throw ApiException('', 500);
    final id = await IdentityVault.instance.get();
    await nav.push(MaterialPageRoute(
        builder: (_) => CircleChatScreen(member: m, identity: id)));
    return true;
  } catch (e) {
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(SnackBar(content: Text(msgRequestErrorText(t, e))));
    return false;
  }
}

// ---------------------------------------------------------------------------
// Sender side
// ---------------------------------------------------------------------------
class MsgRequestWaitingLine extends StatelessWidget {
  const MsgRequestWaitingLine({super.key, required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final who = name.trim().isEmpty ? t.circleSomeone : name.trim();
    return Padding(
      key: const Key('mr1-waiting'),
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.xs, Gap.lg, 0),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.schedule, size: 14, color: scheme.onSurfaceVariant),
        const SizedBox(width: Gap.xs),
        Flexible(
          child: Text(t.mr1Waiting(who),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
        ),
      ]),
    );
  }
}

class MsgRequestLimitNote extends StatelessWidget {
  const MsgRequestLimitNote({super.key, required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final who = name.trim().isEmpty ? t.circleSomeone : name.trim();
    return SafeArea(
      top: false,
      child: Container(
        key: const Key('mr1-limit'),
        width: double.infinity,
        margin: const EdgeInsets.all(Gap.sm),
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        child: Text(t.mr1LimitNote(who),
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Recipient side — the read-only request conversation
// ---------------------------------------------------------------------------
class MsgRequestActionBar extends StatelessWidget {
  const MsgRequestActionBar({
    super.key,
    required this.name,
    this.phone = '',
    this.busy = false,
    required this.onAccept,
    required this.onBlock,
    required this.onReport,
    required this.onDelete,
  });

  final String name;
  final String phone;
  final bool busy;
  final VoidCallback onAccept;
  final VoidCallback onBlock;
  final VoidCallback onReport;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final who = name.trim().isEmpty ? t.circleSomeone : name.trim();
    Widget act(Key key, IconData icon, String label, VoidCallback onTap,
            {bool danger = false}) =>
        Expanded(
          child: TextButton.icon(
            key: key,
            onPressed: busy ? null : onTap,
            style: TextButton.styleFrom(
                foregroundColor: danger ? scheme.error : scheme.onSurface,
                padding: const EdgeInsets.symmetric(vertical: Gap.sm)),
            icon: Icon(icon, size: 20),
            label: Text(label,
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        );
    return Material(
      key: const Key('mr1-request-bar'),
      color: scheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.sm),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(t.mr1RequestFrom(who),
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            const SizedBox(height: 2),
            Text(phone.trim().isEmpty ? t.mr1NotInContacts : phone.trim(),
                key: const Key('mr1-request-phone'),
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
            const SizedBox(height: Gap.xs),
            Text(t.mr1RequestExplainer,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: scheme.onSurfaceVariant, fontSize: 12.5, height: 1.35)),
            const SizedBox(height: Gap.sm),
            Row(children: [
              act(const Key('mr1-block'), Icons.block, t.circleBlock, onBlock,
                  danger: true),
              act(const Key('mr1-report'), Icons.flag_outlined, t.circleReport,
                  onReport, danger: true),
              act(const Key('mr1-delete'), Icons.delete_outline, t.delete,
                  onDelete),
            ]),
            const SizedBox(height: Gap.xs),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const Key('mr1-accept'),
                onPressed: busy ? null : onAccept,
                icon: busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.check),
                label: Text(t.circleAccept),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Block / Report / Delete always confirm first (WhatsApp does too).
Future<bool?> showMsgRequestConfirm(
    BuildContext context, String action, String name) {
  final t = AppLocalizations.of(context);
  final who = name.trim().isEmpty ? t.circleSomeone : name.trim();
  final (title, body, label) = switch (action) {
    'block' => (t.mr1BlockTitle(who), t.mr1BlockBody, t.circleBlock),
    'report' => (t.mr1ReportTitle(who), t.mr1ReportBody, t.circleReport),
    _ => (t.mr1DeleteTitle, t.mr1DeleteBody(who), t.delete),
  };
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
        FilledButton(
            key: const Key('mr1-confirm'),
            style: action == 'delete'
                ? null
                : FilledButton.styleFrom(
                    backgroundColor: Theme.of(ctx).colorScheme.error,
                    foregroundColor: Theme.of(ctx).colorScheme.onError),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(label)),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// Recipient side — the row in the "Message requests" section
// ---------------------------------------------------------------------------

/// True when a /circle/requests row carries at least one message.
bool msgRequestHasMessages(Map<String, dynamic> r) =>
    r['last'] is Map || ((r['msg_count'] as num?)?.toInt() ?? 0) > 0;

/// The member payload to open a request conversation with (+ the number to
/// show, only when the sender allows it).
Map<String, dynamic> msgRequestMember(Map<String, dynamic> r) {
  final m = <String, dynamic>{
    ...((r['member'] as Map?)?.cast<String, dynamic>() ?? const {}),
  };
  m['id'] ??= r['id'];
  m['name'] ??= r['display_name'] ?? r['name'] ?? '';
  m['photo'] ??= r['photo'] ?? '';
  m['state'] ??= 'pending';
  m['direction'] ??= 'incoming';
  m['request_phone'] = '${r['phone'] ?? ''}';
  return m;
}

class MsgRequestRow extends StatelessWidget {
  const MsgRequestRow({
    super.key,
    required this.request,
    required this.identity,
    required this.onOpen,
  });

  final Map<String, dynamic> request;
  final IdentityKeyPair? identity;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final r = request;
    final name = '${r['display_name'] ?? r['name'] ?? ''}'.trim();
    final phone = '${r['phone'] ?? ''}'.trim();
    final pv = ChatPreview.fromRow(
        {'last': r['last'], 'member': r['member'], 'at': r['at']},
        identity: identity, e2e: SoftwareE2E());
    final String body = switch (pv.kind) {
      PreviewKind.text => pv.text,
      PreviewKind.media => mediaPreviewLabel(t, pv.contentType),
      PreviewKind.deleted => t.circleDeletedPlaceholder,
      PreviewKind.encrypted => t.c3PreviewEncrypted,
      PreviewKind.empty => t.m3WantsToAdd,
    };
    final at = pv.at;
    final lang = Localizations.localeOf(context).languageCode;
    return InkWell(
      key: Key('mr1-req-${r['id']}'),
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
        child: Row(children: [
          MsgrAvatar(
              name: name.isEmpty ? '?' : name,
              photoUrl: '${r['photo'] ?? ''}',
              photoV: '${r['photo_v'] ?? ''}',
              radius: 24),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Text(name.isEmpty ? t.circleSomeone : name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 16)),
                ),
                if (at != null)
                  Text(chatListTime(t, at, lang),
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              ]),
              Text(phone.isEmpty ? t.mr1NotInContacts : phone,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: scheme.primary)),
              Text(body,
                  key: const Key('mr1-req-preview'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
            ]),
          ),
        ]),
      ),
    );
  }
}
