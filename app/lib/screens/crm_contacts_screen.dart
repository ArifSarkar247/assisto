import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';

/// Personal CRM (feature 24): people you meet, notes, follow-ups.
class CrmContactsScreen extends StatefulWidget {
  const CrmContactsScreen({super.key});
  @override
  State<CrmContactsScreen> createState() => _CrmContactsScreenState();
}

class _CrmContactsScreenState extends State<CrmContactsScreen> {
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
      _list = await context.read<AppState>().api.listItems('contacts');
    } catch (_) {
      _error = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _add(AppLocalizations tr) async {
    final name = TextEditingController();
    final phone = TextEditingController();
    final org = TextEditingController();
    final note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.addContact),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, decoration: InputDecoration(labelText: tr.name)),
            TextField(controller: phone, keyboardType: TextInputType.phone,
                decoration: InputDecoration(labelText: tr.phone)),
            TextField(controller: org, decoration: InputDecoration(labelText: tr.organization)),
            TextField(controller: note, maxLines: 2,
                decoration: InputDecoration(labelText: tr.note)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr.add)),
        ],
      ),
    );
    if (ok == true && name.text.trim().isNotEmpty) {
      await context.read<AppState>().api.createItem('contacts', {
        'name': name.text.trim(),
        'phone': phone.text.trim(),
        'org': org.text.trim(),
        'note': note.text.trim(),
      });
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr.crmContacts)),
      floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _add(tr), icon: const Icon(Icons.person_add_alt),
          label: Text(tr.contact)),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(icon: Icons.cloud_off, tint: scheme.error,
                  title: tr.loadFailed,
                  action: FilledButton.tonalIcon(onPressed: _load,
                      icon: const Icon(Icons.refresh), label: Text(tr.retry)))
              : _list.isEmpty
                  ? StateMessage(icon: Icons.contacts_outlined,
                      title: tr.noContactsYet,
                      message: tr.keepNotesOnPeopleYou)
                  : ListView(padding: const EdgeInsets.all(Gap.md), children: [
                      for (final c in _list)
                        Card(child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: scheme.primaryContainer,
                            child: Text(((c['name'] ?? '?').toString().isNotEmpty
                                    ? c['name'][0] : '?').toUpperCase(),
                                style: TextStyle(color: scheme.onPrimaryContainer)),
                          ),
                          title: Text(c['name'] ?? ''),
                          subtitle: Text([c['org'], c['note']]
                              .where((e) => (e ?? '').toString().isNotEmpty).join(' · ')),
                          trailing: (c['phone'] ?? '').toString().isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.call, color: Colors.green),
                                  onPressed: () => launchUrl(Uri.parse('tel:${c['phone']}')))
                              : null,
                        )),
                    ]),
    );
  }
}
