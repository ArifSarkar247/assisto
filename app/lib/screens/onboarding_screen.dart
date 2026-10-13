import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../l10n/app_localizations.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';
import 'family_screen.dart';
import 'money_screen.dart';
import 'vault_screen.dart';

/// First-run onboarding — the "why install" surface.
///
/// Benchmarked against fast-"aha" onboarding (Duolingo / Notion): skippable,
/// bilingual, three steps:
///   1. Three quick value slides (what Assisto does).
///   2. "Pick one thing to try now" — a real win in under 60s (add a parent's
///      medicine / scan a bill / log an expense). Tapping jumps straight into
///      the real screen, so value is immediate, not simulated.
///   3. "Link a parent in under 2 minutes" — enter a phone, then invite by
///      call / SMS / copy-link (QR-ready). IVR for feature phones is key-gated
///      with a clean "Available when ___" state.
///
/// `onboarded` flag is set when the user finishes OR skips, so it shows once.
class OnboardingScreen extends StatefulWidget {
  final VoidCallback onDone;
  const OnboardingScreen({super.key, required this.onDone});
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pc = PageController();
  int _page = 0;

  // Total pages = 3 intro slides + 1 "try now" + 1 "link a parent".
  static const _intro = 3;
  static const _pages = _intro + 2;

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    await Settings.setBool('onboarded', true);
    widget.onDone();
  }

  void _next() =>
      _pc.nextPage(duration: Motion.base, curve: Curves.easeOut);

  /// Mark onboarded, then open a real screen so the win is genuine.
  Future<void> _open(Widget screen) async {
    await _finish();
    if (mounted) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Align(
            alignment: Alignment.topRight,
            child: TextButton(onPressed: _finish, child: Text(t.skip)),
          ),
          Expanded(
            child: PageView(
              controller: _pc,
              onPageChanged: (i) => setState(() => _page = i),
              children: [
                _introSlide(t, scheme, Icons.chat_bubble_outline,
                    t.justTellMe, t.n500TakaFoodExpenseRemind),
                _introSlide(t, scheme, Icons.diversity_1_outlined,
                    t.careForFamily, t.parentsMedicinesSchoolEmergenciesAll),
                _introSlide(t, scheme, Icons.lock_outline,
                    t.youStayInControl, t.dataIsNeverSoldIt),
                _tryNow(t, scheme),
                _linkParent(t, scheme),
              ],
            ),
          ),
          _dots(scheme),
          const SizedBox(height: Gap.lg),
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.lg),
            child: _footer(t),
          ),
        ]),
      ),
    );
  }

  Widget _footer(AppLocalizations t) {
    // Intro slides -> Next. Try-now and link-parent screens carry their own
    // CTAs, so the footer just offers "continue / finish".
    if (_page < _intro) {
      return FilledButton(
        onPressed: _next,
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
        child: Text(t.next),
      );
    }
    if (_page == _intro) {
      return TextButton(onPressed: _next, child: Text(t.onbMaybeLater));
    }
    return TextButton(onPressed: _finish, child: Text(t.justStartChatting));
  }

  Widget _dots(ColorScheme scheme) =>
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        for (int i = 0; i < _pages; i++)
          AnimatedContainer(
            duration: Motion.fast,
            margin: const EdgeInsets.all(3),
            height: 8,
            width: _page == i ? 22 : 8,
            decoration: BoxDecoration(
              color: _page == i ? scheme.primary : scheme.outlineVariant,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
      ]);

  Widget _introSlide(AppLocalizations t, ColorScheme scheme, IconData icon,
      String title, String body) {
    return Padding(
      padding: const EdgeInsets.all(Gap.xxl),
      child:
          Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Container(
          height: 96,
          width: 96,
          decoration:
              const BoxDecoration(gradient: Brand.gradient, shape: BoxShape.circle),
          child: Icon(icon, size: 46, color: Colors.white),
        ),
        const SizedBox(height: Gap.xl),
        Text(title,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: Gap.md),
        Text(body,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.5)),
      ]),
    );
  }

  // ---- Step: try one real thing now (the <60s "wow") ----
  Widget _tryNow(AppLocalizations t, ColorScheme scheme) {
    final actions = <(IconData, String, String, Widget)>[
      (
        Icons.medication_outlined,
        t.onbTryMedicineTitle,
        t.onbTryMedicineSub,
        const FamilyScreen()
      ),
      (
        Icons.receipt_long_outlined,
        t.onbTryBillTitle,
        t.onbTryBillSub,
        const VaultScreen()
      ),
      (
        Icons.payments_outlined,
        t.onbTryExpenseTitle,
        t.onbTryExpenseSub,
        const MoneyScreen()
      ),
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.lg, Gap.xl, Gap.lg),
      children: [
        Text(t.onbTryNowTitle,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: Gap.xs),
        Text(t.onbTryNowSub,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
        const SizedBox(height: Gap.xl),
        for (final a in actions)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.md),
            child: _actionTile(scheme, a.$1, a.$2, a.$3, () => _open(a.$4)),
          ),
      ],
    );
  }

  Widget _actionTile(ColorScheme scheme, IconData icon, String title,
      String sub, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Radii.md),
      child: Container(
        padding: const EdgeInsets.all(Gap.lg),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(children: [
          Container(
            height: 44,
            width: 44,
            decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(Radii.sm)),
            child: Icon(icon, color: scheme.onPrimaryContainer),
          ),
          const SizedBox(width: Gap.md),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(sub,
                  style:
                      TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            ]),
          ),
          Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
        ]),
      ),
    );
  }

  // ---- Step: link a parent in under 2 minutes ----
  Widget _linkParent(AppLocalizations t, ColorScheme scheme) =>
      _LinkParentStep(onOpenFamily: () => _open(const FamilyScreen()));
}

/// Enter a parent's phone, then invite them by call / SMS / copy-link. IVR for
/// feature phones is key-gated ("Available when ___"). Kept stateful + separate
/// so the phone field has its own controller lifecycle.
class _LinkParentStep extends StatefulWidget {
  final VoidCallback onOpenFamily;
  const _LinkParentStep({required this.onOpenFamily});
  @override
  State<_LinkParentStep> createState() => _LinkParentStepState();
}

class _LinkParentStepState extends State<_LinkParentStep> {
  final _phone = TextEditingController();
  bool get _hasPhone => _phone.text.trim().length >= 6;

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  String get _number => _phone.text.trim().replaceAll(' ', '');

  String _invite(AppLocalizations t) => t.onbInviteMessage;

  Future<void> _tel() async {
    final uri = Uri.parse('tel:$_number');
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  Future<void> _sms(AppLocalizations t) async {
    final uri =
        Uri.parse('sms:$_number?body=${Uri.encodeComponent(_invite(t))}');
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  Future<void> _copy(AppLocalizations t) async {
    await Clipboard.setData(ClipboardData(text: _invite(t)));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.onbInviteCopied)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.lg, Gap.xl, Gap.lg),
      children: [
        Icon(Icons.favorite, size: 40, color: scheme.primary),
        const SizedBox(height: Gap.sm),
        Text(t.onbLinkParentTitle,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: Gap.xs),
        Text(t.onbLinkParentSub,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
        const SizedBox(height: Gap.xl),
        TextField(
          controller: _phone,
          keyboardType: TextInputType.phone,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: t.onbParentPhoneLabel,
            prefixIcon: const Icon(Icons.phone_outlined),
          ),
        ),
        const SizedBox(height: Gap.lg),
        Row(children: [
          Expanded(
            child: _inviteBtn(scheme, Icons.call_outlined, t.onbInviteCall,
                _hasPhone ? _tel : null),
          ),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: _inviteBtn(scheme, Icons.sms_outlined, t.onbInviteSms,
                _hasPhone ? () => _sms(t) : null),
          ),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: _inviteBtn(scheme, Icons.link_outlined, t.onbInviteCopy,
                () => _copy(t)),
          ),
        ]),
        const SizedBox(height: Gap.lg),
        // QR invite (ready; renders the same invite text as a scannable code
        // once the invite-link endpoint is live). Shown as a gated affordance.
        _gatedRow(scheme, Icons.qr_code_2_outlined, t.onbInviteQr,
            t.onbAvailableWhenInvites),
        const SizedBox(height: Gap.sm),
        // IVR call for feature phones — key-gated.
        _gatedRow(scheme, Icons.phone_in_talk_outlined, t.onbInviteIvr,
            t.onbAvailableWhenIvr),
        const SizedBox(height: Gap.xl),
        FilledButton.icon(
          onPressed: widget.onOpenFamily,
          icon: const Icon(Icons.diversity_1_outlined),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
          label: Text(t.onbManageFamily),
        ),
      ],
    );
  }

  Widget _inviteBtn(
      ColorScheme scheme, IconData icon, String label, VoidCallback? onTap) {
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: Gap.md),
        minimumSize: const Size.fromHeight(64),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 20),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(fontSize: 12)),
      ]),
    );
  }

  /// A "coming soon" affordance with a clean "Available when ___" explanation.
  Widget _gatedRow(
      ColorScheme scheme, IconData icon, String label, String whenText) {
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(children: [
        Icon(icon, size: 20, color: scheme.onSurfaceVariant),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(whenText,
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          ]),
        ),
        Icon(Icons.lock_clock_outlined,
            size: 18, color: scheme.onSurfaceVariant),
      ]),
    );
  }
}
