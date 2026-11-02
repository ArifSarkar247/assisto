import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../account_mode.dart';
import '../api.dart' show ApiClient;
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import 'app_sheet.dart';
import 'local_digits.dart';
import 'onb_common.dart';

/// acctmode UI: the three choices (onboarding step + Settings sheet), the
/// Settings row, and the "hidden from your menu" card on a hidden area's
/// screen. See lib/account_mode.dart for the rules.

String accountModeLabel(AppLocalizations t, AccountMode m) => switch (m) {
      AccountMode.personal => t.acmPersonal,
      AccountMode.business => t.acmBusiness,
      AccountMode.both => t.acmBoth,
    };

/// The three big choice tiles.
class AccountModeChoices extends StatelessWidget {
  final AccountMode? selected;
  final ValueChanged<AccountMode> onPick;

  /// Tile badge "Matches what you use" (Settings: the server's suggestion).
  final AccountMode? suggested;

  /// Optional per-mode count line (Settings: "12 customers, 3 products").
  final String? Function(AccountMode m)? countLine;
  const AccountModeChoices(
      {super.key,
      required this.selected,
      required this.onPick,
      this.suggested,
      this.countLine});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final items = <(AccountMode, IconData, String, String)>[
      (AccountMode.personal, Icons.account_balance_wallet_rounded,
          t.acmPersonal, t.acmPersonalSub),
      (AccountMode.business, Icons.storefront_rounded, t.acmBusiness,
          t.acmBusinessSub),
      (AccountMode.both, Icons.layers_rounded, t.acmBoth, t.acmBothSub),
    ];
    return Column(children: [
      for (final it in items)
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.md),
          child: OnbChoiceTile(
            key: ValueKey('acm-${it.$1.name}'),
            icon: it.$2,
            title: it.$3,
            subtitle: [it.$4, countLine?.call(it.$1)]
                .whereType<String>()
                .where((s) => s.isNotEmpty)
                .join('\n'),
            selected: selected == it.$1,
            badge: suggested == it.$1 ? t.acmMatchesUse : null,
            onTap: () => onPick(it.$1),
          ),
        ),
    ]);
  }
}

/// Onboarding step: "What will you keep accounts for?"
class OnbAccountModeStep extends StatelessWidget {
  final AccountMode? selected;
  final ValueChanged<AccountMode> onPick;
  const OnbAccountModeStep(
      {super.key, required this.selected, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return ListView(
      key: const ValueKey('onb-acct-mode'),
      padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.lg, Gap.xl, Gap.lg),
      children: [
        OnbHeader(
          icon: Icons.account_balance_rounded,
          title: t.acmOnbTitle,
          subtitle: t.acmOnbSub,
          iconSize: 72,
        ),
        const SizedBox(height: Gap.xl),
        AccountModeChoices(selected: selected, onPick: onPick),
      ],
    );
  }
}

/// Settings -> Accounts mode row.
class AccountModeSettingsTile extends StatefulWidget {
  const AccountModeSettingsTile({super.key});
  @override
  State<AccountModeSettingsTile> createState() =>
      _AccountModeSettingsTileState();
}

class _AccountModeSettingsTileState extends State<AccountModeSettingsTile> {
  final _c = AccountModeController.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _c.refresh(context.read<AppState>().api);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        final hint = !_c.chosen &&
                _c.suggested != null &&
                _c.suggested != _c.mode
            ? '\n${t.acmTileSuggest(accountModeLabel(t, _c.suggested!))}'
            : '';
        return ListTile(
          key: const ValueKey('settings-acct-mode'),
          leading: const Icon(Icons.account_balance_rounded),
          title: Text(t.acmTitle),
          subtitle: Text(t.acmTileSub(accountModeLabel(t, _c.mode)) + hint),
          onTap: () => showAccountModeSheet(context),
        );
      },
    );
  }
}

String? _countLine(AppLocalizations t, bool bn, AccountMode m) {
  final c = AccountModeController.instance;
  String d(int v) => toLocalDigits('$v', bn);
  final p = c.personalEntries > 0 ? t.acmCountPersonal(d(c.personalEntries)) : null;
  final b = (c.businessParties > 0 || c.businessProducts > 0)
      ? t.acmCountBusiness(d(c.businessParties), d(c.businessProducts))
      : null;
  return switch (m) {
    AccountMode.personal => p,
    AccountMode.business => b,
    AccountMode.both => [p, b].whereType<String>().join(' · '),
  };
}

/// The warning line when [m] would hide an area that holds entries.
String? accountModeWarning(AppLocalizations t, bool bn, AccountMode m) {
  final c = AccountModeController.instance;
  final hidden = accountModeHiddenWithData(m, c.usage);
  if (hidden.isEmpty) return null;
  final what = hidden
      .map((a) => _countLine(t, bn,
          a == AcctArea.personal ? AccountMode.personal : AccountMode.business))
      .whereType<String>()
      .join(' · ');
  return t.acmWarnHide(what);
}

/// The mode picker sheet (Settings row, and "Show in menu again").
Future<void> showAccountModeSheet(BuildContext context) {
  final api = context.read<AppState>().api;
  AccountModeController.instance.refresh(api);
  return showAppSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => AccountModeSheet(api: api),
  );
}

class AccountModeSheet extends StatefulWidget {
  final ApiClient api;
  const AccountModeSheet({super.key, required this.api});
  @override
  State<AccountModeSheet> createState() => _AccountModeSheetState();
}

class _AccountModeSheetState extends State<AccountModeSheet> {
  final _c = AccountModeController.instance;
  late AccountMode _sel = _c.mode;
  bool _saving = false;

  Future<void> _save(AppLocalizations t) async {
    setState(() => _saving = true);
    final msg = ScaffoldMessenger.maybeOf(context);
    final ok = await _c.set(_sel, api: widget.api);
    if (!mounted) return;
    Navigator.pop(context);
    msg?.showSnackBar(
        SnackBar(content: Text(ok ? t.acmSaved : t.acmSavedOffline)));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        final t = AppLocalizations.of(context);
        final bn = Localizations.localeOf(context).languageCode == 'bn';
        final scheme = Theme.of(context).colorScheme;
        final warn = accountModeWarning(t, bn, _sel);
        return SafeArea(
          child: SingleChildScrollView(
            key: const ValueKey('acm-sheet'),
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.lg),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(t.acmTitle,
                      style: AType.titleLarge
                          .copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: Gap.xs),
                  Text(t.acmSafeNote,
                      style: AType.bodyMedium
                          .copyWith(color: scheme.onSurfaceVariant)),
                  const SizedBox(height: Gap.lg),
                  AccountModeChoices(
                    selected: _sel,
                    suggested: _c.chosen ? null : _c.suggested,
                    countLine: (m) => _countLine(t, bn, m),
                    onPick: (m) => setState(() => _sel = m),
                  ),
                  if (warn != null)
                    Container(
                      key: const ValueKey('acm-warn'),
                      margin: const EdgeInsets.only(bottom: Gap.md),
                      padding: const EdgeInsets.all(Gap.md),
                      decoration: BoxDecoration(
                        color: scheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(Radii.md),
                      ),
                      child: Row(children: [
                        Icon(Icons.lock_outline_rounded,
                            color: scheme.onSecondaryContainer),
                        const SizedBox(width: Gap.sm),
                        Expanded(
                            child: Text(warn,
                                style: AType.bodyMedium.copyWith(
                                    color: scheme.onSecondaryContainer))),
                      ]),
                    ),
                  FilledButton(
                    key: const ValueKey('acm-save'),
                    style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(50)),
                    onPressed: _saving ? null : () => _save(t),
                    child: Text(t.save),
                  ),
                ]),
          ),
        );
      },
    );
  }
}

/// Top card on a screen whose area the current mode hides from the menu
/// (reached via search, chat or a link). One tap -> "both" again.
class AccountModeHiddenCard extends StatelessWidget {
  final AcctArea area;
  const AccountModeHiddenCard({super.key, required this.area});

  @override
  Widget build(BuildContext context) {
    final c = AccountModeController.instance;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        if (c.shows(area)) return const SizedBox.shrink();
        final t = AppLocalizations.of(context);
        final scheme = Theme.of(context).colorScheme;
        return Card(
          key: ValueKey('acm-hidden-${area.name}'),
          color: scheme.secondaryContainer,
          margin: const EdgeInsets.only(bottom: Gap.md),
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(Icons.visibility_off_rounded,
                        color: scheme.onSecondaryContainer),
                    const SizedBox(width: Gap.sm),
                    Expanded(
                      child: Text(
                          area == AcctArea.personal
                              ? t.acmHiddenPersonal
                              : t.acmHiddenBusiness,
                          style: AType.bodyMedium
                              .copyWith(color: scheme.onSecondaryContainer)),
                    ),
                  ]),
                  const SizedBox(height: Gap.sm),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: FilledButton.tonal(
                      key: const ValueKey('acm-show-again'),
                      style: FilledButton.styleFrom(
                          minimumSize: const Size(48, 48)),
                      onPressed: () async {
                        final ok = await c.set(AccountMode.both,
                            api: context.read<AppState>().api,
                            source: 'show_again');
                        if (!context.mounted) return;
                        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                            SnackBar(
                                content: Text(
                                    ok ? t.acmSaved : t.acmSavedOffline)));
                      },
                      child: Text(t.acmShowAgain),
                    ),
                  ),
                ]),
          ),
        );
      },
    );
  }
}
