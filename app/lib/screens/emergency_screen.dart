import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:geolocator/geolocator.dart';
import 'package:share_plus/share_plus.dart';
import '../state.dart';
import '../l10n/app_localizations.dart';

class EmergencyScreen extends StatefulWidget {
  const EmergencyScreen({super.key});
  @override
  State<EmergencyScreen> createState() => _EmergencyScreenState();
}

class _EmergencyScreenState extends State<EmergencyScreen> {
  final _blood = TextEditingController();
  final _allergies = TextEditingController();
  final _meds = TextEditingController();
  final _conditions = TextEditingController();
  List<Map<String, dynamic>> _contacts = [];
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _blood.dispose(); _allergies.dispose(); _meds.dispose(); _conditions.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final c = await context.read<AppState>().api.getEmergency();
      _blood.text = c['blood_group'] ?? '';
      _allergies.text = c['allergies'] ?? '';
      _meds.text = c['medicines'] ?? '';
      _conditions.text = c['conditions'] ?? '';
      _contacts = ((c['contacts'] ?? []) as List).cast<Map<String, dynamic>>();
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await context.read<AppState>().api.putEmergency({
        'blood_group': _blood.text.trim(),
        'allergies': _allergies.text.trim(),
        'medicines': _meds.text.trim(),
        'conditions': _conditions.text.trim(),
        'contacts': _contacts,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).emergencySaved)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _addContact() async {
    final name = TextEditingController();
    final phone = TextEditingController();
    final rel = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocalizations.of(context).emergencyContactTitle),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, decoration: InputDecoration(labelText: AppLocalizations.of(context).name)),
          TextField(controller: phone, keyboardType: TextInputType.phone,
              decoration: InputDecoration(labelText: AppLocalizations.of(context).phone)),
          TextField(controller: rel, decoration: InputDecoration(labelText: AppLocalizations.of(context).familyRelationLabel)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(AppLocalizations.of(context).cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(AppLocalizations.of(context).add)),
        ],
      ),
    );
    if (ok == true && phone.text.trim().isNotEmpty) {
      setState(() => _contacts.add({
        'name': name.text.trim(), 'phone': phone.text.trim(), 'relation': rel.text.trim()}));
    }
  }

  Future<void> _call(String phone) async {
    final uri = Uri.parse('tel:$phone');
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  Future<void> _shareLocation() async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        messenger.showSnackBar(SnackBar(content: Text(t.locationOff)));
        return;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        messenger.showSnackBar(SnackBar(content: Text(t.locationNeeded)));
        return;
      }
      final pos = await Geolocator.getCurrentPosition();
      final link = 'https://maps.google.com/?q=${pos.latitude},${pos.longitude}';
      await Share.share(t.sosShareText(link));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _sos() async {
    if (_contacts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).emergencyAddContactFirst)));
      return;
    }
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('SOS'),
        content: Text(AppLocalizations.of(context).emergencySosConfirm(_contacts.first['name'], _contacts.first['phone'])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(AppLocalizations.of(context).emergencyNo)),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true), child: Text(AppLocalizations.of(context).call)),
        ],
      ),
    );
    if (confirm == true) _call(_contacts.first['phone']);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(AppLocalizations.of(context).emergencyCard), actions: [
        _saving
            ? const Padding(padding: EdgeInsets.all(14),
                child: SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)))
            : IconButton(onPressed: _save, icon: const Icon(Icons.save)),
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
                backgroundColor: Colors.red, padding: const EdgeInsets.symmetric(vertical: 16)),
            onPressed: _sos,
            icon: const Icon(Icons.sos, size: 28),
            label: Text(AppLocalizations.of(context).emergencySosButton, style: TextStyle(fontSize: 18)),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _shareLocation,
            icon: const Icon(Icons.my_location),
            label: Text(t.shareMyLocation),
          ),
        ),
        const SizedBox(height: 16),
        TextField(controller: _blood, decoration: InputDecoration(labelText: AppLocalizations.of(context).emergencyBloodGroup)),
        const SizedBox(height: 10),
        TextField(controller: _allergies, maxLines: 2,
            decoration: InputDecoration(labelText: AppLocalizations.of(context).emergencyAllergies)),
        const SizedBox(height: 10),
        TextField(controller: _meds, maxLines: 2,
            decoration: InputDecoration(labelText: AppLocalizations.of(context).emergencyMedicines)),
        const SizedBox(height: 10),
        TextField(controller: _conditions, maxLines: 2,
            decoration: InputDecoration(labelText: AppLocalizations.of(context).emergencyConditions)),
        const SizedBox(height: 18),
        Row(children: [
          Text(AppLocalizations.of(context).emergencyContactTitle, style: TextStyle(fontWeight: FontWeight.bold)),
          const Spacer(),
          TextButton.icon(onPressed: _addContact,
              icon: const Icon(Icons.add), label: Text(AppLocalizations.of(context).add)),
        ]),
        for (int i = 0; i < _contacts.length; i++)
          Card(child: ListTile(
            title: Text(_contacts[i]['name'] ?? ''),
            subtitle: Text('${_contacts[i]['phone']} · ${_contacts[i]['relation'] ?? ''}'),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(icon: const Icon(Icons.call, color: Colors.green),
                  onPressed: () => _call(_contacts[i]['phone'])),
              IconButton(icon: const Icon(Icons.delete_outline),
                  onPressed: () => setState(() => _contacts.removeAt(i))),
            ]),
          )),
        const SizedBox(height: 20),
        Text(AppLocalizations.of(context).emergencyFooterNote, style: TextStyle(fontSize: 12, color: Colors.grey)),
      ]),
    );
  }
}
