import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart' show withNavBarInset;
import '../widgets/skeleton.dart';
import 'fc_api.dart';
import 'fc_member_card.dart';
import 'fc_slots.dart';
import 'fc_status.dart';
import 'fc_text.dart';

/// fcscreen — MEMBER PAGE: the member's card, today's timeline, and who can
/// see this member (with what), plus the promise that Assisto staff never see
/// places. Opened from a card tap or an ask-bar answer.
class FcMemberPage extends StatefulWidget {
  final int familyId;
  final int userId;
  final Map<String, dynamic>? seed; // the board row, shown while loading
  final DateTime? debugNow;
  final Widget Function(BuildContext, Map<String, dynamic> member)? cardBuilder;
  const FcMemberPage(
      {super.key,
      required this.familyId,
      required this.userId,
      this.seed,
      this.debugNow,
      this.cardBuilder});
  @override
  State<FcMemberPage> createState() => _FcMemberPageState();
}

class _FcMemberPageState extends State<FcMemberPage> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _data = await context.read<AppState>().api.fcMemberPage(widget.userId, widget.familyId);
      _failed = false;
    } catch (_) {
      _failed = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  String _tl(AppLocalizations t, Map e) {
    final text = '${e['text'] ?? ''}';
    final place = '${e['place'] ?? text}';
    return switch ('${e['kind']}') {
      'carecall_done' => t.fc3TlCareDone,
      'carecall_missed' => t.fc3TlCareMissed,
      'carecall_pending' => t.fc3TlCarePending,
      'task_taken' => t.fc3TlTaken(text),
      'task_done' => t.fc3TlDone(text),
      'arrived' => t.fc3TlArrived(place),
      'left' => t.fc3TlLeft(place),
      _ => text,
    };
  }

  IconData _tlIcon(String kind) => switch (kind) {
        'carecall_done' => Icons.call_received_rounded,
        'carecall_missed' => Icons.call_missed_rounded,
        'carecall_pending' => Icons.schedule_rounded,
        'task_taken' || 'task_done' => Icons.task_alt_rounded,
        'arrived' => Icons.home_rounded,
        'left' => Icons.directions_walk_rounded,
        _ => Icons.circle_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final now = widget.debugNow ?? DateTime.now();
    final member = (_data?['member'] as Map?)?.cast<String, dynamic>() ?? widget.seed;
    final me = member?['me'] == true;
    final name = me
        ? t.fc3You
        : ('${member?['label'] ?? ''}'.trim().isNotEmpty
            ? '${member?['label']}'
            : '${member?['name'] ?? ''}');
    final timeline = [
      for (final e in (_data?['timeline'] as List? ?? const []))
        if (e is Map) e
    ];
    final seenBy = [
      for (final e in (_data?['seen_by'] as List? ?? const []))
        if (e is Map) e
    ];
    return Scaffold(
      appBar: AppBar(title: Text(name)),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          key: const ValueKey('fc3-member-page'),
          padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
          children: [
            if (member != null)
              widget.cardBuilder?.call(context, member) ??
                  FcMemberCard(member: member, now: now),
            const SizedBox(height: Gap.lg),
            Text(t.fc3TodayTitle,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            if (_loading)
              const Padding(
                  padding: EdgeInsets.all(Gap.lg),
                  child: Center(child: CircularProgressIndicator()))
            else if (_failed)
              StateMessage(
                icon: Icons.cloud_off_rounded,
                title: t.loadFailed,
                tint: Brand.danger,
                action: FilledButton.icon(
                    onPressed: () {
                      setState(() => _loading = true);
                      _load();
                    },
                    icon: const Icon(Icons.refresh_rounded),
                    label: Text(t.retry)),
              )
            else ...[
              if (timeline.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: Gap.sm),
                  child: Text(t.fc3TimelineEmpty, style: TextStyle(color: scheme.onSurfaceVariant)),
                ),
              for (final e in timeline)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(_tlIcon('${e['kind']}')),
                  title: Text(_tl(t, e)),
                  trailing: Text(fcClock(context, e['at'])),
                ),
              const SizedBox(height: Gap.lg),
              Text(me ? t.fc3SeenByMe : t.fc3SeenByTitle(name),
                  key: const ValueKey('fc3-seen-by'),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              if (seenBy.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: Gap.sm),
                  child: Text(t.fc3SeenByNone),
                ),
              for (final s in seenBy)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(child: Text(fcInitial('${s['name'] ?? ''}'))),
                  title: Text('${s['name'] ?? ''}'),
                  subtitle: Text([
                    s['sees_place'] == false ? t.fc3SeenByNoPlace : t.fc3SeenByPlace,
                    ...((s['families'] as List?) ?? const []).map((f) => '$f'),
                  ].join(' · ')),
                ),
              if (me && FcSlots.privacyScreen != null)
                ListTile(
                  key: const ValueKey('fc3-member-privacy'),
                  contentPadding: EdgeInsets.zero,
                  minTileHeight: 56,
                  leading: const Icon(Icons.privacy_tip_rounded),
                  title: Text(t.fc3MorePrivacy),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (c) => FcSlots.privacyScreen!(c, widget.familyId))),
                ),
              const SizedBox(height: Gap.sm),
              Row(children: [
                Icon(Icons.verified_user_rounded, color: fcInk(context, 'ok')),
                const SizedBox(width: Gap.sm),
                Expanded(child: Text(t.fc3SeenByNote)),
              ]),
            ],
          ],
        ),
      ),
    );
  }
}

/// Helper used by tests: is this board row stale right now on this phone?
bool fcIsStale(Map member, DateTime now) => fcRecheck(member, now).state == 'stale';
