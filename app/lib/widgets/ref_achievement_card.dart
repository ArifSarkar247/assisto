import 'package:flutter/material.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import 'wrapped_share.dart';
import 'subs_common.dart' show fmtInt;

/// Shareable referral ACHIEVEMENT card (feature #102 advanced).
///
/// A festival-style brand-gradient card the user can share as an image. It is
/// wrapped in a RepaintBoundary and captured to a PNG via the proven
/// WrappedShare helper (RepaintBoundary -> toImage -> share_plus) — the same
/// flow Monthly Money Wrapped and the Emergency card already use.
///
/// It renders ONLY real numbers handed down from the backend (friends joined,
/// Premium days earned, the embedded referral code) — nothing is invented. If
/// capture isn't ready yet it falls back to a text share, so the button never
/// dead-ends.
class RefAchievementCard extends StatelessWidget {
  final int friendsJoined;
  final int daysEarnedTotal;
  final int points;
  final String? code;
  const RefAchievementCard({
    super.key,
    required this.friendsJoined,
    required this.daysEarnedTotal,
    required this.points,
    required this.code,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final boundaryKey = GlobalKey();
    final hasCode = (code ?? '').trim().isNotEmpty;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      RepaintBoundary(
        key: boundaryKey,
        child: Container(
          padding: const EdgeInsets.all(Gap.xl),
          decoration: BoxDecoration(
            gradient: Brand.gradient,
            borderRadius: BorderRadius.circular(Radii.lg),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.emoji_events_rounded, color: Colors.white, size: 22),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(t.refCardTitle,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 16)),
              ),
            ]),
            const SizedBox(height: Gap.lg),
            Wrap(spacing: 0, runSpacing: Gap.sm, children: [ // qa1: wraps at large font
              // qa1: locale digits (Latin "0 0 120" in the Bangla card)
              _stat(context, fmtInt(context, friendsJoined), t.refCardFriends),
              const SizedBox(width: Gap.xl),
              _stat(context, fmtInt(context, daysEarnedTotal), t.refCardDays),
              const SizedBox(width: Gap.xl),
              _stat(context, fmtInt(context, points), t.referralPoints),
            ]),
            if (hasCode) ...[
              const SizedBox(height: Gap.lg),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: Gap.md, vertical: Gap.sm),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(Radii.sm),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(t.refShareCodeLabel,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 12)),
                  const SizedBox(width: Gap.sm),
                  Text(code!.trim(),
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.5)),
                ]),
              ),
            ],
          ]),
        ),
      ),
      const SizedBox(height: Gap.md),
      FilledButton.icon(
        onPressed: () async {
          final caption = _caption(t);
          final ok = await WrappedShare.shareAsImage(boundaryKey, caption);
          if (!ok) await WrappedShare.shareAsText(caption);
        },
        icon: const Icon(Icons.ios_share_rounded, size: 18),
        label: Text(t.refCardShare),
      ),
    ]);
  }

  String _caption(AppLocalizations t) {
    final c = (code ?? '').trim();
    final head = t.refCardCaption(daysEarnedTotal, friendsJoined) /* (days, friends) */;
    return c.isNotEmpty ? '$head\n${t.refShareCodeLabel} $c' : head;
  }

  Widget _stat(BuildContext context, String value, String label) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(value,
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.w800, fontSize: 26)),
      Text(label,
          style: const TextStyle(color: Colors.white70, fontSize: 11)),
    ]);
  }
}
