import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../screens/circle_call_screen.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart';

/// callsbar (owner checklist: "group call honesty — the client has no group
/// audio yet: build it if feasible or state it honestly").
///
/// A call with 3+ people needs a media mesh / SFU and real-phone proof that
/// do not exist yet, so the group chat's call buttons USED to show
/// "Starting call…" and then nothing (a dead button). Now they open this
/// sheet: it says plainly that group calls are not ready, and offers the
/// thing that works today — a real 1:1 voice / video call with any group
/// member who is in my circle, in ONE tap. Members outside my circle are
/// listed with the reason (no dead button).
///
/// [members]: the group roster rows (`name`, `user_id`, `is_self`,
/// `circle_member_id` = MY circle edge to that person, or null).
Future<void> showGroupCallSheet(
  BuildContext context, {
  required List<Map<String, dynamic>> members,
  required String groupName,
}) {
  final nav = Navigator.of(context);
  return showAppSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => GroupCallSheet(
      members: members,
      groupName: groupName,
      onCall: (member, kind) {
        Navigator.of(ctx).pop();
        nav.push(MaterialPageRoute(
            builder: (_) => CircleCallScreen(member: member, kind: kind)));
      },
    ),
  );
}

class GroupCallSheet extends StatelessWidget {
  const GroupCallSheet({
    super.key,
    required this.members,
    required this.groupName,
    required this.onCall,
  });

  final List<Map<String, dynamic>> members;
  final String groupName;

  /// (member map for [CircleCallScreen], 'voice' | 'video')
  final void Function(Map<String, dynamic> member, String kind) onCall;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final others = members.where((m) => m['is_self'] != true).toList();
    final callable =
        others.where((m) => m['circle_member_id'] is num).toList();
    final notInCircle =
        others.where((m) => m['circle_member_id'] is! num).toList();
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.95,
      builder: (ctx, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xl),
        children: [
          Text(t.cbarGroupTitle,
              key: const Key('group-call-title'),
              style: AType.titleLarge.copyWith(color: scheme.onSurface)),
          const SizedBox(height: Gap.md),
          Container(
            key: const Key('group-call-honest'),
            padding: const EdgeInsets.all(Gap.md),
            decoration: BoxDecoration(
              color: scheme.secondaryContainer,
              borderRadius: BorderRadius.circular(Radii.lg),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline_rounded,
                    color: scheme.onSecondaryContainer),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Text(t.cbarGroupHonest,
                      style: AType.bodyMedium
                          .copyWith(color: scheme.onSecondaryContainer)),
                ),
              ],
            ),
          ),
          const SizedBox(height: Gap.lg),
          if (callable.isNotEmpty) ...[
            Text(t.cbarGroupCallOne,
                style: AType.titleSmall.copyWith(color: scheme.onSurface)),
            const SizedBox(height: Gap.xs),
            for (final m in callable) _row(context, t, m, callable: true),
          ] else ...[
            // empty state: benefit line + how-to
            Text(t.cbarGroupNoneCallable,
                key: const Key('group-call-empty'),
                style: AType.bodyMedium.copyWith(color: scheme.onSurface)),
          ],
          if (notInCircle.isNotEmpty) ...[
            const SizedBox(height: Gap.md),
            Text(t.cbarGroupNotInCircle,
                style: AType.bodySmall
                    .copyWith(color: scheme.onSurfaceVariant)),
            for (final m in notInCircle) _row(context, t, m, callable: false),
          ],
          const SizedBox(height: Gap.lg),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonal(
              key: const Key('group-call-close'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
              onPressed: () => Navigator.of(context).pop(),
              child: Text(t.cbarGroupBackToChat),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, AppLocalizations t, Map<String, dynamic> m,
      {required bool callable}) {
    final scheme = Theme.of(context).colorScheme;
    final name = '${m['name'] ?? ''}'.trim();
    final shown = name.isEmpty ? t.cbarGroupUnnamed : name;
    final id = (m['circle_member_id'] as num?)?.toInt();
    final member = <String, dynamic>{'id': id, 'name': shown};
    return ListTile(
      key: Key('group-call-member-${m['user_id']}'),
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: scheme.primaryContainer,
        foregroundColor: scheme.onPrimaryContainer,
        child: Text(shown.characters.first.toUpperCase()),
      ),
      title: Text(shown, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: !callable
          ? null
          : Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                key: Key('group-call-voice-${m['user_id']}'),
                tooltip: t.cbarGroupVoiceTo(shown),
                icon: const Icon(Icons.call_rounded),
                onPressed: () => onCall(member, 'voice'),
              ),
              IconButton(
                key: Key('group-call-video-${m['user_id']}'),
                tooltip: t.cbarGroupVideoTo(shown),
                icon: const Icon(Icons.videocam_rounded),
                onPressed: () => onCall(member, 'video'),
              ),
            ]),
    );
  }
}
