import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'package:assisto/widgets/app_sheet.dart';

/// ledger100 — the written "digital khata free forever" promise. Only what
/// is TRUE (backend core/tests_ledger100 FreeForeverTests: no plan gate and
/// no credit on any core khata call). The paid part — an SMS that Assisto
/// sends, AI extras — is said in the same place, plainly.
class KhataFreePromise extends StatelessWidget {
  const KhataFreePromise({super.key});

  static Future<void> showDetails(BuildContext context) {
    return showAppSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const SafeArea(child: KhataFreePromiseDetails()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      key: const ValueKey('ldg-free-promise'),
      margin: EdgeInsets.zero,
      child: ListTile(
        minVerticalPadding: Gap.md,
        leading: Icon(Icons.verified_rounded,
            color: AssistoTokens.of(context).success),
        title: Text(t.ldgFreeTitle,
            style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(t.ldgFreeSub,
            style: TextStyle(color: scheme.onSurfaceVariant)),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => showDetails(context),
      ),
    );
  }
}

class KhataFreePromiseDetails extends StatelessWidget {
  const KhataFreePromiseDetails({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    Widget line(IconData i, String s, Color c) => Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.xs),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(i, size: 20, color: c),
            const SizedBox(width: Gap.sm),
            Expanded(child: Text(s)),
          ]),
        );
    final ok = AssistoTokens.of(context).success;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t.ldgFreeTitle, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: Gap.sm),
        Text(t.ldgFreeSub, style: TextStyle(color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.md),
        for (final s in [
          t.ldgFreeL1,
          t.ldgFreeL2,
          t.ldgFreeL3,
          t.ldgFreeL4,
          t.ldgFreeL5
        ])
          line(Icons.check_circle_rounded, s, ok),
        const SizedBox(height: Gap.md),
        Text(t.ldgFreePaidTitle, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: Gap.xs),
        line(Icons.sms_outlined, t.ldgFreePaidSms, scheme.onSurfaceVariant),
        line(Icons.auto_awesome_outlined, t.ldgFreePaidAi, scheme.onSurfaceVariant),
        const SizedBox(height: Gap.md),
        Text(t.ldgFreeWeb, style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
      ]),
    );
  }
}
