import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import 'memory_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final pages = const [_Dashboard(), MemoryScreen(), SettingsScreen()];
    return Scaffold(
      body: SafeArea(child: pages[_tab]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), label: 'হোম'),
          NavigationDestination(
              icon: Icon(Icons.psychology_outlined), label: 'AI কী জানে'),
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
          const _ComingSoonList(),
        ],
      ),
    );
  }
}

class _ComingSoonList extends StatelessWidget {
  const _ComingSoonList();
  @override
  Widget build(BuildContext context) {
    final items = const [
      ['⏰', 'রিমাইন্ডার, নোট, ভল্ট', 'Part 2'],
      ['💰', 'জীবনের হিসাব (আয়-খরচ-ধার)', 'Part 3'],
      ['👨‍👩‍👧', 'ফ্যামিলি কেয়ার ও ওষুধ', 'Part 4'],
      ['📷', 'Life Scanner (ছবি → AI)', 'Part 5 · AI key লাগবে'],
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
