// cde-chat — the Theme picker and the Nicknames sheet (1:1 + groups).
import 'dart:io';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import 'chat_themes.dart';

/// What the user picked in the theme sheet.
class ThemePick {
  final String id; // a preset id, 'custom' (my photo) or 'ai'
  final bool locked; // a Premium choice on a Free plan -> show the plans
  const ThemePick(this.id, {this.locked = false});
}

Future<ThemePick?> showChatThemeSheet(
  BuildContext context, {
  required String currentId,
  required bool premium,
  bool group = false,
  File? currentPhoto,
  bool aiAvailable = false,
  String aiCredits = '',
}) {
  return showModalBottomSheet<ThemePick>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => ChatThemeSheet(
      currentId: currentId,
      premium: premium,
      group: group,
      currentPhoto: currentPhoto,
      aiAvailable: aiAvailable,
      aiCredits: aiCredits,
    ),
  );
}

class ChatThemeSheet extends StatelessWidget {
  final String currentId;
  final bool premium;
  final bool group;
  final File? currentPhoto;
  final bool aiAvailable;
  final String aiCredits;
  const ChatThemeSheet({
    super.key,
    required this.currentId,
    required this.premium,
    this.group = false,
    this.currentPhoto,
    this.aiAvailable = false,
    this.aiCredits = '',
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final ids = [kClassicTheme, for (final d in kChatThemes) d.id];
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.88),
      child: ListView(
        key: const Key('cde-theme-sheet'),
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        children: [
          Text(t.cdeThemeTitle, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Gap.xs),
          Text(group ? t.cdeThemeSubtitleGroup : t.cdeThemeSubtitle,
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35)),
          const SizedBox(height: Gap.md),
          LayoutBuilder(builder: (context, c) {
            final cols = c.maxWidth >= 520 ? 4 : 3;
            const gap = 10.0;
            final w = (c.maxWidth - gap * (cols - 1)) / cols;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final id in ids)
                  SizedBox(
                    width: w,
                    child: _Tile(
                      id: id,
                      selected: id == currentId,
                      locked: !premium && !chatThemeFree(id),
                    ),
                  ),
              ],
            );
          }),
          const SizedBox(height: Gap.md),
          _ActionRow(
            key: const Key('cde-theme-photo'),
            icon: Icons.photo_outlined,
            title: t.cdeThemeFromPhoto,
            subtitle: t.cdeThemeFromPhotoHint,
            locked: !premium,
            selected: currentId == 'custom',
            onTap: () => Navigator.pop(context, ThemePick('custom', locked: !premium)),
          ),
          if (aiAvailable)
            _ActionRow(
              key: const Key('cde-theme-ai'),
              icon: Icons.auto_awesome_outlined,
              title: t.cdeThemeAiCreate,
              subtitle: aiCredits.isEmpty ? t.cdeThemeAiFaceLock : t.cdeThemeAiHint(aiCredits),
              locked: !premium,
              selected: currentId == 'ai',
              onTap: () => Navigator.pop(context, ThemePick('ai', locked: !premium)),
            ),
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  final String id;
  final bool selected;
  final bool locked;
  const _Tile({required this.id, required this.selected, required this.locked});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final label = chatThemeLabel(t, id);
    return Semantics(
      button: true,
      selected: selected,
      label: locked
          ? '$label, ${t.premium}'
          : (selected ? '$label, ${t.cdeThemeInUse}' : label),
      child: InkWell(
        key: Key('cde-theme-$id'),
        borderRadius: BorderRadius.circular(14),
        onTap: () => Navigator.pop(context, ThemePick(id, locked: locked)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 0.78,
              child: Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                      color: selected ? scheme.primary : scheme.outlineVariant,
                      width: selected ? 2.5 : 1),
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ExcludeSemantics(child: ChatThemeSwatch(def: chatThemeById(id))),
                    if (locked)
                      Positioned(
                        right: 6,
                        top: 6,
                        child: _Badge(icon: Icons.lock_outline, text: t.premium),
                      ),
                    if (selected)
                      Positioned(
                        left: 6,
                        top: 6,
                        child: CircleAvatar(
                          radius: 11,
                          backgroundColor: scheme.primary,
                          child: Icon(Icons.check, size: 15, color: scheme.onPrimary),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12.5,
                    height: 1.25,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: scheme.onSurface)),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Badge({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: const Color(0xE6151A23),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 11, color: const Color(0xFFFFD866)),
          const SizedBox(width: 3),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 72),
            child: Text(text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w600)),
          ),
        ]),
      );
}

class _ActionRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool locked;
  final bool selected;
  final VoidCallback onTap;
  const _ActionRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.locked,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: scheme.primaryContainer,
        child: Icon(icon, color: scheme.onPrimaryContainer),
      ),
      title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle, style: const TextStyle(height: 1.3)),
      trailing: locked
          ? Chip(
              visualDensity: VisualDensity.compact,
              avatar: const Icon(Icons.lock_outline, size: 14),
              label: Text(t.premium),
            )
          : (selected ? Icon(Icons.check_circle, color: scheme.primary) : null),
      onTap: onTap,
    );
  }
}

// ---------------------------------------------------------------------------
// Nicknames
// ---------------------------------------------------------------------------

/// One person in the Nicknames sheet.
class NickRow {
  final String slot; // 'peer' | 'me' | 'u<uid>'
  final String realName;
  final String nick;
  final bool isMe;
  final int? uid;
  const NickRow({
    required this.slot,
    required this.realName,
    required this.nick,
    this.isMe = false,
    this.uid,
  });
}

/// The edit result: the row and the new nickname ('' = remove).
typedef NickEdit = (NickRow, String);

Future<NickEdit?> showNicknamesSheet(BuildContext context, List<NickRow> rows) async {
  final row = await showModalBottomSheet<NickRow>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => NicknamesSheet(rows: rows),
  );
  if (row == null || !context.mounted) return null;
  final name = await showNicknameEditor(context, row);
  if (name == null) return null;
  return (row, name);
}

class NicknamesSheet extends StatelessWidget {
  final List<NickRow> rows;
  const NicknamesSheet({super.key, required this.rows});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
      child: ListView(
        key: const Key('cde-nick-sheet'),
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: Gap.lg),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xs),
            child: Text(t.cdeNickTitle, style: Theme.of(context).textTheme.titleLarge),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
            child: Text(t.cdeNickSubtitle,
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35)),
          ),
          for (final r in rows)
            ListTile(
              key: Key('cde-nick-row-${r.slot}'),
              leading: CircleAvatar(
                backgroundColor: scheme.secondaryContainer,
                child: Text(
                  (r.realName.trim().isEmpty ? '?' : r.realName.trim().characters.first)
                      .toUpperCase(),
                  style: TextStyle(color: scheme.onSecondaryContainer),
                ),
              ),
              title: Text(
                r.nick.isNotEmpty
                    ? r.nick
                    : (r.isMe ? t.cdeNickYouRow(r.realName) : r.realName),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                r.nick.isNotEmpty
                    ? (r.isMe ? t.cdeNickYouRow(r.realName) : t.cdeNickRealName(r.realName))
                    : t.cdeNickSet,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.edit_outlined),
              onTap: () => Navigator.pop(context, r),
            ),
        ],
      ),
    );
  }
}

/// The nickname editor. null = cancelled, '' = remove.
Future<String?> showNicknameEditor(BuildContext context, NickRow row) {
  final ctl = TextEditingController(text: row.nick);
  final t = AppLocalizations.of(context);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(row.isMe ? t.cdeNickEditTitleSelf : t.cdeNickEditTitle(row.realName)),
      content: TextField(
        key: const Key('cde-nick-field'),
        controller: ctl,
        autofocus: true,
        maxLength: 40,
        textCapitalization: TextCapitalization.words,
        decoration: InputDecoration(labelText: t.cdeNickEditHint),
        onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
      ),
      actions: [
        if (row.nick.isNotEmpty)
          TextButton(
            key: const Key('cde-nick-remove'),
            onPressed: () => Navigator.pop(ctx, ''),
            child: Text(t.cdeNickRemove),
          ),
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t.cancel)),
        FilledButton(
          key: const Key('cde-nick-save'),
          onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
          child: Text(t.save),
        ),
      ],
    ),
  );
}

/// The AI-theme prompt (Premium; shown only when an image provider is
/// connected). Returns the prompt, or null when cancelled.
Future<String?> showAiThemePrompt(BuildContext context, {required String credits}) {
  final ctl = TextEditingController();
  final t = AppLocalizations.of(context);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(t.cdeThemeAiCreate),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('cde-ai-prompt'),
            controller: ctl,
            autofocus: true,
            maxLength: 200,
            minLines: 2,
            maxLines: 4,
            decoration: InputDecoration(
              labelText: t.cdeThemeAiPromptLabel,
              hintText: t.cdeThemeAiPromptExample,
            ),
          ),
          Text(t.cdeThemeAiHint(credits), style: const TextStyle(height: 1.3)),
          const SizedBox(height: Gap.xs),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.verified_user_outlined,
                size: 16, color: Theme.of(ctx).colorScheme.primary),
            const SizedBox(width: Gap.xs),
            Expanded(child: Text(t.cdeThemeAiFaceLock, style: const TextStyle(height: 1.3))),
          ]),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t.cancel)),
        FilledButton(
          key: const Key('cde-ai-create'),
          onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
          child: Text(t.cdeThemeCreate),
        ),
      ],
    ),
  );
}
