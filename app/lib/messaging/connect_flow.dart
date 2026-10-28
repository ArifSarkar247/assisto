import 'package:flutter/material.dart';

import '../crypto/identity_vault.dart';
import '../l10n/app_localizations.dart';
import '../screens/circle_call_screen.dart';
import '../screens/circle_chat_screen.dart';
import '../theme.dart';
import '../widgets/msgr_avatar.dart';
import 'chat_decor/system_line.dart';
import 'package:assisto/widgets/app_sheet.dart';

/// connect-flow — My Circle CONNECT FLOW (owner order 25 Oct, QUEUE 0b).
///
///  * after a request the chat opens at once with the banner "Request sent —
///    they can reply after accepting" (msg_request_widgets.dart);
///  * before accept: up to 3 plain TEXT messages — no media, voice, calls or
///    links ([preAcceptHasLink]; the server refuses them too);
///  * on accept both phones draw "You are now connected" ([ConnectedLine],
///    at the server's `connected_at`) and the chat tops both lists;
///  * every My Circle contact / member / profile offers Message, Audio call
///    and Video call ([ConnectActions], [showConnectSheet]) — no searching.
/// Encryption stays invisible (the chat's normal key / outbox path).

/// Same rule as the server (core/connect_flow.py LINK_RE): http(s):// or www.
final RegExp kPreAcceptLink = RegExp(r'(https?://|www\.)', caseSensitive: false);

bool preAcceptHasLink(String text) => kPreAcceptLink.hasMatch(text);

/// The server's `connected_at` (member payload / message fetch `edge`).
DateTime? connectedAtOf(Object? m) {
  if (m is! Map) return null;
  final s = m['connected_at'];
  if (s == null) return null;
  return DateTime.tryParse('$s')?.toLocal();
}

/// The centred system line "You are now connected".
class ConnectedLine extends StatelessWidget {
  const ConnectedLine({super.key});

  @override
  Widget build(BuildContext context) => KeyedSubtree(
        key: const Key('conn-connected-line'),
        child: ChatSystemLine(
            text: AppLocalizations.of(context).connConnectedLine,
            icon: Icons.handshake_rounded),
      );
}

/// Message / Audio call / Video call — the three big actions on a contact.
/// Calls only for an ACCEPTED contact (free calls, existing server rules).
class ConnectActions extends StatelessWidget {
  const ConnectActions({
    super.key,
    required this.onMessage,
    this.onAudio,
    this.onVideo,
  });

  final VoidCallback? onMessage;
  final VoidCallback? onAudio;
  final VoidCallback? onVideo;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    Widget btn(Key key, IconData icon, String label, VoidCallback? onTap) =>
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.xs),
            child: OutlinedButton(
              key: key,
              onPressed: onTap,
              style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                      vertical: Gap.sm, horizontal: Gap.xs),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(Radii.md))),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, size: 24),
                const SizedBox(height: 4),
                Text(label,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    softWrap: true,
                    style: const TextStyle(fontSize: 13, height: 1.2)),
              ]),
            ),
          ),
        );
    return Row(
      key: const Key('conn-actions'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        btn(const Key('conn-message'), Icons.chat_bubble_outline_rounded, t.c1Message,
            onMessage),
        if (onAudio != null)
          btn(const Key('conn-audio'), Icons.call_rounded, t.connAudioCall,
              onAudio),
        if (onVideo != null)
          btn(const Key('conn-video'), Icons.videocam_rounded, t.connVideoCall,
              onVideo),
      ],
    );
  }
}

class ConnectFlow {
  ConnectFlow._();

  /// Tests replace the call screen (no WebRTC in a widget test).
  @visibleForTesting
  static Future<void> Function(
      BuildContext context, Map<String, dynamic> member, String kind)? callOverride;

  /// Tests replace the chat screen (no identity vault in a fake-async test).
  @visibleForTesting
  static Future<void> Function(BuildContext context, Map<String, dynamic> member)?
      chatOverride;

  static bool isAccepted(Map<String, dynamic> m) =>
      '${m['state'] ?? 'accepted'}' == 'accepted';

  static Future<void> openChat(
      BuildContext context, Map<String, dynamic> member) async {
    final o = chatOverride;
    if (o != null) return o(context, member);
    final nav = Navigator.of(context);
    final id = await IdentityVault.instance.get();
    await nav.push(MaterialPageRoute(
        builder: (_) => CircleChatScreen(member: member, identity: id)));
  }

  /// 'voice' | 'video' — the call screen runs the server gate itself.
  static Future<void> call(
      BuildContext context, Map<String, dynamic> member, String kind) async {
    final o = callOverride;
    if (o != null) return o(context, member, kind);
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => CircleCallScreen(member: member, kind: kind)));
  }
}

/// Tapping a My Circle contact / member: photo, name and the three actions.
/// [onMessage] replaces the default "open the chat" (the caller's own path).
Future<void> showConnectSheet(
    BuildContext context, Map<String, dynamic> member,
    {Future<void> Function()? onMessage}) {
  final t = AppLocalizations.of(context);
  final name = '${member['display_name'] ?? member['name'] ?? ''}'.trim();
  final accepted = ConnectFlow.isAccepted(member);
  return showAppSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        key: const Key('conn-sheet'),
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          MsgrAvatar(
              name: name.isEmpty ? '?' : name,
              photoUrl: '${member['photo_link'] ?? member['photo'] ?? ''}',
              photoV: '${member['photo_v'] ?? ''}',
              radius: 36),
          const SizedBox(height: Gap.sm),
          Text(name.isEmpty ? t.circleSomeone : name,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(ctx).textTheme.titleMedium),
          if (!accepted) ...[
            const SizedBox(height: 2),
            Text(t.mr1CallsAfterAccept,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12.5,
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
          ],
          const SizedBox(height: Gap.md),
          ConnectActions(
            onMessage: () {
              Navigator.pop(ctx);
              if (onMessage != null) {
                onMessage();
              } else {
                ConnectFlow.openChat(context, member);
              }
            },
            onAudio: accepted
                ? () {
                    Navigator.pop(ctx);
                    ConnectFlow.call(context, member, 'voice');
                  }
                : null,
            onVideo: accepted
                ? () {
                    Navigator.pop(ctx);
                    ConnectFlow.call(context, member, 'video');
                  }
                : null,
          ),
        ]),
      ),
    ),
  );
}
