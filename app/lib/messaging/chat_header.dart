import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';

/// t1-ticks — WhatsApp-standard chat header title (1:1 and groups).
///
///   line 1  the name — ONE line, full width (Search lives in the ⋮ menu so
///           only video + voice icons sit beside it); ellipsis only when the
///           name really doesn't fit.
///   line 2  smaller status: online / typing… / recording audio… / last seen
///           today at 9:40 pm / yesterday at 8:15 am / Monday at 9:40 pm /
///           18 Oct at 9:40 pm — always with the time, in the phone's 12/24-
///           hour format (mr1, see presence_label.dart). Hidden by privacy ->
///           no line at all.
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

  /// a1-circle: true (1:1) = the status is never cut (2 lines / smaller
  /// font). false (group member list) = one line, ellipsized.
  final bool fitStatusLine;
  const ChatHeaderTitle(
      {super.key,
      required this.name,
      this.status,
      this.statusActive = false,
      this.avatar,
      this.onTap,
      this.fitStatusLine = true});

  /// "online" / "typing…" green: the AA success token (both themes).
  static Color activeColor(BuildContext context) =>
      AssistoTokens.of(context).success;

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
                  child: LayoutBuilder(builder: (ctx, box) {
                    final statusStyle = TextStyle(
                        fontSize: 12.5,
                        height: 1.2,
                        fontWeight:
                            statusActive ? FontWeight.w600 : FontWeight.w400,
                        color: statusActive
                            ? activeColor(context)
                            : scheme.onSurfaceVariant);
                    final fit = s.isEmpty
                        ? null
                        : fitStatusLine
                            ? fitStatus(s, statusStyle, box.maxWidth,
                                MediaQuery.textScalerOf(ctx),
                                Directionality.of(ctx))
                            : (fontSize: 12.5, lines: 1);
                    final col = Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // a1-circle: the NAME gives way first (ellipsis)…
                        Text(
                          name,
                          key: const Key('t1-header-name'),
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: fit != null && fit.lines != 1 ? 16 : 17,
                              height: 1.2,
                              fontWeight: FontWeight.w600,
                              color: scheme.onSurface),
                        ),
                        // …the status ("last seen today at 10:05 pm") is
                        // NEVER cut: one line when it fits, else two lines,
                        // else a slightly smaller font (see fitStatus).
                        if (fit != null)
                          Text(
                            s,
                            key: const Key('t1-header-status'),
                            maxLines: !fitStatusLine
                                ? 1
                                : (fit.lines == 0 ? null : 2),
                            softWrap: fitStatusLine,
                            overflow: fitStatusLine
                                ? TextOverflow.clip
                                : TextOverflow.ellipsis,
                            style: statusStyle.copyWith(fontSize: fit.fontSize),
                          ),
                      ],
                    );
                    // Never a vertical clip inside the toolbar either (large
                    // system font): scale the whole block down as a last
                    // resort rather than cutting a line.
                    // (AppBar lays its title out with an UNBOUNDED height,
                    // so the toolbar's own height is the bound.)
                    if (!box.maxWidth.isFinite) return col;
                    final maxH = box.hasBoundedHeight
                        ? box.maxHeight
                        : kToolbarHeight - 8; // minus the 4+4 padding
                    return ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: maxH),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: AlignmentDirectional.centerStart,
                        child: SizedBox(width: box.maxWidth, child: col),
                      ),
                    );
                  }),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// a1-circle: how the header status line fits [width] without ever being
/// cut (owner: "last seen today at…" was cut off at 360 dp): the largest
/// font from 12.5 down to 10.5 at which [text] takes ONE line, else the
/// largest at which it takes at most TWO lines (word-wrapped), else 10.5 on
/// two lines (the caller's FittedBox scales the block as a last resort).
({double fontSize, int lines}) fitStatus(String text, TextStyle style,
    double width, TextScaler scaler, TextDirection dir) {
  if (!width.isFinite || width <= 0) return (fontSize: 12.5, lines: 1);
  const sizes = [12.5, 12.0, 11.5];
  int linesAt(double fs, int maxLines) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style.copyWith(fontSize: fs)),
      textDirection: dir,
      textScaler: scaler,
      maxLines: maxLines,
    )..layout(maxWidth: width);
    final over = tp.didExceedMaxLines;
    final n = tp.computeLineMetrics().length;
    tp.dispose();
    return over ? 99 : n;
  }

  // one line at a gently smaller size first (keeps the classic look)
  for (final fs in sizes) {
    if (linesAt(fs, 1) == 1) return (fontSize: fs, lines: 1);
  }
  for (final fs in [12.5, 12.0, 11.5, 11.0, 10.5]) {
    if (linesAt(fs, 2) <= 2) return (fontSize: fs, lines: 2);
  }
  // still too long (huge system font): as many lines as it needs - the
  // caller's FittedBox scales the block into the toolbar. Never cut.
  return (fontSize: 10.5, lines: 0);
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
      // the member list is a long, truncatable roster (ellipsis is right)
      fitStatusLine: false,
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
          ? const Icon(Icons.group_rounded, size: 20)
          : Text(n.isEmpty ? '?' : n.characters.first.toUpperCase()),
    );
  }
}
