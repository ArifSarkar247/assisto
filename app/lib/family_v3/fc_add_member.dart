import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../famcare_api.dart';
import '../l10n/app_localizations.dart';
import '../services/action_feedback.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart';
import '../screens/messenger/messenger_home_screen.dart'; // gap-familycare
import 'fc_api.dart';
import 'fc_text.dart';

/// fcscreen — "Add member": pick from My Circle in one tap (Family group
/// first), choose Adult / Elder / Child. Adults get an invite they accept on
/// their own phone; a child is added at once only by an approved guardian
/// (the server decides). Returns true when something changed.
Future<bool?> showFcAddMember(BuildContext context,
    {required int familyId, required Set<int> inFamilyUserIds}) {
  return showAppSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => FcAddMemberSheet(familyId: familyId, inFamily: inFamilyUserIds),
  );
}

class FcAddMemberSheet extends StatefulWidget {
  final int familyId;
  final Set<int> inFamily;
  const FcAddMemberSheet({super.key, required this.familyId, required this.inFamily});
  @override
  State<FcAddMemberSheet> createState() => _FcAddMemberSheetState();
}

class _FcAddMemberSheetState extends State<FcAddMemberSheet> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  bool _failed = false;
  final Set<int> _sent = {};
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await context.read<AppState>().api.famCirclePick();
      _rows = [
        for (final x in (r['results'] as List? ?? const []))
          if (x is Map) Map<String, dynamic>.from(x)
      ];
      _failed = false;
    } catch (_) {
      _failed = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _invite(Map<String, dynamic> row) async {
    final t = AppLocalizations.of(context);
    final name = '${row['name'] ?? ''}';
    final role = await showAppSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
              child: Text(t.fc3RoleAsk(name),
                  style: Theme.of(ctx).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            ),
            for (final (k, label, icon) in [
              ('adult', t.fc3RoleAdult, Icons.person_rounded),
              ('elder', t.fc3RoleElder, Icons.elderly_rounded),
              ('child', t.fc3RoleChild, Icons.child_care_rounded),
            ])
              ListTile(
                key: ValueKey('fc3-role-$k'),
                minTileHeight: 56,
                leading: Icon(icon),
                title: Text(label),
                onTap: () => Navigator.pop(ctx, k),
              ),
          ],
        ),
      ),
    );
    if (role == null || !mounted) return;
    final api = context.read<AppState>().api;
    try {
      final r = await api.fcInvite(widget.familyId, (row['circle_id'] as num).toInt(),
          role: role, relation: '${row['relation'] ?? ''}');
      if (!mounted) return;
      setState(() {
        _sent.add((row['circle_id'] as num).toInt());
        _changed = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(r['state'] == 'active' ? t.fc3ChildAdded(name) : t.fc3InviteSent(name))));
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (mounted) showActionFailed(context, 'fc3.invite', e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return ListView(
        key: const ValueKey('fc3-add-sheet'),
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        children: [
          Row(children: [
            Expanded(
              child: Text(t.fc3AddTitle,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            ),
            IconButton(
              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
              onPressed: () => Navigator.pop(context, _changed),
              icon: const Icon(Icons.close_rounded),
            ),
          ]),
          Text(t.fc3AddNote, style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.sm),
          if (_loading)
            const Padding(
                padding: EdgeInsets.all(Gap.xl),
                child: Center(child: CircularProgressIndicator()))
          else if (_failed)
            Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: FilledButton.icon(
                onPressed: () {
                  setState(() => _loading = true);
                  _load();
                },
                icon: const Icon(Icons.refresh_rounded),
                label: Text(t.retry),
              ),
            )
          else if (_rows.isEmpty)
            Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Text(t.fc3AddEmpty, key: const ValueKey('fc3-add-empty')),
            )
          else
            for (final r in _rows) _row(r, t),
          // gap-familycare: never a dead end — add the person to My Circle
          // here, then pick them (the list reloads on the way back)
          if (!_loading && !_failed) ...[
            const SizedBox(height: Gap.sm),
            if (_rows.isEmpty)
              FilledButton.icon(
                key: const ValueKey('fcg-add-to-circle'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                onPressed: _addToCircle,
                icon: const Icon(Icons.person_add_alt_1_rounded),
                label: Text(t.c1AddToCircle),
              )
            else
              OutlinedButton.icon(
                key: const ValueKey('fcg-add-to-circle'),
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                onPressed: _addToCircle,
                icon: const Icon(Icons.person_add_alt_1_rounded),
                label: Text(t.c1AddToCircle),
              ),
          ],
        ],
    );
  }

  Future<void> _addToCircle() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const MessengerHomeScreen(startAdd: true)));
    if (!mounted) return;
    setState(() => _loading = true);
    await _load();
  }

  Widget _row(Map<String, dynamic> r, AppLocalizations t) {
    final id = (r['circle_id'] as num?)?.toInt() ?? 0;
    final uid = (r['user_id'] as num?)?.toInt();
    final name = '${r['name'] ?? ''}';
    final inFam = uid != null && widget.inFamily.contains(uid);
    final sent = _sent.contains(id);
    return ListTile(
      key: ValueKey('fc3-add-$id'),
      minTileHeight: 56,
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(child: Text(fcInitial(name))),
      title: Text(name),
      subtitle: inFam ? Text(t.fc3InFamily) : null,
      trailing: inFam || sent
          ? const Icon(Icons.check_circle_rounded, color: Brand.success)
          : FilledButton.tonal(onPressed: () => _invite(r), child: Text(t.fc3Invite)),
      onTap: inFam || sent ? null : () => _invite(r),
    );
  }
}
