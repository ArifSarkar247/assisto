import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
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

  Future<void> _add(AppLocalizations tr) async {
    final name = TextEditingController();
    final contact = TextEditingController();
    String scope = 'emergency';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
            title: Text(tr.addNominee),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: name, decoration: InputDecoration(labelText: tr.name)),
              TextField(controller: contact,
                  decoration: InputDecoration(labelText: tr.phoneEmail)),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                value: scope,
                decoration: InputDecoration(labelText: tr.accessScope),
                items: [
                  DropdownMenuItem(value: 'emergency', child: Text(tr.emergencyCard)),
                  DropdownMenuItem(value: 'vault', child: Text(tr.moduleVault)),
                  DropdownMenuItem(value: 'money', child: Text(tr.moneyOverview)),
                  DropdownMenuItem(value: 'all', child: Text(tr.all)),
                ],
                onChanged: (v) => setD(() => scope = v ?? 'emergency'),
              ),
            ]),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr.cancel)),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr.add)),
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
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr.nomineeFamilyAccess)),
      floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _add(tr),
          icon: const Icon(Icons.person_add_alt),
          label: Text(tr.nominee2)),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off, tint: scheme.error,
                  title: tr.loadFailed,
                  action: FilledButton.tonalIcon(onPressed: _load,
                      icon: const Icon(Icons.refresh), label: Text(tr.retry)))
              : _list.isEmpty
                  ? StateMessage(
                      icon: Icons.family_restroom,
                      title: tr.noNomineesYet,
                      message: tr.addATrustedPersonWho)
                  : ListView(padding: const EdgeInsets.all(Gap.md), children: [
                      Padding(
                        padding: const EdgeInsets.only(bottom: Gap.sm, left: 4),
                        child: Text(
                            tr.accessOpensOnlyWhenYou,
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
                            tr.scopeValue(n['scope']),
                            n['activated'] == true ? tr.accessOpen : '',
                          ].where((e) => (e ?? '').toString().isNotEmpty).join(' · ')),
                          secondary: const Icon(Icons.shield_outlined),
                        )),
                    ]),
    );
  }
}
