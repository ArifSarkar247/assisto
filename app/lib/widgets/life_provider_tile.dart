import 'package:flutter/material.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';

/// A ride/food provider row that deep-links out to the provider's own app.
/// We never show prices/availability here — only an "open in app" action.
class LifeProviderTile extends StatelessWidget {
  final IconData icon;
  final String name;
  final String subtitle;
  final VoidCallback onOpen;
  const LifeProviderTile({
    super.key,
    required this.icon,
    required this.name,
    required this.subtitle,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Brand.blue.withOpacity(0.12),
          child: Icon(icon, color: Brand.blue),
        ),
        title: Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle),
        trailing: FilledButton.tonalIcon(
          icon: const Icon(Icons.open_in_new, size: 16),
          label: Text(t.rideFoodOpen),
          onPressed: onOpen,
        ),
        onTap: onOpen,
      ),
    );
  }
}
