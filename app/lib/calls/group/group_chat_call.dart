import 'dart:async';

import 'package:flutter/material.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import '../../widgets/notif_models.dart' show notifLocalizeDigits;
import '../call_log.dart';
import 'group_call.dart';
import 'group_call_api.dart';
import 'group_call_screen.dart';

/// callsB: the group chat's "Group call in progress · Join call" banner.
/// Polls GET circle/groups/<id>/call/active while the chat is open (light:
/// every 15 s, answers from one indexed query) and hides when I am in it.
class GroupCallJoinBanner extends StatefulWidget {
  const GroupCallJoinBanner({
    super.key,
    required this.api,
    required this.groupId,
    this.groupName = '',
    this.every = const Duration(seconds: 15),
    this.initial,
  });

  final ApiClient api;
  final int groupId;
  final String groupName;
  final Duration every;

  /// Gallery / tests: a fixed answer (no polling).
  final Map<String, dynamic>? initial;

  @override
  State<GroupCallJoinBanner> createState() => _GroupCallJoinBannerState();
}

class _GroupCallJoinBannerState extends State<GroupCallJoinBanner> {
  GroupRoster? _room;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    final init = widget.initial;
    if (init != null) {
      final r = init['room'];
      _room = r is Map ? GroupRoster.fromJson(r.cast<String, dynamic>()) : null;
      return;
    }
    unawaited(_load());
    _timer = Timer.periodic(widget.every, (_) => unawaited(_load()));
  }

  Future<void> _load() async {
    try {
      final j = await ApiGroupCallApi.active(widget.api, widget.groupId);
      final r = j['room'];
      if (!mounted) return;
      setState(() => _room =
          r is Map ? GroupRoster.fromJson(r.cast<String, dynamic>()) : null);
    } catch (e) {
      callLog('group_banner#1', e); // the banner just stays as it was
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _join() async {
    final r = _room;
    if (r == null) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => GroupCallScreen(
            roomId: r.roomId, kind: r.kind, title: widget.groupName)));
    if (mounted && widget.initial == null) unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final r = _room;
    if (r == null || !r.live || r.myState == 'joined') {
      return const SizedBox.shrink();
    }
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final n = notifLocalizeDigits(context, '${r.joined}');
    final full = r.active >= r.max && r.myState != 'ringing';
    return Semantics(
      container: true,
      liveRegion: true,
      child: Material(
        key: const Key('group-join-banner'),
        color: scheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.sm, Gap.sm),
          child: Row(
            children: [
              Icon(r.video ? Icons.videocam_rounded : Icons.call_rounded,
                  color: scheme.onPrimaryContainer),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Text(
                  full ? t.cgJoinFull : t.cgJoinBanner(n),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onPrimaryContainer,
                      fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: Gap.sm),
              FilledButton(
                key: const Key('group-join-call'),
                style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
                onPressed: full ? null : () => unawaited(_join()),
                child: Text(t.cgJoin),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The group chat's call buttons: an ongoing call is JOINED; otherwise pick
/// up to 3 members (my accepted contacts — the others can Join) to ring.
/// [onUpgrade] = the group video Premium gate said no.
Future<void> startGroupCallFromChat(
  BuildContext context, {
  required ApiClient api,
  required int groupId,
  required String groupName,
  required String kind,
  required List<Map<String, dynamic>> members,
  required VoidCallback onUpgrade,
}) async {
  final t = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final nav = Navigator.of(context);
  Map<String, dynamic> act;
  try {
    act = await ApiGroupCallApi.active(api, groupId);
  } catch (e) {
    callLog('group_start#1', e);
    messenger.showSnackBar(SnackBar(content: Text(t.cgStartFailed)));
    return;
  }
  final room = act['room'];
  if (room is Map) {
    final r = GroupRoster.fromJson(room.cast<String, dynamic>());
    await nav.push(MaterialPageRoute<void>(
        builder: (_) => GroupCallScreen(
            roomId: r.roomId, kind: r.kind, title: groupName)));
    return;
  }
  final ringable = ((act['ringable'] ?? const []) as List)
      .whereType<num>()
      .map((e) => e.toInt())
      .toSet();
  final candidates = [
    for (final m in members)
      if (m['is_self'] != true &&
          ringable.contains((m['user_id'] as num?)?.toInt()))
        m
  ];
  if (!context.mounted) return;
  if (candidates.isEmpty) {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.cgStartTitle),
        content: Text(t.cgStartNoContacts),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(t.close)),
        ],
      ),
    );
    return;
  }
  final picked = await showModalBottomSheet<List<int>>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => GroupCallPicker(candidates: candidates),
  );
  if (picked == null || picked.isEmpty) return;
  Map<String, dynamic> body;
  try {
    body = await ApiGroupCallApi.start(api, groupId, kind, picked);
  } on ApiException catch (e) {
    callLog('group_start#2', e);
    messenger.showSnackBar(SnackBar(
        content: Text(e.reason == 'no_one' ? t.cgStartNoOne : t.cgStartFailed)));
    return;
  } catch (e) {
    callLog('group_start#3', e);
    messenger.showSnackBar(SnackBar(content: Text(t.cgStartFailed)));
    return;
  }
  if (body['allowed'] == false) {
    if (body['upgrade_required'] == true) {
      onUpgrade();
    } else {
      messenger.showSnackBar(SnackBar(content: Text(t.cgStartFailed)));
    }
    return;
  }
  final roomId = (body['room_id'] as num?)?.toInt();
  if (roomId == null) return;
  await nav.push(MaterialPageRoute<void>(
      builder: (_) => GroupCallScreen(
          roomId: roomId,
          kind: '${body['kind'] ?? kind}',
          title: groupName,
          started: body['existing'] == true ? null : body)));
}

/// Pick who to ring (max 3 — 4 people with me).
class GroupCallPicker extends StatefulWidget {
  const GroupCallPicker({super.key, required this.candidates});
  final List<Map<String, dynamic>> candidates;
  @override
  State<GroupCallPicker> createState() => _GroupCallPickerState();
}

class _GroupCallPickerState extends State<GroupCallPicker> {
  late final Set<int> _sel = {
    for (final m in widget.candidates.take(kGroupMax - 1))
      (m['user_id'] as num).toInt()
  };

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Column(
        key: const Key('group-call-picker'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xs),
            child: Text(t.cgStartTitle,
                style: Theme.of(context).textTheme.titleLarge),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
            child: Text(t.cgStartHint,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final m in widget.candidates)
                  Builder(builder: (_) {
                    final id = (m['user_id'] as num).toInt();
                    final on = _sel.contains(id);
                    final full = !on && _sel.length >= kGroupMax - 1;
                    return CheckboxListTile(
                      key: Key('group-pick-$id'),
                      value: on,
                      title: Text('${m['name'] ?? ''}',
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      onChanged: full
                          ? null
                          : (v) => setState(() {
                                if (v == true) {
                                  _sel.add(id);
                                } else {
                                  _sel.remove(id);
                                }
                              }),
                    );
                  }),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: FilledButton.icon(
              key: const Key('group-pick-ring'),
              style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
              icon: const Icon(Icons.call_rounded),
              onPressed: _sel.isEmpty
                  ? null
                  : () => Navigator.of(context).pop(_sel.toList()),
              label: Text(t.cgStartRing),
            ),
          ),
        ],
      ),
    );
  }
}
