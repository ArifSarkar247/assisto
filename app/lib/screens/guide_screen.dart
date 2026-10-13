import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';

/// Govt-service + religious guide (feature 30). Original factual process steps;
/// links users to the official portal to confirm current rules.
class GuideScreen extends StatefulWidget {
  const GuideScreen({super.key});
  @override
  State<GuideScreen> createState() => _GuideScreenState();
}

class _GuideScreenState extends State<GuideScreen> {
  Map<String, dynamic>? _g;
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
      _g = await context.read<AppState>().api.guides();
    } catch (_) {
      _error = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final en = context.watch<AppState>().locale?.languageCode == 'en';
    String tr(String bn, String e) => en ? e : bn;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr('সেবা গাইড', 'Service guide'))),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off, tint: scheme.error,
                  title: tr('লোড করা গেল না', "Couldn't load"),
                  action: FilledButton.tonalIcon(onPressed: _load,
                      icon: const Icon(Icons.refresh), label: Text(tr('আবার', 'Retry'))))
              : ListView(padding: const EdgeInsets.all(Gap.md), children: [
                  Text(tr('সরকারি সেবা', 'Govt services'),
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                  const SizedBox(height: Gap.sm),
                  for (final s in (_g?['services'] ?? []) as List)
                    Card(child: ExpansionTile(
                      leading: const Icon(Icons.description_outlined),
                      title: Text((en ? s['name_en'] : s['name_bn']) ?? s['name_bn'] ?? ''),
                      subtitle: Text(s['portal'] ?? '',
                          style: TextStyle(fontSize: 12, color: scheme.primary)),
                      childrenPadding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.lg, Gap.md),
                      children: [
                        for (int i = 0; i < ((s['steps_bn'] ?? []) as List).length; i++)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 3),
                              child: Text('${i + 1}. ${s['steps_bn'][i]}'),
                            ),
                          ),
                      ],
                    )),
                  const SizedBox(height: Gap.lg),
                  Text(tr('ধর্মীয় রিমাইন্ডার', 'Religious reminders'),
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                  const SizedBox(height: Gap.sm),
                  for (final r in (_g?['religious'] ?? []) as List)
                    Card(child: ListTile(
                      leading: const Icon(Icons.favorite_outline),
                      title: Text((en ? r['en'] : r['bn']) ?? r['bn'] ?? ''),
                      dense: true,
                    )),
                ]),
    );
  }
}
