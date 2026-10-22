import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// t1-ticks — WhatsApp-standard chat header title (1:1 and groups).
///
///   line 1  the name — ONE line, full width (Search lives in the ⋮ menu so
///           only video + voice icons sit beside it); ellipsis only when the
///           name really doesn't fit.
///   line 2  smaller status: online / typing… / recording audio… / last seen
///           today at 12:45 / last seen yesterday at 21:10 / last seen 18 Oct
///           (see presence_label.dart). Hidden by privacy -> no line at all.
///           Groups: member names ("Rahim, Karim, You") or "Rahim is typing…".
///   tap     the whole title opens contact / group info.
///
/// Text scaling is clamped inside the 56 px toolbar (max 1.3×) so a large
/// system font never clips the second line; the name keeps its full width.
class ChatHeaderTitle extends StatelessWidget {
  final String name;

  /// Line 2; null/empty = no second line (privacy / unknown).
  final String? status;

  /// typing / recording: shown in the "active" green, semi-bold.
  final bool statusActive;
  final Widget? avatar;
  final VoidCallback? onTap;
  const ChatHeaderTitle(
      {super.key,
      required this.name,
      this.status,
      this.statusActive = false,
      this.avatar,
      this.onTap});

  static Color activeColor(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF4ADE80)
          : const Color(0xFF15803D);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = (status ?? '').trim();
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3,
      child: Semantics(
        button: onTap != null,
        child: InkWell(
          key: const Key('t1-header'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                if (avatar != null) ...[avatar!, const SizedBox(width: 10)],
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        key: const Key('t1-header-name'),
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 17,
                            height: 1.2,
                            fontWeight: FontWeight.w600,
                            color: scheme.onSurface),
                      ),
                      if (s.isNotEmpty)
                        Text(
                          s,
                          key: const Key('t1-header-status'),
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12.5,
                              height: 1.25,
                              fontWeight: statusActive
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: statusActive
                                  ? activeColor(context)
                                  : scheme.onSurfaceVariant),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Group line 2 when nobody is typing: other members first (roster order),
/// "You" last, comma-separated — the Text ellipsizes what doesn't fit.
/// Empty roster -> null (the caller may show nothing).
String? groupMembersLine(List<String> otherNames, String you) {
  final names =
      otherNames.map((n) => n.trim()).where((n) => n.isNotEmpty).toList();
  if (names.isEmpty) return null;
  return [...names, you].join(', ');
}

/// The group header: [activity] ("Rahim is typing…") wins over the member
/// names line.
class GroupHeaderTitle extends StatelessWidget {
  final String name;
  final List<String> memberNames;
  final String? activity;
  final Widget? avatar;
  final VoidCallback? onTap;
  const GroupHeaderTitle(
      {super.key,
      required this.name,
      this.memberNames = const [],
      this.activity,
      this.avatar,
      this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final act = (activity ?? '').trim();
    return ChatHeaderTitle(
      name: name,
      status: act.isNotEmpty
          ? act
          : (groupMembersLine(memberNames, t.c3You) ?? t.t1GroupTapInfo),
      statusActive: act.isNotEmpty,
      avatar: avatar,
      onTap: onTap,
    );
  }
}

/// The plain initial avatar the chat headers use.
class HeaderInitialAvatar extends StatelessWidget {
  final String name;
  final bool group;
  const HeaderInitialAvatar({super.key, required this.name, this.group = false});

  @override
  Widget build(BuildContext context) {
    final n = name.trim();
    return CircleAvatar(
      radius: 18,
      child: group && n.isEmpty
          ? const Icon(Icons.group_outlined, size: 20)
          : Text(n.isEmpty ? '?' : n.characters.first.toUpperCase()),
    );
  }
}
