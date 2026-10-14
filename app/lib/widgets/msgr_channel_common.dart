import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';

/// Assisto Messenger — CHANNELS shared UI pieces (Step 3).
///
/// Original Assisto identity throughout: our own brand tokens, our own icon
/// choices and wording — nothing is copied from WhatsApp / Meta. These are the
/// reusable bits the channel_* / discover_* screens share so every channel
/// surface feels like one app.

/// Bangla digits via codepoints (zero == U+09E6) — keeps ALL Bangla out of the
/// Dart source while still localising numerals the server didn't pre-format.
String msgrLocalizeDigits(String s, bool bn) {
  if (!bn) return s;
  const base = 0x09E6;
  final buf = StringBuffer();
  for (final ch in s.runes) {
    buf.writeCharCode((ch >= 0x30 && ch <= 0x39) ? base + (ch - 0x30) : ch);
  }
  return buf.toString();
}

/// True when the UI is rendering in Bangla (used to localise numerals).
bool msgrIsBn(BuildContext c) =>
    Localizations.localeOf(c).languageCode == 'bn';

/// Our own channel reaction set — deliberately original (NOT WhatsApp's set).
/// The server stores per-emoji aggregate counts only, so these can never be
/// used to enumerate followers.
const msgrChannelReactions = ['👍', '❤️', '🎉', '👏', '😮', '🙏'];

/// Resolve a `{bn,en}` display pair or a plain string from a server field.
String msgrPair(dynamic v, bool bn) {
  if (v is Map) return '${(bn ? v['bn'] : v['en']) ?? v['en'] ?? ''}';
  return '${v ?? ''}';
}

/// A channel avatar — brand gradient ring + initial (no photo asset reuse).
class MsgrChannelAvatar extends StatelessWidget {
  final String name;
  final double size;
  const MsgrChannelAvatar({super.key, required this.name, this.size = 48});

  @override
  Widget build(BuildContext context) {
    final letter =
        name.trim().isEmpty ? '#' : name.trim().characters.first.toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: Brand.gradient,
      ),
      child: Text(
        letter,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: size * 0.42,
        ),
      ),
    );
  }
}

/// The verified badge — rendered ONLY by callers that have already checked
/// `is_verified` (operator-granted). There is no self-grant anywhere in the UI.
class MsgrVerifiedBadge extends StatelessWidget {
  final double size;
  const MsgrVerifiedBadge({super.key, this.size = 16});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Tooltip(
      message: t.channelVerified,
      child: Icon(Icons.verified_rounded,
          size: size, color: Theme.of(context).colorScheme.primary),
    );
  }
}

/// The prominent "not end-to-end encrypted — public" label. This is the
/// deliberate opposite of personal / group chats (which stay E2E) and must be
/// shown clearly on every channel surface.
class MsgrNotEncryptedBanner extends StatelessWidget {
  const MsgrNotEncryptedBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: Gap.lg, vertical: Gap.md),
      color: cs.secondaryContainer,
      child: Row(
        children: [
          Icon(Icons.public, size: 18, color: cs.onSecondaryContainer),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(
              t.channelNotEncryptedNote,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: cs.onSecondaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}

/// A single channel row for lists / search results. Shows follower COUNT and a
/// verified badge ONLY when `is_verified`. The trailing slot takes a
/// follow/following action.
class MsgrChannelTile extends StatelessWidget {
  final Map<String, dynamic> channel;
  final VoidCallback? onTap;
  final Widget? trailing;
  const MsgrChannelTile({
    super.key,
    required this.channel,
    this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final bn = msgrIsBn(context);
    final name = '${channel['name'] ?? ''}';
    final handle = '${channel['handle'] ?? ''}';
    final verified = channel['is_verified'] == true;
    final count = (channel['follower_count'] as num?)?.toInt() ?? 0;
    final followers =
        msgrLocalizeDigits(t.channelFollowerCount(count.toString()), bn);
    final sub = handle.isEmpty ? followers : '@$handle · $followers';
    return ListTile(
      onTap: onTap,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.xs),
      leading: MsgrChannelAvatar(name: name),
      title: Row(
        children: [
          Flexible(
            child: Text(name,
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          if (verified) ...[
            const SizedBox(width: Gap.xs),
            const MsgrVerifiedBadge(),
          ],
        ],
      ),
      subtitle: Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: trailing,
    );
  }
}

/// A compact follow / following pill used in lists.
class MsgrFollowButton extends StatelessWidget {
  final bool following;
  final bool busy;
  final VoidCallback? onPressed;
  const MsgrFollowButton({
    super.key,
    required this.following,
    this.busy = false,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (busy) {
      return const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (following) {
      return OutlinedButton(
        onPressed: onPressed,
        child: Text(t.channelFollowing),
      );
    }
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(minimumSize: const Size(0, 38)),
      child: Text(t.channelFollow),
    );
  }
}

/// A friendly empty state (used when there are no channels / no results).
class MsgrEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final Widget? action;
  const MsgrEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: cs.primary),
            const SizedBox(height: Gap.lg),
            Text(title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Gap.sm),
            Text(body,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: cs.onSurfaceVariant)),
            if (action != null) ...[
              const SizedBox(height: Gap.xl),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
