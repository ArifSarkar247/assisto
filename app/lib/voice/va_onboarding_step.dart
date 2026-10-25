import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'va_native.dart';

/// Onboarding page (Part 3): guide the user to make Assisto the phone's
/// default digital assistant, so long-press power / home opens Assisto Voice.
/// Optional — "Next" / "Skip" move on; nothing is changed without the user.
class VaOnboardingStep extends StatefulWidget {
  const VaOnboardingStep({super.key});
  @override
  State<VaOnboardingStep> createState() => _VaOnboardingStepState();
}

class _VaOnboardingStepState extends State<VaOnboardingStep>
    with WidgetsBindingObserver {
  bool? _isDefault;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    final v = await VaNative.isDefaultAssistant();
    if (mounted) setState(() => _isDefault = v);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    Widget step(int n, String text) => Padding(
          padding: const EdgeInsets.only(bottom: Gap.sm),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CircleAvatar(
                radius: 12,
                backgroundColor: scheme.primaryContainer,
                child: Text('$n',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: scheme.onPrimaryContainer))),
            const SizedBox(width: Gap.sm),
            Expanded(child: Text(text)),
          ]),
        );
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.lg, Gap.xl, Gap.lg),
      children: [
        Center(
          child: ShaderMask(
            shaderCallback: (r) => Brand.gradient.createShader(r),
            child: const Icon(Icons.graphic_eq_rounded, size: 48, color: Colors.white),
          ),
        ),
        const SizedBox(height: Gap.sm),
        Text(t.vaOnbTitle,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: Gap.xs),
        Text(t.vaOnbBody,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
        const SizedBox(height: Gap.xl),
        step(1, t.vaDefStep1),
        step(2, t.vaDefStep2),
        step(3, t.vaDefStep3),
        const SizedBox(height: Gap.sm),
        Text('${t.vaDefColorOs}\n\n${t.vaDefPowerNote}',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
        const SizedBox(height: Gap.lg),
        if (_isDefault == true)
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.check_circle_rounded, color: Brand.success),
            const SizedBox(width: Gap.sm),
            Flexible(child: Text(t.vaDefIsDefault)),
          ])
        else
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: () async {
              final ok = await VaNative.openAssistantSettings();
              if (!ok && context.mounted) {
                ScaffoldMessenger.maybeOf(context)
                    ?.showSnackBar(SnackBar(content: Text(t.vaSettingsOpenFailed)));
              }
            },
            icon: const Icon(Icons.assistant_rounded),
            label: Text(t.vaDefOpenSettings),
          ),
        const SizedBox(height: Gap.sm),
        Text(t.vaOnbLater,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
      ],
    );
  }
}
