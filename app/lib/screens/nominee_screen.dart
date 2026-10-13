import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';

/// Nominee / family access (feature 36). A trusted person who can access
/// chosen data if you're inactive or in an emergency. Explicit + reversible.
class NomineeScreen extends StatefulWidget {
  const NomineeScreen({super.key});
  @override
  State<NomineeScreen> createState() => _NomineeScreenState();
}

class _NomineeScreenState extends State<NomineeScreen> {
  List<Map<String, dynamic>> _list = [];
  bool _loading = true, _error = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      _list = await context.read<AppState>().api.listItems('nominees');
    } catch (_) {
      _error = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _add(String Function(String, String) tr) async {
    final name = TextEditingController();
    final contact = TextEditingController();
    String scope = 'emergency';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
            title: Text(tr('নমিনি যোগ', 'Add nominee')),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: name, decoration: InputDecoration(labelText: tr('নাম', 'Name'))),
              TextField(controller: contact,
                  decoration: InputDecoration(labelText: tr('ফোন/ইমেইল', 'Phone/email'))),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                value: scope,
                decoration: InputDecoration(labelText: tr('কী দেখতে পারবে', 'Access scope')),
                items: [
                  DropdownMenuItem(value: 'emergency', child: Text(tr('ইমার্জেন্সি কার্ড', 'Emergency card'))),
                  DropdownMenuItem(value: 'vault', child: Text(tr('ভল্ট', 'Vault'))),
                  DropdownMenuItem(value: 'money', child: Text(tr('টাকার সারাংশ', 'Money overview'))),
                  DropdownMenuItem(value: 'all', child: Text(tr('সব', 'All'))),
                ],
                onChanged: (v) => setD(() => scope = v ?? 'emergency'),
              ),
            ]),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('বাতিল', 'Cancel'))),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('যোগ', 'Add'))),
            ],
          )),
    );
    if (ok == true && name.text.trim().isNotEmpty) {
      await context.read<AppState>().api.createItem('nominees', {
        'name': name.text.trim(),
        'contact': contact.text.trim(),
        'scope': scope,
      });
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final en = context.watch<AppState>().locale?.languageCode == 'en';
    String tr(String bn, String e) => en ? e : bn;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr('নমিনি / পারিবারিক অ্যাক্সেস', 'Nominee / family access'))),
      floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _add(tr),
          icon: const Icon(Icons.person_add_alt),
          label: Text(tr('নমিনি', 'Nominee'))),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off, tint: scheme.error,
                  title: tr('লোড করা গেল না', "Couldn't load"),
                  action: FilledButton.tonalIcon(onPressed: _load,
                      icon: const Icon(Icons.refresh), label: Text(tr('আবার', 'Retry'))))
              : _list.isEmpty
                  ? StateMessage(
                      icon: Icons.family_restroom,
                      title: tr('কোনো নমিনি নেই', 'No nominees yet'),
                      message: tr('জরুরি অবস্থায় যাকে আপনার তথ্য দেখতে দেবেন, যোগ করুন।',
                          'Add a trusted person who can access your info in an emergency.'))
                  : ListView(padding: const EdgeInsets.all(Gap.md), children: [
                      Padding(
                        padding: const EdgeInsets.only(bottom: Gap.sm, left: 4),
                        child: Text(
                            tr('অ্যাক্সেস শুধু আপনি চালু করলে খোলে — নীরবে কখনো নয়।',
                                'Access opens only when you turn it on — never silently.'),
                            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                      ),
                      for (final n in _list)
                        Card(child: SwitchListTile(
                          value: n['activated'] == true,
                          onChanged: (v) async {
                            await context.read<AppState>().api
                                .nomineeActivate(n['id'], v);
                            await _load();
                          },
                          title: Text(n['name'] ?? ''),
                          subtitle: Text([
                            n['contact'],
                            tr('স্কোপ: ${n['scope']}', 'scope: ${n['scope']}'),
                            n['activated'] == true ? tr('✓ অ্যাক্সেস খোলা', '✓ access open') : '',
                          ].where((e) => (e ?? '').toString().isNotEmpty).join(' · ')),
                          secondary: const Icon(Icons.shield_outlined),
                        )),
                    ]),
    );
  }
}
