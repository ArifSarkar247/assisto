import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../state.dart';
import '../updater.dart';
import 'memory_screen.dart';
import 'settings_screen.dart';
import 'reminders_screen.dart';
import 'notes_todos_screen.dart';
import 'vault_screen.dart';
import 'emergency_screen.dart';
import 'money_screen.dart';
import 'family_screen.dart';

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
          const SizedBox(height: 16),
          const _BriefingCard(),
          const SizedBox(height: 4),
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
          Card(
            color: const Color(0xFF0E7C66),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const MoneyScreen())),
              child: const Padding(
                padding: EdgeInsets.all(18),
                child: Row(children: [
                  Text('💰', style: TextStyle(fontSize: 30)),
                  SizedBox(width: 14),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('জীবনের হিসাব', style: TextStyle(color: Colors.white,
                        fontSize: 18, fontWeight: FontWeight.bold)),
                    Text('আয়, খরচ, বাজেট, ধার, সঞ্চয়', style: TextStyle(color: Colors.white70, fontSize: 13)),
                  ])),
                  Icon(Icons.chevron_right, color: Colors.white70),
                ]),
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
              emoji: '👨‍👩‍👧', label: 'ফ্যামিলি কেয়ার',
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const FamilyScreen())))),
            const SizedBox(width: 10),
            Expanded(child: _QuickCard(
              emoji: '🚑', label: 'ইমার্জেন্সি',
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const EmergencyScreen())))),
          ]),
          const SizedBox(height: 12),
          const _WrappedCard(),
          const SizedBox(height: 12),
          const _ComingSoonList(),
        ],
      ),
    );
  }
}

class _WrappedCard extends StatefulWidget {
  const _WrappedCard();
  @override
  State<_WrappedCard> createState() => _WrappedCardState();
}

class _WrappedCardState extends State<_WrappedCard> {
  Map<String, dynamic>? _w;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final w = await context.read<AppState>().api.wrapped();
      if (mounted) setState(() => _w = w);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final w = _w;
    if (w == null) return const SizedBox.shrink();
    final badges = (w['badges'] as List?)?.cast<String>() ?? [];
    return Card(
      color: const Color(0xFF1A1442),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(w['title'] ?? 'আমার মাস',
              style: const TextStyle(color: Color(0xFFFFE08A),
                  fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          for (final b in badges)
            Padding(padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(b, style: const TextStyle(color: Colors.white))),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () {
                final url = w['card_url'];
                if (url != null) launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
              },
              icon: const Icon(Icons.share, color: Color(0xFFFFE08A)),
              label: const Text('কার্ড শেয়ার', style: TextStyle(color: Color(0xFFFFE08A))),
            ),
          ),
        ]),
      ),
    );
  }
}

class _BriefingCard extends StatefulWidget {
  const _BriefingCard();
  @override
  State<_BriefingCard> createState() => _BriefingCardState();
}

class _BriefingCardState extends State<_BriefingCard> {
  Map<String, dynamic>? _b;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final b = await context.read<AppState>().api.briefing();
      if (mounted) setState(() => _b = b);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final b = _b;
    if (b == null) return const SizedBox.shrink();
    final lines = (b['lines'] as List?)?.cast<String>() ?? [];
    final aiText = b['ai_text'] as String?;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Text('✨ আজকের ব্রিফিং',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const Spacer(),
            IconButton(onPressed: _load, icon: const Icon(Icons.refresh, size: 18),
                visualDensity: VisualDensity.compact),
          ]),
          if (aiText != null && aiText.isNotEmpty)
            Text(aiText)
          else
            ...lines.map((l) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 1), child: Text(l))),
        ]),
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
      ['📷', 'Life Scanner (ছবি → AI)', 'AI key লাগবে'],
      ['✨', 'সকালের ব্রিফিং ও প্ল্যান', 'AI key লাগবে'],
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
