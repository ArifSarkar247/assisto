import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'package:assisto/widgets/app_sheet.dart';

/// Result of the group-create sheet.
class CircleGroupDraft {
  final String name;
  final String description;
  final String? photoRef; // encrypted-blob reference (media is key-gated)
  final List<int> memberIds; // CIRCLE members chosen to seed the group
  const CircleGroupDraft({
    required this.name,
    required this.description,
    required this.memberIds,
    this.photoRef,
  });
}

/// Create-group bottom sheet: name (required), description, and a picker of
/// CIRCLE MEMBERS to add. Only circle members are offered — groups are
/// circle-only (the server re-enforces this in
/// core/logic/circle_groups.can_add_member). Photo is key-gated media, so the
/// sheet shows an avatar placeholder and leaves photo wiring to the integrator.
Future<CircleGroupDraft?> showCircleGroupCreateSheet(
  BuildContext context, {
  List<Map<String, dynamic>> circleMembers = const [],
}) {
  return showAppSheet<CircleGroupDraft>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _CircleGroupCreateSheet(circleMembers: circleMembers),
  );
}

class _CircleGroupCreateSheet extends StatefulWidget {
  final List<Map<String, dynamic>> circleMembers;
  const _CircleGroupCreateSheet({required this.circleMembers});

  @override
  State<_CircleGroupCreateSheet> createState() =>
      _CircleGroupCreateSheetState();
}

class _CircleGroupCreateSheetState extends State<_CircleGroupCreateSheet> {
  final _name = TextEditingController();
  final _desc = TextEditingController();
  final Set<int> _selected = {};

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final canCreate = _name.text.trim().isNotEmpty;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: CircleAvatar(
                radius: 32,
                backgroundColor:
                    Theme.of(context).colorScheme.primaryContainer,
                child: const Icon(Icons.groups_rounded, size: 30),
              ),
            ),
            const SizedBox(height: Gap.lg),
            TextField(
              controller: _name,
              maxLength: 100,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: t.circleGroupName,
                prefixIcon: const Icon(Icons.badge_rounded),
              ),
            ),
            TextField(
              controller: _desc,
              maxLength: 1000,
              maxLines: 3,
              minLines: 1,
              decoration: InputDecoration(
                labelText: t.circleGroupDescription,
                prefixIcon: const Icon(Icons.notes_rounded),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: Gap.md),
            Text(t.circleGroupAddMembers,
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: Gap.xs),
            if (widget.circleMembers.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Gap.md),
                child: Text(t.circleGroupNoCircleMembers,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
              )
            else
              Wrap(
                spacing: Gap.sm,
                runSpacing: Gap.sm,
                children: [
                  for (final m in widget.circleMembers)
                    FilterChip(
                      label: Text('${m['name'] ?? ''}'),
                      selected: _selected.contains(_idOf(m)),
                      onSelected: (v) => setState(() {
                        final id = _idOf(m);
                        if (v) {
                          _selected.add(id);
                        } else {
                          _selected.remove(id);
                        }
                      }),
                    ),
                ],
              ),
            const SizedBox(height: Gap.lg),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.check_rounded),
                onPressed: canCreate
                    ? () => Navigator.pop(
                          ctx0(context),
                          CircleGroupDraft(
                            name: _name.text.trim(),
                            description: _desc.text.trim(),
                            memberIds: _selected.toList(),
                          ),
                        )
                    : null,
                label: Text(t.circleGroupCreate),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // The sheet's own context (for Navigator.pop).
  BuildContext ctx0(BuildContext c) => c;

  int _idOf(Map<String, dynamic> m) {
    final raw = m['id'] ?? m['member_id'] ?? 0;
    if (raw is int) return raw;
    return int.tryParse('$raw') ?? 0;
  }
}
