import 'dart:math';

import 'package:flutter/material.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'ladder_common.dart' show fmtInt;

/// aibar (2 Nov, launch group 6) — per-turn honesty shared by the Assisto AI
/// chat and the home chat thread:
///
///  * [AiCreditLine] — under every keyed-AI answer: the credits ACTUALLY
///    taken for it (server `meta.credits`, the router's real charge) and the
///    balance after, or "free quick answer" / "free". Never shown on a crisis
///    reply (safety is never about money) or on a local notice.
///  * [FailedSendRow] — a message that did not go out stays in its bubble
///    with the honest reason (no internet / our server / too fast) and a
///    48dp "Send again" button. A resend carries the SAME [newChatClientId],
///    so the server answers / charges / logs it once even if the first try
///    did reach it.
String newChatClientId() {
  final r = Random.secure();
  final b = StringBuffer('c');
  for (var i = 0; i < 12; i++) {
    b.write(r.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  b.write('-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}');
  return b.toString();
}

/// The server is still answering an earlier try of this client_id (409).
bool isTurnInProgress(Object? e) =>
    e is ApiException && e.status == 409 && e.reason == 'in_progress';

/// Too many messages too fast (429) — the server's own bn/en sentence.
bool isRateLimited(Object? e) => e is ApiException && e.status == 429;

/// The honest one-line reason a message was not sent.
String notSentText(AppLocalizations t, Object? e) {
  if (e is ApiException) {
    final s = e.status ?? 0;
    if (s == 429 && e.message.trim().isNotEmpty) return e.message;
    if (s >= 500) return t.aibarNotSentServer;
    if (s >= 400) return t.aibarNotSent;
    return t.aibarNotSentOffline;
  }
  return t.aibarNotSentOffline; // socket / timeout: no answer reached us
}

class AiCreditLine extends StatelessWidget {
  const AiCreditLine(this.meta, {super.key});
  final Map<String, dynamic> meta;

  /// Only real keyed-AI answers carry a credit line.
  static bool shows(Map<String, dynamic>? meta) =>
      meta != null && meta['source'] == 'ai';

  static int? _int(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');

  static String label(BuildContext context, Map<String, dynamic> meta) {
    final t = AppLocalizations.of(context);
    final n = _int(meta['credits']) ?? 0;
    final bal = _int(meta['balance']);
    String head;
    if (n > 0) {
      head = t.aibarCreditsUsed(fmtInt(context, n));
    } else if (meta['free_quota'] == true) {
      head = t.aibarFreeQuick;
    } else {
      head = t.aibarFreeAnswer;
    }
    return bal == null ? head : '$head · ${t.aibarCreditsLeft(fmtInt(context, bal))}';
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final style = AType.labelSmall.copyWith(color: scheme.onSurfaceVariant);
    return Padding(
      key: const ValueKey('aibar_credit_line'),
      padding: const EdgeInsets.only(top: Gap.xs, left: Gap.xs),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.toll_rounded, size: 14, color: scheme.onSurfaceVariant),
          const SizedBox(width: Gap.xs),
          Flexible(child: Text(label(context, meta), style: style)),
        ]),
        if (meta['text_cut'] == true)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(t.aibarTextCut, style: style),
          ),
        // aileft: a stopped answer is billed only for the part shown
        if (meta['stopped'] == true)
          Padding(
            key: const ValueKey('aileft_stopped_line'),
            padding: const EdgeInsets.only(top: 2),
            child: Text(t.aileftStoppedPaid, style: style),
          ),
      ]),
    );
  }
}

class FailedSendRow extends StatelessWidget {
  const FailedSendRow({super.key, required this.cause, required this.onRetry});
  final Object? cause;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      key: const ValueKey('aibar_failed_row'),
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: Gap.xs),
          // the reason is its own plain Text (TalkBack + finders read it
          // whole); the icon sits beside it
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.error_outline_rounded, size: 15, color: scheme.error),
            const SizedBox(width: Gap.xs),
            Flexible(
              child: Text(notSentText(t, cause),
                  textAlign: TextAlign.end,
                  style: AType.labelSmall.copyWith(color: scheme.error)),
            ),
          ]),
        ),
        TextButton.icon(
          key: const ValueKey('aibar_send_again'),
          onPressed: onRetry,
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: Text(t.aibarSendAgain),
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
        ),
      ],
    );
  }
}
