import 'dart:async';

import 'package:flutter/material.dart';

import '../ds/ds.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../widgets/notif_models.dart' show notifLocalizeDigits;

/// group-calls: the "Join call" bar in a My Circle group chat while a group
/// call is on in that group (late joiners, or someone who declined and
/// changed their mind). Invisible when no call is on, or when I am already
/// in it. [load] = GET circle/group-calls/group/<gid> -> the call or null.
class GroupCallJoinBar extends StatefulWidget {
  const GroupCallJoinBar({
    super.key,
    required this.load,
    required this.onJoin,
    this.every = const Duration(seconds: 15),
  });

  final Future<Map<String, dynamic>?> Function() load;

  /// (room id, 'voice' | 'video')
  final void Function(int roomId, String kind) onJoin;
  final Duration every;

  @override
  State<GroupCallJoinBar> createState() => GroupCallJoinBarState();
}

class GroupCallJoinBarState extends State<GroupCallJoinBar> {
  Map<String, dynamic>? _call;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(refresh());
    _timer = Timer.periodic(widget.every, (_) => unawaited(refresh()));
  }

  /// Re-check now (the chat calls this after its own call button).
  Future<void> refresh() async {
    try {
      final c = await widget.load();
      if (mounted) setState(() => _call = c);
    } catch (_) {
      // offline: keep what we showed; the next tick tries again
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _call;
    final room = (c?['room_id'] as num?)?.toInt();
    if (c == null || room == null || c['my_state'] == 'joined') {
      return const SizedBox.shrink();
    }
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final video = c['kind'] == 'video';
    final n = notifLocalizeDigits(context, '${c['joined'] ?? 0}');
    final full = (c['free'] as num?)?.toInt() == 0;
    return Material(
      key: const Key('gcall-join-bar'),
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.sm, Gap.sm),
        child: Row(
          children: [
            Icon(video ? Icons.videocam_rounded : Icons.call_rounded,
                color: scheme.onPrimaryContainer),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(
                full
                    ? t.gcallFull
                    : (video ? t.gcallJoinBarVideo(n) : t.gcallJoinBar(n)),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: AType.bodyMedium
                    .copyWith(color: scheme.onPrimaryContainer),
              ),
            ),
            if (!full) ...[
              const SizedBox(width: Gap.sm),
              DsButton(
                key: const Key('gcall-join'),
                icon: Icons.call_rounded,
                label: t.gcallJoin,
                onPressed: () => widget.onJoin(room, video ? 'video' : 'voice'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
