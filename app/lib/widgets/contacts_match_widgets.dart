import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'contacts_match_model.dart';
import 'msgr_avatar.dart';

/// Reusable presentation pieces for the ADVANCED contact-match + invite flow
/// (#99/#101, SPEC §21). Pure widgets — no API, no state; the screen wires
/// callbacks. All copy is localized (ARB getters where they exist, else
/// [cmStr]); zero Bangla glyphs live here.

// ---------------------------------------------------------------------------
// 1) PERMISSION DISCLOSURE (Play-compliant, prominent, BEFORE any access)
// ---------------------------------------------------------------------------

class CmDisclosure extends StatelessWidget {
  const CmDisclosure({
    super.key,
    required this.onAllow,
    required this.onDeny,
    required this.onPrivacy,
  });

  final VoidCallback onAllow;
  final VoidCallback onDeny;
  final VoidCallback onPrivacy;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(Gap.xl),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const SizedBox(height: Gap.sm),
        Center(
          child: Container(
            width: 72,
            height: 72,
            decoration: const BoxDecoration(
                shape: BoxShape.circle, gradient: Brand.gradient),
            child: const Icon(Icons.contacts_outlined,
                color: Colors.white, size: 36),
          ),
        ),
        const SizedBox(height: Gap.lg),
        Text(t.msgrContactsPermTitle,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: Gap.md),
        // The four prominent disclosure facts (why / sent / never-stored /
        // control) — Play requires a clear in-context disclosure before the
        // runtime permission prompt.
        _fact(context, Icons.help_outline, 'cmDiscWhyTitle', 'cmDiscWhyBody',
            scheme.primary),
        _fact(context, Icons.lock_outline, 'cmDiscSendTitle', 'cmDiscSendBody',
            scheme.primary),
        _fact(context, Icons.delete_outline, 'cmDiscStoreTitle',
            'cmDiscStoreBody', Brand.success),
        _fact(context, Icons.tune, 'cmDiscControlTitle', 'cmDiscControlBody',
            scheme.primary),
        const SizedBox(height: Gap.sm),
        TextButton.icon(
          onPressed: onPrivacy,
          icon: const Icon(Icons.shield_outlined, size: 18),
          label: Text(cmLabel(context, 'cmPrivacyLearnMore')),
        ),
        const SizedBox(height: Gap.md),
        FilledButton.icon(
          onPressed: onAllow,
          icon: const Icon(Icons.verified_user_outlined),
          label: Text(t.msgrContactsAllow),
        ),
        const SizedBox(height: Gap.xs),
        TextButton(onPressed: onDeny, child: Text(t.msgrContactsDeny)),
      ]),
    );
  }

  Widget _fact(BuildContext context, IconData icon, String titleKey,
      String bodyKey, Color accent) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 20, color: accent),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(cmLabel(context, titleKey),
                style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(cmLabel(context, bodyKey),
                style: TextStyle(
                    color: scheme.onSurfaceVariant, height: 1.4, fontSize: 13)),
          ]),
        ),
      ]),
    );
  }
}

/// The "how this protects your privacy" explainer (a bottom sheet).
Future<void> showCmPrivacyExplainer(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) {
      final scheme = Theme.of(ctx).colorScheme;
      Widget step(String key) => Padding(
            padding: const EdgeInsets.only(bottom: Gap.md),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.check_circle_outline,
                  size: 20, color: Brand.success),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(cmLabel(ctx, key),
                    style: TextStyle(color: scheme.onSurface, height: 1.45)),
              ),
            ]),
          );
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.xl),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 56,
              height: 56,
              decoration:
                  const BoxDecoration(shape: BoxShape.circle, gradient: Brand.gradient),
              child: const Icon(Icons.shield_outlined,
                  color: Colors.white, size: 28),
            ),
            const SizedBox(height: Gap.md),
            Text(cmLabel(ctx, 'cmPrivacyExplainerTitle'),
                textAlign: TextAlign.center,
                style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: Gap.lg),
            step('cmPrivacyStep1'),
            step('cmPrivacyStep2'),
            step('cmPrivacyStep3'),
            step('cmPrivacyStep4'),
            const SizedBox(height: Gap.xs),
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(MaterialLocalizations.of(ctx).okButtonLabel),
            ),
          ]),
        ),
      );
    },
  );
}

// ---------------------------------------------------------------------------
// 2) LOADING / PROGRESS (hashing + match) — a real progress state
// ---------------------------------------------------------------------------

class CmLoading extends StatelessWidget {
  const CmLoading({super.key, required this.progress});

  final CmProgress progress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = switch (progress.phase) {
      CmPhase.reading => cmLabel(context, 'cmPhaseReading'),
      CmPhase.hashing => cmLabel(context, 'cmPhaseHashing'),
      CmPhase.matching => cmLabel(context, 'cmPhaseMatching'),
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            width: 120,
            child: progress.fraction != null && progress.phase == CmPhase.hashing
                ? LinearProgressIndicator(value: progress.fraction)
                : const LinearProgressIndicator(),
          ),
          const SizedBox(height: Gap.lg),
          Text(label, style: Theme.of(context).textTheme.titleSmall),
          if (progress.phase == CmPhase.hashing && progress.total > 0) ...[
            const SizedBox(height: Gap.xs),
            Text(
              AppLocalizations.of(context)
                  .cmHashedOnDevice(cmNum(context, progress.total)),
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
            ),
          ],
          const SizedBox(height: Gap.md),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.lock_outline, size: 14, color: scheme.primary),
            const SizedBox(width: 4),
            Text(cmLabel(context, 'cmDiscSendTitle'),
                style: TextStyle(color: scheme.primary, fontSize: 12)),
          ]),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 3) EMPTY / DENIED / OFFLINE states (nothing raw)
// ---------------------------------------------------------------------------

class CmStateView extends StatelessWidget {
  const CmStateView({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.primaryLabel,
    this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
    this.tone,
  });

  final IconData icon;
  final String title;
  final String body;
  final String? primaryLabel;
  final VoidCallback? onPrimary;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = tone ?? scheme.primary;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 52, color: c.withValues(alpha: 0.8)),
          const SizedBox(height: Gap.md),
          Text(title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Gap.sm),
          Text(body,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.45)),
          if (primaryLabel != null) ...[
            const SizedBox(height: Gap.lg),
            FilledButton(onPressed: onPrimary, child: Text(primaryLabel!)),
          ],
          if (secondaryLabel != null) ...[
            const SizedBox(height: Gap.xs),
            TextButton(onPressed: onSecondary, child: Text(secondaryLabel!)),
          ],
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 4) MATCHED USER ROW (existing user → connect)
// ---------------------------------------------------------------------------

class CmUserRow extends StatelessWidget {
  const CmUserRow({super.key, required this.user, required this.onConnect});

  final Map<String, dynamic> user;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final name = '${user['name'] ?? ''}';
    return ListTile(
      leading: MsgrAvatar(
          name: name,
          photoUrl: '${user['photo_link'] ?? user['photo'] ?? ''}',
          radius: 22),
      title: Text(name.isEmpty ? '?' : name),
      subtitle: user['about'] != null && '${user['about']}'.isNotEmpty
          ? Text('${user['about']}',
              maxLines: 1, overflow: TextOverflow.ellipsis)
          : null,
      trailing: FilledButton.tonal(
        onPressed: onConnect,
        child: Text(AppLocalizations.of(context).msgrConnectAction),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 5) SHAREABLE INVITE CARD (#101) — referral-code embedded
// ---------------------------------------------------------------------------

class CmInviteCardView extends StatelessWidget {
  const CmInviteCardView({
    super.key,
    required this.card,
    required this.onShare,
    required this.onSms,
    required this.onCopy,
    required this.onSeeReferral,
  });

  final CmInviteCard card;
  final VoidCallback onShare;
  final VoidCallback onSms;
  final VoidCallback onCopy;
  final VoidCallback onSeeReferral;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // hero band (brand gradient)
        Container(
          padding: const EdgeInsets.all(Gap.lg),
          decoration: const BoxDecoration(gradient: Brand.gradient),
          child: Row(children: [
            const Icon(Icons.auto_awesome, color: Colors.white),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(cmLabel(context, 'cmInviteCardTitle'),
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 16)),
                    const SizedBox(height: 2),
                    Text(cmLabel(context, 'cmInviteCardBody'),
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12, height: 1.3)),
                  ]),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (card.hasReferral) ...[
              Row(children: [
                Icon(Icons.card_giftcard, size: 18, color: scheme.primary),
                const SizedBox(width: Gap.xs),
                Expanded(
                  child: Text(
                    t.cmInviteCardReferral(card.referralCode),
                    style: TextStyle(
                        fontWeight: FontWeight.w700, color: scheme.primary),
                  ),
                ),
              ]),
              const SizedBox(height: 2),
              Text(cmLabel(context, 'cmInviteCardReferralNote'),
                  style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12,
                      height: 1.35)),
              const SizedBox(height: Gap.sm),
            ],
            // action row — share (any app) OR own-SIM SMS; copy link; referral
            Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
              FilledButton.icon(
                onPressed: onShare,
                icon: const Icon(Icons.ios_share, size: 18),
                label: Text(t.msgrInviteShareLink),
              ),
              OutlinedButton.icon(
                onPressed: onSms,
                icon: const Icon(Icons.sms_outlined, size: 18),
                label: Text(t.msgrInviteSms),
              ),
              TextButton.icon(
                onPressed: onCopy,
                icon: const Icon(Icons.link, size: 18),
                label: Text(cmLabel(context, 'cmInviteCopyLink')),
              ),
            ]),
            if (card.hasReferral)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: onSeeReferral,
                  icon: const Icon(Icons.stars_outlined, size: 18),
                  label: Text(cmLabel(context, 'cmInviteCardSeeReferral')),
                ),
              ),
            // own-SIM honesty note
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.info_outline,
                  size: 14, color: scheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Expanded(
                child: Text(t.msgrInviteSmsNote,
                    style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 11,
                        height: 1.3)),
              ),
            ]),
          ]),
        ),
      ]),
    );
  }
}
