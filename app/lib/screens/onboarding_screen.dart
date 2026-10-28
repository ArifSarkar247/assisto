import '../voice/va_onboarding_step.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/onb_common.dart';
import '../widgets/onb_role.dart';
import '../widgets/elderly_mode.dart' show EldersModeController; // famcare
import '../widgets/onb_first_win.dart';
import '../widgets/onb_permissions.dart';
import '../widgets/onb_link_parent.dart';
import 'family_screen.dart';
import 'money_screen.dart';
import 'vault_screen.dart';
import 'journey_start_screen.dart';
import 'business/khata_entry_screen.dart';
import '../widgets/robo_id.dart';
import 'offers_screens.dart' show OnbOffersStep; // p2-money

/// First-run ADVANCED onboarding — a <60s "wow" that teaches the main features
/// through a quick interactive flow (SPEC v2.1 §21).
///
/// FLOW (skippable + resumable, with progress dots):
///   0. Welcome + LANGUAGE   — pick bn/en up front (sets the app locale).
///   1. WHO ARE YOU          — self / elderly parent / family / business.
///   2. PERMISSIONS, HONESTLY— every permission + exactly WHY (nothing granted).
///   3. FIRST WIN            — one REAL task, recommended per role (medicine /
///                             scan a bill / safe-journey / expense). Tapping a
///                             tile opens the live screen, so value is genuine.
///   4. LINK A PARENT        — phone + relation → invite by call / SMS (own-SIM)
///                             / QR. IVR for feature phones is 🔑 key-gated and
///                             shown honestly as "Available when ___".
///
/// RESUMABLE: the current step index is persisted; on relaunch (before the user
/// finished) we offer "Continue vs Start over". FINISH or SKIP sets `onboarded`
/// so it shows once.
///
/// Strict per-page language; ZERO Bangla in this file (all via AppLocalizations).
class OnboardingScreen extends StatefulWidget {
  final VoidCallback onDone;

  /// Whether the owner has connected an IVR/voice-call provider. The integrator
  /// wires this from the live integrations status (see up_onb_integration note);
  /// default false keeps the honest key-gated state.
  final bool ivrEnabled;
  const OnboardingScreen({super.key, required this.onDone, this.ivrEnabled = false});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  static const _resumeKey = 'onb_step';
  // welcome+lang, who, perms, assistant (Part 3), offers (p2-money,
  // optional), first-win, link-parent
  static const _steps = 7;

  final _pc = PageController();
  int _page = 0;
  OnbRole? _role;
  bool _checkedResume = false;

  @override
  void initState() {
    super.initState();
    _maybeResume();
  }

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  /// If a previous run saved a step past the first, offer to continue there.
  Future<void> _maybeResume() async {
    final saved = int.tryParse(await Settings.getString(_resumeKey) ?? '') ?? 0;
    if (!mounted) return;
    setState(() => _checkedResume = true);
    if (saved <= 0 || saved >= _steps) return;
    final t = AppLocalizations.of(context);
    final resume = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        title: Text(t.onbResumeTitle),
        content: Text(t.onbResumeBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.onbResumeRestart)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.onbResumeContinue)),
        ],
      ),
    );
    if (resume == true && mounted) {
      _go(saved);
    } else {
      await Settings.setString(_resumeKey, '0');
    }
  }

  void _go(int page) {
    setState(() => _page = page);
    _pc.jumpToPage(page);
    Settings.setString(_resumeKey, '$page');
  }

  Future<void> _next() async {
    final n = (_page + 1).clamp(0, _steps - 1);
    await Settings.setString(_resumeKey, '$n');
    _pc.nextPage(duration: Motion.base, curve: Curves.easeOut);
  }

  // famcare (owner decision 6): the elderly simple home, chosen at setup.
  bool _simpleHome = false;

  Future<void> _setSimpleHome(bool on) async {
    if (on && _role == OnbRole.parent &&
        !await EldersModeController.confirmParentPermission(context)) {
      return; // setting it up for a parent needs their permission first
    }
    if (mounted) setState(() => _simpleHome = on);
  }

  Future<void> _finish() async {
    if (_simpleHome) await EldersModeController.set(context, true);
    await Settings.setBool('onboarded', true);
    await Settings.setString(_resumeKey, '0');
    if (mounted) context.read<AppState>().markOnboarded();
    widget.onDone();
  }

  /// Mark onboarded, then open a real screen so the win is genuine (not a demo).
  Future<void> _open(Widget screen) async {
    await _finish();
    if (mounted) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
    }
  }

  void _openWin(OnbWin win) {
    final screen = switch (win) {
      OnbWin.medicine => const FamilyScreen(),
      OnbWin.bill => const VaultScreen(),
      OnbWin.journey => const JourneyStartScreen(),
      OnbWin.expense => const MoneyScreen(),
      OnbWin.ledger => const KhataEntryScreen(),
    };
    _open(screen);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;

    // Loading state while we read the resume flag (avoids a flash of page 0).
    if (!_checkedResume) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Align(
            alignment: AlignmentDirectional.topEnd,
            child: Padding(
              padding: const EdgeInsetsDirectional.only(end: Gap.sm, top: Gap.xs),
              child: RoboId(id: 'tl_onb_skip',
                  child: TextButton(onPressed: _finish, child: Text(t.skip))),
            ),
          ),
          Expanded(
            child: PageView(
              controller: _pc,
              onPageChanged: (i) {
                setState(() => _page = i);
                Settings.setString(_resumeKey, '$i');
              },
              children: [
                _welcomeLang(t, scheme),
                OnbRoleStep(
                    selected: _role,
                    onPick: (r) => setState(() => _role = r),
                    simpleHome: _simpleHome,
                    onSimpleHome: _setSimpleHome),
                const OnbPermissions(),
                // Part 3: set Assisto as the default digital assistant.
                const VaOnboardingStep(),
                // p2-money: optional — pick offer categories or just Next
                const OnbOffersStep(),
                OnbFirstWin(role: _role, onPick: _openWin),
                OnbLinkParent(
                  ivrEnabled: widget.ivrEnabled,
                  onOpenFamily: () => _open(const FamilyScreen()),
                  onSkip: _finish,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.sm),
            child: Text(t.onbProgressStep(_page + 1, _steps),
                style: AType.labelSmall.copyWith(color: scheme.onSurfaceVariant)),
          ),
          OnbDots(count: _steps, index: _page),
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
    // First-win and link-parent steps carry their own CTAs, so the footer there
    // just offers "start chatting". Earlier steps advance with Next; the role
    // step requires a pick before Next lights up.
    // (page 3 = the Part 3 assistant step: plain Next, it is optional)
    if (_page == 5) {
      return TextButton(onPressed: _next, child: Text(t.onbMaybeLater));
    }
    if (_page == 6) {
      return TextButton(onPressed: _finish, child: Text(t.justStartChatting));
    }
    final canNext = _page != 1 || _role != null;
    return FilledButton(
      onPressed: canNext ? _next : null,
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
      child: Text(t.next),
    );
  }

  // ---- Step 0: welcome + language (strict language switch up front) ----
  Widget _welcomeLang(AppLocalizations t, ColorScheme scheme) {
    final app = context.watch<AppState>();
    final current = app.locale?.languageCode;
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.lg, Gap.xl, Gap.lg),
      children: [
        OnbHeader(
          icon: Icons.auto_awesome_rounded,
          title: t.onbWelcomeTitle,
          subtitle: t.onbWelcomeSub,
        ),
        const SizedBox(height: Gap.xl),
        Text(t.onbLangStepTitle,
            style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.xs),
        Text(t.onbLangStepSub,
            style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.md),
        _langTile(scheme, 'bn', t.languageBangla, current == 'bn'),
        const SizedBox(height: Gap.sm),
        _langTile(scheme, 'en', t.languageEnglish, current == 'en'),
      ],
    );
  }

  Widget _langTile(
      ColorScheme scheme, String code, String label, bool selected) {
    // QA a6: the subtitle used to repeat "Choose your language" on both
    // tiles. Now: title = the language's OWN name (always readable by its
    // speakers), subtitle = its name in the current UI language.
    final native = lookupAppLocalizations(Locale(code));
    final nativeName =
        code == 'bn' ? native.languageBangla : native.languageEnglish;
    return OnbChoiceTile(
      icon: Icons.translate_rounded,
      title: nativeName,
      subtitle: label == nativeName ? '' : label,
      selected: selected,
      onTap: () => context.read<AppState>().setLocale(Locale(code)),
    );
  }
}
