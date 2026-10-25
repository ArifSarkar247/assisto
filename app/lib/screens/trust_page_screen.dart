import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../widgets/chatnav.dart';

/// TRUST / PROOF PAGE — ADVANCED (#201, SPEC v2.1 §20).
///
/// Assisto's integrity statement: a transparency page that honestly states what
/// the app DOES and DOES NOT do. Every claim here is written to be TRUE to the
/// codebase as it stands — nothing aspirational is stated as fact, and anything
/// not yet fully shipped is phrased conservatively (e.g. end-to-end encryption
/// is claimed only for the surface where it is actually implemented today,
/// Connected Circle TEXT messages; media/voice/video are honestly flagged as
/// "coming when encrypted storage is enabled", not claimed).
///
/// This page is STATIC — no backend, no persistence, no network, no AI. It is a
/// fixed, verifiable document. It links out to the live privacy / security /
/// about surfaces (Legal pages and the About page) so a user can read the full
/// policies and verify the claims.
///
/// §21: bilingual (every string an AppLocalizations getter — ZERO Bangla
/// literals), honest (no loading/empty/error needed: static content always
/// renders), WCAG-safe (theme tokens + explicit high-contrast accents),
/// no clipped text at 360dp (wrapping bodies, FittedBox title).
///
/// The claims verified against the codebase (see up_farmtrust_integration.md):
///   1. We never hold your money.      — payment ladder kHoldsMoney=false; we
///      only prefill the user's OWN bank/MFS app; no wallet, no charge path.
///   2. Your Circle chats are E2E.     — core/logic/circle.py software fallback
///      (X25519 + AEAD), server stores ciphertext only; TEXT today, media/voice
///      "coming when encrypted storage is enabled".
///   3. AI only with your key+consent.  — no AI runs without an owner-provided
///      key; AI never auto-posts/auto-pays/auto-applies; memory is explicit and
///      user-managed and can be deleted.
///   4. We never sell your data.        — no 3rd-party trackers/ad/analytics
///      SDKs in the app; analytics are our own, PII-free (salted HMAC id, event
///      allow-list, day buckets).
///   5. Your data, your control.        — export everything + delete your
///      account are in-app; the document vault is PIN-locked.
///   6. Data location.                  — stored on Assisto's own server; not
///      sold or handed to third parties.
///   7. Licensing/transparency note.    — conservative: we prefer permissively
///      licensed building blocks for encryption (e.g. OpenMLS, Apache/MIT); the
///      app itself is not (yet) open source — stated plainly, not overclaimed.
class TrustPageScreen extends StatelessWidget {
  const TrustPageScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    // honest accent colours (AA on both themes)
    final good = AssistoTokens.of(context).success;
    final never = scheme.error;
    return Scaffold(
      appBar: AppBar(
        title: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(t.trustTitle, maxLines: 1),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 28),
        children: [
          // ---- header / integrity statement ----
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Brand.cyan, Brand.blue],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(Radii.lg),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.verified_user, color: Colors.white, size: 36),
                const SizedBox(height: 10),
                Text(t.trustHeadline,
                    style: AType.titleLarge.copyWith(color: Colors.white, fontWeight: FontWeight.bold)),
                const SizedBox(height: Gap.sm),
                Text(t.trustIntro,
                    style: AType.titleMedium.copyWith(color: Colors.white, height: 1.4)),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // ---- WHAT WE DO (verified claims) ----
          _SectionHeader(text: t.trustWhatWeDo),
          _ClaimTile(
            icon: Icons.account_balance_wallet,
            tint: good,
            title: t.trustMoneyTitle,
            body: t.trustMoneyBody,
          ),
          _ClaimTile(
            icon: Icons.lock,
            tint: good,
            title: t.trustE2eTitle,
            body: t.trustE2eBody,
          ),
          _ClaimTile(
            icon: Icons.smart_toy,
            tint: good,
            title: t.trustAiTitle,
            body: t.trustAiBody,
          ),
          _ClaimTile(
            icon: Icons.privacy_tip,
            tint: good,
            title: t.trustSellTitle,
            body: t.trustSellBody,
          ),
          _ClaimTile(
            icon: Icons.download_done,
            tint: good,
            title: t.trustControlTitle,
            body: t.trustControlBody,
          ),
          _ClaimTile(
            icon: Icons.dns,
            tint: good,
            title: t.trustDataLocationTitle,
            body: t.trustDataLocationBody,
          ),

          const SizedBox(height: 20),

          // ---- WHAT WE DO NOT DO ----
          _SectionHeader(text: t.trustWhatWeDont),
          _NeverTile(text: t.trustNeverHoldMoney, tint: never),
          _NeverTile(text: t.trustNeverSell, tint: never),
          _NeverTile(text: t.trustNeverReadChats, tint: never),
          _NeverTile(text: t.trustNeverAutoAct, tint: never),
          _NeverTile(text: t.trustNeverTrackers, tint: never),

          const SizedBox(height: 20),

          // ---- transparency / licensing note (conservative) ----
          _SectionHeader(text: t.trustTransparency),
          Card(
            margin: EdgeInsets.zero,
            color: scheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(Gap.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.gavel, size: 22, color: scheme.onSurfaceVariant),
                    const SizedBox(width: Gap.sm),
                    Expanded(
                      child: Text(t.trustLicenseTitle,
                          style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700)),
                    ),
                  ]),
                  const SizedBox(height: Gap.sm),
                  Text(t.trustLicenseBody,
                      style: AType.bodyMedium.copyWith(height: 1.4)),
                ],
              ),
            ),
          ),

          const SizedBox(height: 20),

          // ---- links to the real policy surfaces ----
          _SectionHeader(text: t.trustReadMore),
          _LinkTile(
            icon: Icons.policy,
            label: t.trustOpenLegal,
            onTap: () => ChatNav.push(context, 'legal'),
          ),
          _LinkTile(
            icon: Icons.info_outline,
            label: t.trustOpenAbout,
            onTap: () => ChatNav.push(context, 'name_about'),
          ),

          const SizedBox(height: 18),
          Center(
            child: Text(t.trustFooter,
                textAlign: TextAlign.center,
                style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant, height: 1.4)),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader({required this.text});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10, top: Gap.xxs),
        child: Text(text,
            style: AType.titleMedium.copyWith(fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary)),
      );
}

class _ClaimTile extends StatelessWidget {
  final IconData icon;
  final Color tint;
  final String title;
  final String body;
  const _ClaimTile(
      {required this.icon, required this.tint, required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.md),
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: 44,
              width: 44,
              decoration: BoxDecoration(
                color: tint.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(Radii.md),
              ),
              child: Icon(icon, color: tint, size: 24),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: Gap.xs),
                  Text(body, style: AType.bodyMedium.copyWith(height: 1.4)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NeverTile extends StatelessWidget {
  final String text;
  final Color tint;
  const _NeverTile({required this.text, required this.tint});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.block, size: 22, color: tint),
            const SizedBox(width: Gap.md),
            Expanded(child: Text(text, style: AType.titleMedium.copyWith(height: 1.35))),
          ],
        ),
      );
}

class _LinkTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _LinkTile({required this.icon, required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.xs),
        leading: Icon(icon, color: scheme.primary),
        title: Text(label, style: AType.titleMedium.copyWith(fontWeight: FontWeight.w600)),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
