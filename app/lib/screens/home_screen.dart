import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../updater.dart';
import 'memory_screen.dart';
import 'settings_screen.dart';
import 'reminders_screen.dart';
import 'notes_todos_screen.dart';
import 'vault_screen.dart';
import 'emergency_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final pages = const [
      _Dashboard(),
      RemindersScreen(),
      NotesTodosScreen(),
      MemoryScreen(),
      SettingsScreen(),
    ];
    return Scaffold(
      body: SafeArea(child: pages[_tab]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), label: 'হোম'),
          NavigationDestination(icon: Icon(Icons.alarm_outlined), label: 'রিমাইন্ডার'),
          NavigationDestination(icon: Icon(Icons.checklist_outlined), label: 'নোট/কাজ'),
          NavigationDestination(
              icon: Icon(Icons.psychology_outlined), label: 'AI জানে'),
          NavigationDestination(
              icon: Icon(Icons.settings_outlined), label: 'সেটিংস'),
        ],
      ),
    );
  }
}

class _Dashboard extends StatelessWidget {
  const _Dashboard();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final name = app.user?.name.isNotEmpty == true ? app.user!.name : 'বন্ধু';
    return RefreshIndicator(
      onRefresh: () => app.sync(),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _UpdateBanner(),
          const SizedBox(height: 8),
          Text('আসসালামু আলাইকুম, $name',
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(app.online ? Icons.cloud_done_outlined : Icons.cloud_off,
                  size: 16,
                  color: app.online ? Colors.green : Colors.orange),
              const SizedBox(width: 6),
              Text(app.online ? 'অনলাইন — সব সেভ হয়েছে' : 'অফলাইন — ডাটা ফোনেই আছে',
                  style: const TextStyle(fontSize: 12)),
              if (app.syncing) ...[
                const SizedBox(width: 8),
                const SizedBox(
                    height: 12,
                    width: 12,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ],
          ),
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('AI আপনার জন্য যা মনে রাখছে',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text('${app.memory.length} টি তথ্য সেভ আছে।'),
                  const SizedBox(height: 8),
                  const Text(
                    'এটা Part 1 (অ্যাপ শেল)। রিমাইন্ডার, ভল্ট, জীবনের হিসাব, '
                    'ফ্যামিলি কেয়ার আর Life Scanner পরের ধাপে আসছে।',
                    style: TextStyle(fontSize: 13, color: Colors.grey),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: _QuickCard(
              emoji: '🔒', label: 'ডকুমেন্ট ভল্ট',
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const VaultScreen())))),
            const SizedBox(width: 10),
            Expanded(child: _QuickCard(
              emoji: '🚑', label: 'ইমার্জেন্সি কার্ড',
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const EmergencyScreen())))),
          ]),
          const SizedBox(height: 12),
          const _ComingSoonList(),
        ],
      ),
    );
  }
}

class _QuickCard extends StatelessWidget {
  final String emoji;
  final String label;
  final VoidCallback onTap;
  const _QuickCard({required this.emoji, required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) => Card(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 10),
            child: Column(children: [
              Text(emoji, style: const TextStyle(fontSize: 30)),
              const SizedBox(height: 6),
              Text(label, textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
      );
}

class _UpdateBanner extends StatelessWidget {
  const _UpdateBanner();
  @override
  Widget build(BuildContext context) {
    final up = context.watch<Updater>();
    if (up.available == null) return const SizedBox.shrink();
    return Card(
      color: const Color(0xFFFFF4D6),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.system_update, color: Color(0xFFB8860B)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('নতুন আপডেট আছে',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                ),
                if (!up.downloading)
                  IconButton(
                      onPressed: up.dismiss,
                      icon: const Icon(Icons.close, size: 18)),
              ],
            ),
            if (up.available!.notes.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(up.available!.notes,
                    style: const TextStyle(fontSize: 13)),
              ),
            if (up.downloading) ...[
              const SizedBox(height: 6),
              LinearProgressIndicator(
                  value: up.progress > 0 ? up.progress : null),
              const SizedBox(height: 4),
              Text('ডাউনলোড হচ্ছে… ${(up.progress * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(fontSize: 12)),
            ] else
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: up.downloadAndInstall,
                  icon: const Icon(Icons.download),
                  label: const Text('আপডেট করুন'),
                ),
              ),
            if (up.error != null)
              Text('সমস্যা: ${up.error}',
                  style: const TextStyle(color: Colors.red, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _ComingSoonList extends StatelessWidget {
  const _ComingSoonList();
  @override
  Widget build(BuildContext context) {
    final items = const [
      ['💰', 'জীবনের হিসাব (আয়-খরচ-ধার)', 'শিগগিরই'],
      ['👨‍👩‍👧', 'ফ্যামিলি কেয়ার ও ওষুধ', 'শিগগিরই'],
      ['📷', 'Life Scanner (ছবি → AI)', 'AI key লাগবে'],
    ];
    return Card(
      child: Column(
        children: [
          for (final it in items)
            ListTile(
              leading: Text(it[0], style: const TextStyle(fontSize: 22)),
              title: Text(it[1]),
              trailing: Chip(
                  label: Text(it[2], style: const TextStyle(fontSize: 11))),
            ),
        ],
      ),
    );
  }
}
