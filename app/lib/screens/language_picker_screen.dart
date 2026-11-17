import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../ds/ds.dart';
import '../theme.dart';
import '../widgets/robo_id.dart';

/// First-launch language choice. Intentionally bilingual — the user hasn't
/// picked a language yet, so every label shows both scripts. Default is Bangla.
class LanguagePickerScreen extends StatefulWidget {
  const LanguagePickerScreen({super.key});
  @override
  State<LanguagePickerScreen> createState() => _LanguagePickerScreenState();
}

class _LanguagePickerScreenState extends State<LanguagePickerScreen> {
  String _code = 'bn';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Spacer(),
            Center(
              child: Container(
                height: 72,
                width: 72,
                decoration: const BoxDecoration(
                    gradient: Brand.gradient, shape: BoxShape.circle),
                child: const Icon(Icons.psychology_alt_rounded,
                    color: Colors.white, size: 38),
              ),
            ),
            const SizedBox(height: Gap.xl),
            Text(AppLocalizations.of(context).chooseLanguage,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: Gap.xl),
            // first-run = launch path: keep it GPU-light — the two languages
            // are rows of ONE DS group (one card shadow, no per-row surface)
            DsGroup(margin: EdgeInsets.zero, children: [
              _option('bn', AppLocalizations.of(context).langPickBangla, 'Bangla'),
              _option('en', 'English', AppLocalizations.of(context).languageEnglish),
            ]),
            const Spacer(),
            // tl1: Semantics identifier = Android resource-id for Test Lab Robo.
            RoboId(id: 'tl_lang_continue',
              child: DsButton(
                expand: true,
                onPressed: () =>
                    context.read<AppState>().setLocale(Locale(_code)),
                label: _code == 'bn' ? AppLocalizations.of(context).continueWord : 'Continue',
              ),
            ),
            const SizedBox(height: Gap.xs),
            Text(
              _code == 'bn'
                  ? AppLocalizations.of(context).chooseLanguageSub
                  : 'You can change this later in Settings.',
              textAlign: TextAlign.center,
              style: AType.bodySmall.copyWith(color: scheme.ds.muted),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _option(String code, String title, String sub) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _code == code;
    return RoboId(id: 'tl_lang_$code',
      child: Semantics(
        selected: selected,
        button: true,
        child: InkWell(
          onTap: () => setState(() => _code = code),
          child: Container(
            color: selected ? scheme.ds.primarySoft : null,
            padding: const EdgeInsets.all(Gap.lg),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title,
                      style: AType.titleLarge.copyWith(fontWeight: FontWeight.w700)),
                  Text(sub, style: AType.bodySmall.copyWith(color: scheme.ds.muted)),
                ]),
              ),
              Icon(selected ? Icons.check_circle_rounded : Icons.circle_outlined,
                  color: selected ? scheme.ds.primaryInk : scheme.ds.muted),
            ]),
          ),
        ),
      ),
    );
  }
}
