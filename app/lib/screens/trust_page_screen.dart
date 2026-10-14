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

  // honest accent colours (high contrast on both themes)
  static const Color _good = Color(0xFF1B5E20);
  static const Color _never = Color(0xFFB71C1C);

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(t.trustTitle, maxLines: 1),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
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
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.verified_user, color: Colors.white, size: 36),
                const SizedBox(height: 10),
                Text(t.trustHeadline,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text(t.trustIntro,
                    style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.4)),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // ---- WHAT WE DO (verified claims) ----
          _SectionHeader(text: t.trustWhatWeDo),
          _ClaimTile(
            icon: Icons.account_balance_wallet,
            tint: _good,
            title: t.trustMoneyTitle,
            body: t.trustMoneyBody,
          ),
          _ClaimTile(
            icon: Icons.lock,
            tint: _good,
            title: t.trustE2eTitle,
            body: t.trustE2eBody,
          ),
          _ClaimTile(
            icon: Icons.smart_toy,
            tint: _good,
            title: t.trustAiTitle,
            body: t.trustAiBody,
          ),
          _ClaimTile(
            icon: Icons.privacy_tip,
            tint: _good,
            title: t.trustSellTitle,
            body: t.trustSellBody,
          ),
          _ClaimTile(
            icon: Icons.download_done,
            tint: _good,
            title: t.trustControlTitle,
            body: t.trustControlBody,
          ),
          _ClaimTile(
            icon: Icons.dns,
            tint: _good,
            title: t.trustDataLocationTitle,
            body: t.trustDataLocationBody,
          ),

          const SizedBox(height: 20),

          // ---- WHAT WE DO NOT DO ----
          _SectionHeader(text: t.trustWhatWeDont),
          _NeverTile(text: t.trustNeverHoldMoney, tint: _never),
          _NeverTile(text: t.trustNeverSell, tint: _never),
          _NeverTile(text: t.trustNeverReadChats, tint: _never),
          _NeverTile(text: t.trustNeverAutoAct, tint: _never),
          _NeverTile(text: t.trustNeverTrackers, tint: _never),

          const SizedBox(height: 20),

          // ---- transparency / licensing note (conservative) ----
          _SectionHeader(text: t.trustTransparency),
          Card(
            margin: EdgeInsets.zero,
            color: scheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.gavel, size: 22, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(t.trustLicenseTitle,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700)),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  Text(t.trustLicenseBody,
                      style: const TextStyle(fontSize: 14, height: 1.4)),
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
                style: TextStyle(
                    fontSize: 13, color: scheme.onSurfaceVariant, height: 1.4)),
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
        padding: const EdgeInsets.only(bottom: 10, top: 2),
        child: Text(text,
            style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.primary)),
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
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: 44,
              width: 44,
              decoration: BoxDecoration(
                color: tint.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: tint, size: 24),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(body, style: const TextStyle(fontSize: 14, height: 1.4)),
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
            const SizedBox(width: 12),
            Expanded(child: Text(text, style: const TextStyle(fontSize: 15, height: 1.35))),
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
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: Icon(icon, color: scheme.primary),
        title: Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
