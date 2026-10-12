import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import 'money_screen.dart';
import 'vault_screen.dart';
import 'family_screen.dart';
import 'emergency_screen.dart';
import 'reminders_screen.dart';
import 'notes_todos_screen.dart';
import 'memory_screen.dart';
import 'subscriptions_screen.dart';
import 'settings_screen.dart';
import 'in_progress_screen.dart';

/// Left sidebar — the app's navigation hub (modern AI-chat style). The main
/// screen is only the chat; everything else lives here.
class AppDrawer extends StatelessWidget {
  final VoidCallback onNewChat;
  const AppDrawer({super.key, required this.onNewChat});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final app = context.watch<AppState>();
    final u = app.user;

    final modules = <(IconData, String, Widget)>[
      (Icons.account_balance_wallet_outlined, t.moduleMoney, const MoneyScreen()),
      (Icons.lock_outline, t.moduleVault, const VaultScreen()),
      (Icons.diversity_1_outlined, t.moduleFamily, const FamilyScreen()),
      (Icons.emergency_outlined, t.moduleEmergency, const EmergencyScreen()),
      (Icons.alarm_outlined, t.navReminders, const RemindersScreen()),
      (Icons.checklist_outlined, t.navNotesTasks, const NotesTodosScreen()),
      (Icons.psychology_outlined, t.navMemory, const MemoryScreen()),
      (Icons.autorenew, t.subscriptions, const SubscriptionsScreen()),
      (Icons.hub_outlined, t.connectedApps, const SourcesScreen()),
      (Icons.pending_actions_outlined, t.inProgress, const InProgressScreen()),
    ];

    return Drawer(
      child: Column(children: [
        // ---- brand header ----
        Container(
          width: double.infinity,
          decoration: const BoxDecoration(gradient: Brand.heroDark),
          padding: EdgeInsets.fromLTRB(
              Gap.lg, MediaQuery.of(context).padding.top + Gap.lg, Gap.lg, Gap.lg),
          child: Row(children: [
            _logoMark(44),
            const SizedBox(width: Gap.md),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Assisto',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w800)),
              Text(t.tagline,
                  style: const TextStyle(color: Colors.white70, fontSize: 11)),
            ]),
          ]),
        ),
        const SizedBox(height: Gap.sm),
        // ---- new chat ----
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.md),
          child: FilledButton.tonalIcon(
            onPressed: () {
              Navigator.pop(context);
              onNewChat();
            },
            icon: const Icon(Icons.add_comment_outlined, size: 20),
            label: Row(children: [Text(t.newChat), const Spacer()]),
            style: FilledButton.styleFrom(
              alignment: Alignment.centerLeft,
              minimumSize: const Size.fromHeight(46),
            ),
          ),
        ),
        const SizedBox(height: Gap.xs),
        const Divider(height: Gap.lg),
        // ---- modules ----
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: Gap.xs),
            children: [
              for (final m in modules)
                ListTile(
                  leading: Icon(m.$1, color: scheme.onSurfaceVariant),
                  title: Text(m.$2),
                  visualDensity: VisualDensity.compact,
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(context,
                        MaterialPageRoute(builder: (_) => m.$3));
                  },
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        // ---- settings + profile ----
        ListTile(
          leading: Icon(Icons.settings_outlined, color: scheme.onSurfaceVariant),
          title: Text(t.settingsTitle),
          onTap: () {
            Navigator.pop(context);
            Navigator.push(context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()));
          },
        ),
        ListTile(
          leading: CircleAvatar(
            radius: 16,
            backgroundColor: scheme.primaryContainer,
            child: Text(
              (u?.name.isNotEmpty == true ? u!.name[0] : 'A').toUpperCase(),
              style: TextStyle(
                  color: scheme.onPrimaryContainer, fontWeight: FontWeight.w700),
            ),
          ),
          title: Text(u?.name.isNotEmpty == true ? u!.name : 'Assisto',
              maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            [u?.phone, u?.email].where((e) => e != null && e!.isNotEmpty).join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        SizedBox(height: MediaQuery.of(context).padding.bottom + Gap.sm),
      ]),
    );
  }

  Widget _logoMark(double size) => ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.24),
        child: Image.asset('assets/branding/new_logo.png',
            width: size, height: size, fit: BoxFit.cover),
      );
}
