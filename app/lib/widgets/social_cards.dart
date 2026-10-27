import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'social_engine.dart';

/// social_cards.dart — presentation atoms for the SOCIAL-MEDIA POST & CAPTION
/// composer (#135, §21): the honest "AI-generated — review before posting"
/// marker, platform / tone / length / language choosers, the per-platform
/// character counter, hashtag + emoji chip rows, and a saved-draft tile.
///
/// Every string comes from an l10n key — ZERO Bangla literals here (and the
/// one-line token→label switches keep the bn/en pairs in `up_social_arb.json`).

// ----------------------------------------------------- token → localised label

String platformLabel(AppLocalizations t, String id) {
  switch (id) {
    case 'facebook':
      return t.socialPlatFacebook;
    case 'instagram':
      return t.socialPlatInstagram;
    case 'linkedin':
      return t.socialPlatLinkedin;
    case 'whatsapp':
      return t.socialPlatWhatsapp;
  }
  return id;
}

IconData platformIcon(String id) {
  switch (id) {
    case 'facebook':
      return Icons.facebook_rounded;
    case 'instagram':
      return Icons.photo_camera_rounded;
    case 'linkedin':
      return Icons.work_outline_rounded;
    case 'whatsapp':
      return Icons.chat_bubble_outline_rounded;
  }
  return Icons.public_rounded;
}

String toneLabel(AppLocalizations t, String id) {
  switch (id) {
    case 'friendly':
      return t.socialToneFriendly;
    case 'professional':
      return t.socialToneProfessional;
    case 'funny':
      return t.socialToneFunny;
    case 'inspirational':
      return t.socialToneInspirational;
    case 'promotional':
      return t.socialTonePromotional;
  }
  return id;
}

String lengthLabel(AppLocalizations t, String id) {
  switch (id) {
    case 'short':
      return t.socialLenShort;
    case 'medium':
      return t.socialLenMedium;
    case 'long':
      return t.socialLenLong;
  }
  return id;
}

String langLabel(AppLocalizations t, String id) {
  switch (id) {
    case 'bn':
      return t.socialLangBn;
    case 'banglish':
      return t.socialLangBanglish;
    case 'en':
      return t.socialLangEn;
  }
  return id;
}

String problemLabel(AppLocalizations t, String key) {
  switch (key) {
    case 'topic_required':
      return t.socialErrTopic;
    case 'bad_platform':
      return t.socialErrPlatform;
    case 'bad_tone':
      return t.socialErrTone;
    case 'bad_length':
      return t.socialErrLength;
    case 'bad_lang':
      return t.socialErrLang;
  }
  return key;
}

// ----------------------------------------------------- honest AI marker

/// The always-visible "AI-generated — review before posting" marker. The draft
/// is a deterministic MOCK; real AI is key-gated (Integrations). We also say,
/// honestly, that Assisto never posts for you — you share it yourself.
class AiDraftMarker extends StatelessWidget {
  const AiDraftMarker({super.key});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.auto_awesome_rounded, size: 18, color: scheme.onTertiaryContainer),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.f6BwTemplateMarker, // truth: template, not AI
                style: TextStyle(
                    color: scheme.onTertiaryContainer,
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                    height: 1.4)),
            const SizedBox(height: 2),
            Text(t.socialNeverAutoPost,
                style: TextStyle(
                    color: scheme.onTertiaryContainer,
                    fontSize: 12,
                    height: 1.4)),
          ]),
        ),
      ]),
    );
  }
}

// ----------------------------------------------------- chooser chip row

/// A single-select chip row (platform / tone / length / language). Generic so
/// all four choosers share the same accessible, theme-tokened widget.
class ChoiceChipsRow extends StatelessWidget {
  final String label;
  final List<String> values;
  final String selected;
  final String Function(String) display;
  final ValueChanged<String> onSelect;
  final IconData Function(String)? leading;
  const ChoiceChipsRow({
    super.key,
    required this.label,
    required this.values,
    required this.selected,
    required this.display,
    required this.onSelect,
    this.leading,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label,
          style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 13,
              color: scheme.onSurfaceVariant)),
      const SizedBox(height: Gap.sm),
      Wrap(
        spacing: Gap.sm,
        runSpacing: Gap.sm,
        children: [
          for (final v in values)
            ChoiceChip(
              selected: v == selected,
              onSelected: (_) => onSelect(v),
              avatar: leading != null
                  ? Icon(leading!(v),
                      size: 16,
                      color: v == selected
                          ? scheme.onSecondaryContainer
                          : scheme.onSurfaceVariant)
                  : null,
              label: Text(display(v),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
        ],
      ),
    ]);
  }
}

// ----------------------------------------------------- character counter

/// Per-platform "used / limit" counter; turns to the danger colour when over.
class CharCounter extends StatelessWidget {
  final CharCount count;
  const CharCounter({super.key, required this.count});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final over = count.over;
    final near = !over && count.remaining <= (count.limit * 0.1);
    final color = over
        ? Brand.danger
        : (near ? Brand.warning : scheme.onSurfaceVariant);
    return Row(mainAxisAlignment: MainAxisAlignment.end, children: [
      if (over) Icon(Icons.error_outline_rounded, size: 14, color: color),
      if (over) const SizedBox(width: 4),
      Text('${count.used} / ${count.limit}',
          style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: over ? FontWeight.w700 : FontWeight.w500)),
    ]);
  }
}

// ----------------------------------------------------- chip rows (hashtag/emoji)

/// Tappable hashtag suggestions — tapping appends the tag to the draft body.
class HashtagChips extends StatelessWidget {
  final List<String> tags;
  final ValueChanged<String> onTap;
  const HashtagChips({super.key, required this.tags, required this.onTap});
  @override
  Widget build(BuildContext context) {
    if (tags.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: Gap.sm,
      runSpacing: Gap.xs,
      children: [
        for (final tag in tags)
          ActionChip(
            label: Text(tag),
            onPressed: () => onTap(tag),
            visualDensity: VisualDensity.compact,
          ),
      ],
    );
  }
}

/// Tappable emoji — appends to the draft body. Empty on platforms that
/// discourage emoji (LinkedIn), so the caller hides the whole section.
class EmojiChips extends StatelessWidget {
  final List<String> emoji;
  final ValueChanged<String> onTap;
  const EmojiChips({super.key, required this.emoji, required this.onTap});
  @override
  Widget build(BuildContext context) {
    if (emoji.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: Gap.sm,
      children: [
        for (final e in emoji)
          InkWell(
            borderRadius: BorderRadius.circular(Radii.sm),
            onTap: () => onTap(e),
            child: Padding(
              padding: const EdgeInsets.all(Gap.xs),
              child: Text(e, style: const TextStyle(fontSize: 22)),
            ),
          ),
      ],
    );
  }
}

// ----------------------------------------------------- saved-draft tile

class SavedDraftTile extends StatelessWidget {
  final SavedDraft d;
  final VoidCallback onOpen;
  final VoidCallback onDelete;
  const SavedDraftTile({
    super.key,
    required this.d,
    required this.onOpen,
    required this.onDelete,
  });
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final preview =
        d.body.replaceAll('\n', ' ').trim();
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        onTap: onOpen,
        leading: CircleAvatar(
          backgroundColor: scheme.secondaryContainer,
          child: Icon(platformIcon(d.platform),
              size: 20, color: scheme.onSecondaryContainer),
        ),
        title: Text(
          d.topic.isEmpty ? platformLabel(t, d.platform) : d.topic,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(preview,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.3)),
        trailing: IconButton(
          icon: Icon(Icons.delete_outline_rounded, size: 20, color: Brand.danger),
          tooltip: t.delete,
          onPressed: onDelete,
        ),
      ),
    );
  }
}
