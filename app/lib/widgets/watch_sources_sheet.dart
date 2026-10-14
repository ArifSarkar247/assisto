import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'watch_item.dart';

/// Localized label for a source.
String watchSourceLabel(AppLocalizations t, WatchSource s) {
  switch (s) {
    case WatchSource.reminders:
      return t.watchSourceReminders;
    case WatchSource.medicine:
      return t.watchSourceMedicine;
    case WatchSource.money:
      return t.watchSourceMoney;
    case WatchSource.subscriptions:
      return t.watchSourceSubscriptions;
    case WatchSource.birthdays:
      return t.watchSourceBirthdays;
    case WatchSource.safety:
      return t.watchSourceSafety;
    case WatchSource.family:
      return t.watchSourceFamily;
    case WatchSource.watchers:
      return t.watchSourceWatchers;
  }
}

IconData watchSourceIcon(WatchSource s) {
  switch (s) {
    case WatchSource.reminders:
      return Icons.alarm_outlined;
    case WatchSource.medicine:
      return Icons.medication_outlined;
    case WatchSource.money:
      return Icons.account_balance_wallet_outlined;
    case WatchSource.subscriptions:
      return Icons.autorenew_outlined;
    case WatchSource.birthdays:
      return Icons.cake_outlined;
    case WatchSource.safety:
      return Icons.directions_walk_outlined;
    case WatchSource.family:
      return Icons.family_restroom_outlined;
    case WatchSource.watchers:
      return Icons.trending_up_outlined;
  }
}

/// Bottom sheet letting the user choose which sources feed the Watch screen.
/// Pure UI: takes the current enabled set, returns the new set on change.
class WatchSourcesSheet extends StatefulWidget {
  final Set<WatchSource> enabled;
  final ValueChanged<Set<WatchSource>> onChanged;
  const WatchSourcesSheet(
      {super.key, required this.enabled, required this.onChanged});

  @override
  State<WatchSourcesSheet> createState() => _WatchSourcesSheetState();
}

class _WatchSourcesSheetState extends State<WatchSourcesSheet> {
  late Set<WatchSource> _on = {...widget.enabled};

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.watchSourcesTitle,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: Gap.xs),
            Text(t.watchSourcesHint,
                style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: Gap.md),
            for (final s in WatchSource.values)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: Icon(watchSourceIcon(s)),
                title: Text(watchSourceLabel(t, s)),
                subtitle: Text(
                    _on.contains(s) ? t.watchSourceOn : t.watchSourceOff,
                    style: TextStyle(color: scheme.onSurfaceVariant)),
                value: _on.contains(s),
                onChanged: (v) {
                  setState(() {
                    if (v) {
                      _on.add(s);
                    } else {
                      _on.remove(s);
                    }
                  });
                  widget.onChanged({..._on});
                },
              ),
          ],
        ),
      ),
    );
  }
}
