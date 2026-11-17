import 'package:flutter/material.dart';

import '../ds/ds.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../widgets/notif_models.dart' show notifLocalizeDigits;
import 'call_avatar.dart';

/// group-calls: "Add person" — pick people from My Circle (search +
/// checkboxes). The list comes from the server (GET
/// circle/group-calls/candidates), which never returns a blocked person; the
/// people already in the call are shown ticked and locked. At most [free]
/// more can be picked (a call holds 8 people).
///
/// Returns the picked user ids, or null when closed.
Future<List<int>?> showGroupAddPeopleSheet(
  BuildContext context, {
  required Future<List<Map<String, dynamic>>> Function() load,
  Set<int> alreadyIn = const {},
  int free = 7,
}) {
  return showAppSheet<List<int>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => FractionallySizedBox(
      heightFactor: 0.88,
      child: GroupAddPeoplePanel(
        load: load,
        alreadyIn: alreadyIn,
        free: free,
        onDone: (ids) => Navigator.of(ctx).pop(ids),
        onClose: () => Navigator.of(ctx).pop(),
      ),
    ),
  );
}

class GroupAddPeoplePanel extends StatefulWidget {
  const GroupAddPeoplePanel({
    super.key,
    required this.load,
    required this.onDone,
    required this.onClose,
    this.alreadyIn = const {},
    this.free = 7,
  });

  final Future<List<Map<String, dynamic>>> Function() load;
  final void Function(List<int> userIds) onDone;
  final VoidCallback onClose;
  final Set<int> alreadyIn;
  final int free;

  @override
  State<GroupAddPeoplePanel> createState() => _GroupAddPeoplePanelState();
}

class _GroupAddPeoplePanelState extends State<GroupAddPeoplePanel> {
  List<Map<String, dynamic>>? _people;
  bool _failed = false;
  String _q = '';
  final List<int> _picked = [];

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    setState(() {
      _failed = false;
      _people = null;
    });
    try {
      final p = await widget.load();
      if (mounted) setState(() => _people = p);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  int? _id(Map<String, dynamic> p) => (p['user_id'] as num?)?.toInt();

  bool _inCall(Map<String, dynamic> p) =>
      p['in_call'] == true || widget.alreadyIn.contains(_id(p));

  int get _left => widget.free - _picked.length;

  void _toggle(int id) {
    setState(() {
      if (_picked.contains(id)) {
        _picked.remove(id);
      } else if (_left > 0) {
        _picked.add(id);
      }
    });
  }

  String _d(String s) => notifLocalizeDigits(context, s);

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final people = _people;
    Widget body;
    if (_failed) {
      body = DsEmptyState(
        key: const Key('gcall-pick-error'),
        icon: Icons.wifi_off_rounded,
        title: t.gcallNetwork,
        actionLabel: t.retry,
        onAction: _fetch,
      );
    } else if (people == null) {
      body = const Center(
          child: Padding(
              padding: EdgeInsets.all(Gap.xl),
              child: CircularProgressIndicator()));
    } else if (people.isEmpty) {
      body = DsEmptyState(
        key: const Key('gcall-pick-empty'),
        icon: Icons.groups_rounded,
        title: t.gcallPickEmptyTitle,
        benefit: t.gcallPickEmptyBenefit,
        howTo: [t.gcallPickEmptyHow1, t.gcallPickEmptyHow2],
        actionLabel: t.close,
        actionKey: const Key('gcall-pick-empty-close'),
        onAction: widget.onClose,
      );
    } else {
      final q = _q.trim().toLowerCase();
      final shown = people
          .where((p) => q.isEmpty || '${p['name'] ?? ''}'.toLowerCase().contains(q))
          .toList();
      body = shown.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(Gap.xl),
              child: Text(t.gcallNoMatch,
                  key: const Key('gcall-pick-nomatch'),
                  textAlign: TextAlign.center,
                  style: AType.bodyLarge
                      .copyWith(color: scheme.onSurfaceVariant)))
          : ListView.builder(
              key: const Key('gcall-pick-list'),
              itemCount: shown.length,
              itemBuilder: (_, i) {
                final p = shown[i];
                final id = _id(p);
                final inCall = _inCall(p);
                final picked = id != null && _picked.contains(id);
                final canPick = id != null && !inCall && (picked || _left > 0);
                return CheckboxListTile(
                  key: Key('gcall-pick-$id'),
                  value: inCall || picked,
                  onChanged: canPick ? (_) => _toggle(id) : null,
                  controlAffinity: ListTileControlAffinity.trailing,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: Gap.lg),
                  secondary: CallAvatar(
                    name: '${p['name'] ?? ''}',
                    photoUrl: '${p['photo_url'] ?? ''}',
                    version: '${p['photo_v'] ?? ''}',
                    radius: 22,
                    onDark: false,
                  ),
                  title: Text('${p['name'] ?? ''}',
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: inCall
                      ? Text(t.gcallPickInCall,
                          style: AType.bodyMedium
                              .copyWith(color: scheme.onSurfaceVariant))
                      : null,
                );
              },
            );
    }
    final hasList = people != null && people.isNotEmpty && !_failed;
    return SafeArea(
      top: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xs),
            child: Text(t.gcallPickTitle,
                style: AType.titleLarge.copyWith(color: scheme.onSurface)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
            child: Text(
                _left > 0
                    ? t.gcallPickSeatsLeft(_d('$_left'))
                    : t.gcallFull,
                key: const Key('gcall-pick-seats'),
                style: AType.bodyMedium.copyWith(
                    color: _left > 0 ? scheme.onSurfaceVariant : scheme.error)),
          ),
          if (hasList)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  Gap.lg, Gap.md, Gap.lg, Gap.sm),
              child: TextField(
                key: const Key('gcall-pick-search'),
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search_rounded),
                  hintText: t.gcallPickSearch,
                ),
                onChanged: (v) => setState(() => _q = v),
              ),
            ),
          Expanded(child: body),
          if (hasList)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  Gap.lg, Gap.sm, Gap.lg, Gap.lg),
              child: DsButton(
                key: const Key('gcall-pick-ring'),
                icon: Icons.call_rounded,
                expand: true,
                label: t.gcallPickRing(_d('${_picked.length}')),
                onPressed: _picked.isEmpty
                    ? null
                    : () => widget.onDone(List<int>.of(_picked)),
              ),
            ),
        ],
      ),
    );
  }
}
