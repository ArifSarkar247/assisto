import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../push/push_payload.dart';
import '../theme.dart';

/// call-reply — WhatsApp-style "Reply with message" on an incoming call.
///
/// LOW-RISK design: Reply = the SAME decline as the Decline button (the
/// caller sees declined / missed exactly as before) + open that person's My
/// Circle chat with [CallQuickReplySheet]. A chosen preset is put in the
/// composer and sent through the chat's NORMAL E2E send path — nothing is
/// sent from the background or an isolate, no new crypto.
///
/// Native ring (IncomingCall.kt): the Reply action is an activity
/// PendingIntent using flutter_local_notifications' launch contract with
/// actionId [action]; MainActivity declines natively (crash-guarded), then
/// the existing Dart routing ([PushService]) lands here.
class CallReply {
  CallReply._();

  /// Notification action id (Kotlin IncomingCall.ACTION_REPLY — keep equal).
  static const action = 'call_reply';

  /// Reply is offered only for a 1:1 My Circle ring with a known chat (the
  /// member id). Group calls never ring through this path, but a payload that
  /// carries a group marker hides Reply (simplest consistent rule; the same
  /// check is mirrored natively).
  static bool canReply(PushPayload p) => p.isCall && memberId(p) != null;

  /// The My Circle member (edge) id the reply goes to, or null.
  static int? memberId(PushPayload p) {
    if (isGroup(p)) return null;
    final id = int.tryParse(p.chatId);
    return (id == null || id <= 0) ? null : id;
  }

  static bool isGroup(PushPayload p) {
    final d = p.data;
    final ck = (d['chat_kind'] ?? '').trim();
    final gid = (d['group_id'] ?? '').trim();
    return ck == 'group' || gid.isNotEmpty;
  }

  /// The four presets in the current language (ARB strings, not editable).
  static List<String> presets(AppLocalizations t) => [
        t.callReplyPreset1,
        t.callReplyPreset2,
        t.callReplyPreset3,
        t.callReplyPreset4,
      ];
}

/// The sheet's answer: a preset text, or "write your own" (focus the box).
class CallReplyChoice {
  const CallReplyChoice.preset(this.text) : writeOwn = false;
  const CallReplyChoice.writeOwn()
      : text = '',
        writeOwn = true;
  final String text;
  final bool writeOwn;
}

/// Bottom sheet with the 4 presets + "Write your own…". Pops a
/// [CallReplyChoice] (null = dismissed).
class CallQuickReplySheet extends StatelessWidget {
  const CallQuickReplySheet({super.key, required this.name});

  final String name;

  static Future<CallReplyChoice?> show(BuildContext context, String name) =>
      showModalBottomSheet<CallReplyChoice>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (_) => CallQuickReplySheet(name: name),
      );

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        child: Column(
          key: const Key('call-reply-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(t.callReplySheetTitle, style: tt.titleMedium),
            const SizedBox(height: Gap.xs),
            Text(t.callReplySheetSubtitle(name),
                style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
            const SizedBox(height: Gap.sm),
            for (final (i, s) in CallReply.presets(t).indexed)
              ListTile(
                key: Key('call-reply-preset-$i'),
                minVerticalPadding: Gap.md,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.chat_bubble_outline_rounded,
                    color: cs.primary),
                title: Text(s, style: tt.bodyLarge),
                onTap: () =>
                    Navigator.of(context).pop(CallReplyChoice.preset(s)),
              ),
            const Divider(),
            ListTile(
              key: const Key('call-reply-own'),
              minVerticalPadding: Gap.md,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.edit_rounded, color: cs.primary),
              title: Text(t.callReplyWriteOwn,
                  style: tt.bodyLarge?.copyWith(color: cs.primary)),
              onTap: () =>
                  Navigator.of(context).pop(const CallReplyChoice.writeOwn()),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows the sheet and applies the choice through the chat's own composer:
/// a preset fills [input] and calls [send] (the chat's normal send);
/// "write your own" calls [focus]. Shared by the chat screen and tests.
Future<void> runCallQuickReply(
  BuildContext context, {
  required String name,
  required TextEditingController input,
  required Future<void> Function() send,
  required VoidCallback focus,
}) async {
  final c = await CallQuickReplySheet.show(context, name);
  if (c == null) return;
  if (c.writeOwn) {
    focus();
    return;
  }
  input.text = c.text;
  input.selection = TextSelection.collapsed(offset: c.text.length);
  await send();
}
