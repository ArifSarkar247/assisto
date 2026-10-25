import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';

/// One member row in a community: name + photo. The phone number is PRIVATE by
/// default — the server only sends it when the member opted in (show_phone) or
/// it is the viewer themselves. When hidden we show a clear "phone hidden"
/// badge rather than any placeholder number, so the privacy state is obvious.
class MsgrCommunityMemberTile extends StatelessWidget {
  final String name;
  final String? photoRef;

  /// Server-decided: non-null only when the member chose to show it (or self).
  final String? phone;

  /// Server flag mirrored into the card; drives the "hidden" badge.
  final bool phoneHidden;

  final bool isAdmin;
  final bool isSelf;

  /// DM this member. First contact outside the recipient's circle becomes a
  /// message request (handled by the caller); null hides the action (self).
  final VoidCallback? onMessage;

  /// Admin-only remove action; null hides it.
  final VoidCallback? onRemove;

  const MsgrCommunityMemberTile({
    super.key,
    required this.name,
    this.photoRef,
    this.phone,
    this.phoneHidden = true,
    this.isAdmin = false,
    this.isSelf = false,
    this.onMessage,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final hasPhoto = photoRef != null && photoRef!.isNotEmpty;
    return ListTile(
      leading: CircleAvatar(
        radius: 22,
        backgroundColor: scheme.primaryContainer,
        backgroundImage: hasPhoto ? NetworkImage(photoRef!) : null,
        child: hasPhoto
            ? null
            : Text(
                name.isNotEmpty ? name.characters.first.toUpperCase() : '?',
                style: TextStyle(color: scheme.onPrimaryContainer),
              ),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(isSelf ? t.communityMemberYou(name) : name,
                overflow: TextOverflow.ellipsis),
          ),
          if (isAdmin) ...[
            const SizedBox(width: Gap.sm),
            _tag(context, t.communityRoleAdmin, scheme.tertiary),
          ],
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: (phone != null && phone!.isNotEmpty)
            ? Text(phone!,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12))
            : Row(
                children: [
                  Icon(Icons.lock_outline_rounded,
                      size: 13, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 4),
                  Text(t.communityPhoneHidden,
                      style: TextStyle(
                          color: scheme.onSurfaceVariant, fontSize: 12)),
                ],
              ),
      ),
      trailing: _trailing(context, t),
    );
  }

  Widget? _trailing(BuildContext context, AppLocalizations t) {
    final items = <Widget>[];
    if (onMessage != null) {
      items.add(IconButton(
        tooltip: t.communityMemberMessage,
        icon: const Icon(Icons.chat_bubble_outline_rounded),
        onPressed: onMessage,
      ));
    }
    if (onRemove != null) {
      items.add(PopupMenuButton<String>(
        tooltip: t.communityMemberMore,
        onSelected: (_) => onRemove!(),
        itemBuilder: (_) => [
          PopupMenuItem(value: 'remove', child: Text(t.communityMemberRemove)),
        ],
      ));
    }
    if (items.isEmpty) return null;
    if (items.length == 1) return items.first;
    return Row(mainAxisSize: MainAxisSize.min, children: items);
  }

  Widget _tag(BuildContext context, String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
        child: Text(label,
            style: TextStyle(
                color: color, fontSize: 11, fontWeight: FontWeight.w600)),
      );
}
