import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// A group member row with role badge and an admin action menu
/// (promote/demote/remove). Visibility of actions mirrors the server rules in
/// core/logic/circle_groups: only admins act; the last admin can't be demoted
/// or removed (the menu hides those options so the UI matches the server, which
/// re-enforces them anyway).
class CircleGroupMemberTile extends StatelessWidget {
  final Map<String, dynamic> member;
  final bool viewerIsAdmin;
  final int adminCount;
  final VoidCallback onPromote;
  final VoidCallback onDemote;
  final VoidCallback onRemove;

  const CircleGroupMemberTile({
    super.key,
    required this.member,
    required this.viewerIsAdmin,
    required this.adminCount,
    required this.onPromote,
    required this.onDemote,
    required this.onRemove,
  });

  bool get _isAdmin => '${member['role']}' == 'admin';
  bool get _isSelf => member['is_self'] == true;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final name = '${member['name'] ?? ''}';

    // The last admin may not be demoted or removed (keeps >=1 admin).
    final isLastAdmin = _isAdmin && adminCount <= 1;

    final menuItems = <PopupMenuEntry<String>>[];
    if (viewerIsAdmin && !_isSelf) {
      if (_isAdmin) {
        if (!isLastAdmin) {
          menuItems.add(PopupMenuItem(
              value: 'demote', child: Text(t.circleGroupDemote)));
        }
      } else {
        menuItems.add(PopupMenuItem(
            value: 'promote', child: Text(t.circleGroupPromote)));
      }
      if (!isLastAdmin) {
        menuItems.add(PopupMenuItem(
            value: 'remove', child: Text(t.circleGroupRemove)));
      }
    }

    return ListTile(
      leading: CircleAvatar(child: Text(_initial(name))),
      title: Text(name),
      subtitle: Text(_isAdmin ? t.circleGroupRoleAdmin : t.circleGroupRoleMember),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_isAdmin)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(t.circleGroupRoleAdmin,
                  style: Theme.of(context).textTheme.labelSmall),
            ),
          if (menuItems.isNotEmpty)
            PopupMenuButton<String>(
              onSelected: (v) {
                switch (v) {
                  case 'promote':
                    onPromote();
                    break;
                  case 'demote':
                    onDemote();
                    break;
                  case 'remove':
                    onRemove();
                    break;
                }
              },
              itemBuilder: (_) => menuItems,
            ),
        ],
      ),
    );
  }

  String _initial(String name) =>
      name.trim().isEmpty ? '?' : name.trim().characters.first.toUpperCase();
}
