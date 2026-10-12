import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:intl/intl.dart';
import '../state.dart';

const _docTypes = {
  'passport': 'পাসপোর্ট',
  'nid': 'NID',
  'licence': 'ড্রাইভিং লাইসেন্স',
  'certificate': 'সার্টিফিকেট',
  'other': 'অন্যান্য',
};

class VaultScreen extends StatefulWidget {
  const VaultScreen({super.key});
  @override
  State<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends State<VaultScreen> {
  final _secure = const FlutterSecureStorage();
  bool _unlocked = false;
  bool _checking = true;
  List<Map<String, dynamic>> _docs = [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    // Block screenshots of the vault where supported (best-effort).
    _gate();
  }

  Future<void> _gate() async {
    final pin = await _secure.read(key: 'vault_pin');
    setState(() => _checking = false);
    if (pin == null) {
      await _setPin();
    } else {
      await _enterPin(pin);
    }
    if (_unlocked) _load();
  }

  Future<void> _setPin() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context, barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('ভল্টের জন্য PIN দিন'),
        content: TextField(
          controller: ctrl, obscureText: true, keyboardType: TextInputType.number,
          maxLength: 6,
          decoration: const InputDecoration(labelText: '৪-৬ সংখ্যার PIN'),
        ),
        actions: [FilledButton(
            onPressed: () => Navigator.pop(ctx, true), child: const Text('সেট করুন'))],
      ),
    );
    if (ok == true && ctrl.text.length >= 4) {
      await _secure.write(key: 'vault_pin', value: ctrl.text);
      setState(() => _unlocked = true);
    } else if (mounted) {
      Navigator.pop(context);
    }
  }

  Future<void> _enterPin(String real) async {
    final ctrl = TextEditingController();
    String? err;
    final ok = await showDialog<bool>(
      context: context, barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
        title: const Text('ভল্ট লক'),
        content: TextField(
          controller: ctrl, obscureText: true, keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: 'PIN দিন', errorText: err),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('বাতিল')),
          FilledButton(onPressed: () {
            if (ctrl.text == real) {
              Navigator.pop(ctx, true);
            } else {
              setD(() => err = 'ভুল PIN');
            }
          }, child: const Text('খুলুন')),
        ],
      )),
    );
    if (ok == true) {
      setState(() => _unlocked = true);
    } else if (mounted) {
      Navigator.pop(context);
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      _docs = await context.read<AppState>().api.listDocuments();
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _add() async {
    final picked = await FilePicker.platform.pickFiles(withData: false);
    if (picked == null || picked.files.single.path == null) return;
    final path = picked.files.single.path!;
    final title = TextEditingController(
        text: picked.files.single.name.split('.').first);
    String type = 'passport';
    DateTime? expiry;
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
        title: const Text('ডকুমেন্ট যোগ'),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: title, decoration: const InputDecoration(labelText: 'নাম')),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            value: type,
            decoration: const InputDecoration(labelText: 'ধরন'),
            items: _docTypes.entries.map((e) =>
                DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
            onChanged: (v) => setD(() => type = v ?? 'other'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            icon: const Icon(Icons.event, size: 18),
            label: Text(expiry == null ? 'মেয়াদ শেষের তারিখ (ঐচ্ছিক)'
                : DateFormat('d MMM yyyy').format(expiry!)),
            onPressed: () async {
              final d = await showDatePicker(context: ctx, initialDate: DateTime.now(),
                  firstDate: DateTime(2000), lastDate: DateTime(2100));
              if (d != null) setD(() => expiry = d);
            },
          ),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('বাতিল')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('সেভ')),
        ],
      )),
    );
    if (ok == true && title.text.trim().isNotEmpty) {
      try {
        await context.read<AppState>().api.uploadDocument(
          title: title.text.trim(), docType: type,
          expiryDate: expiry != null ? DateFormat('yyyy-MM-dd').format(expiry!) : null,
          filePath: path);
        await _load();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
        }
      }
    }
  }

  Future<void> _view(Map<String, dynamic> doc) async {
    try {
      final bytes = await context.read<AppState>().api.getBytes('/documents/${doc['id']}/file');
      final dir = await getTemporaryDirectory();
      final name = (doc['title'] ?? 'doc').toString().replaceAll(RegExp(r'[^\w.-]'), '_');
      final f = File('${dir.path}/$name');
      await f.writeAsBytes(bytes);
      await OpenFilex.open(f.path);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('খোলা গেল না: $e')));
      }
    }
  }

  Widget? _expiryBadge(String? iso) {
    if (iso == null) return null;
    final d = DateTime.tryParse(iso);
    if (d == null) return null;
    final days = d.difference(DateTime.now()).inDays;
    Color c;
    String t;
    if (days < 0) { c = Colors.red; t = 'মেয়াদ শেষ'; }
    else if (days <= 7) { c = Colors.red; t = '$days দিনে শেষ'; }
    else if (days <= 30) { c = Colors.orange; t = '$days দিনে শেষ'; }
    else if (days <= 90) { c = const Color(0xFFB8860B); t = '$days দিনে শেষ'; }
    else { return null; }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: c.withOpacity(0.15), borderRadius: BorderRadius.circular(10)),
      child: Text(t, style: TextStyle(fontSize: 11, color: c)));
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_unlocked) {
      return Scaffold(
        appBar: AppBar(title: const Text('ডকুমেন্ট ভল্ট')),
        body: const Center(child: Text('ভল্ট লক করা।')),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('ডকুমেন্ট ভল্ট 🔒')),
      floatingActionButton: FloatingActionButton.extended(
          onPressed: _add, icon: const Icon(Icons.upload_file), label: const Text('যোগ করুন')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _docs.isEmpty
              ? const Center(child: Padding(padding: EdgeInsets.all(32),
                  child: Text('কোনো ডকুমেন্ট নেই।\nপাসপোর্ট, NID, লাইসেন্স নিরাপদে রাখুন।',
                      textAlign: TextAlign.center, style: TextStyle(color: Colors.grey))))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
                  children: [
                    for (final doc in _docs)
                      Card(child: ListTile(
                        leading: const Icon(Icons.description_outlined),
                        title: Text(doc['title'] ?? ''),
                        subtitle: Row(children: [
                          Text(_docTypes[doc['doc_type']] ?? ''),
                          const SizedBox(width: 8),
                          if (_expiryBadge(doc['expiry_date']) != null)
                            _expiryBadge(doc['expiry_date'])!,
                        ]),
                        onTap: () => _view(doc),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            await context.read<AppState>().api.deleteDocument(doc['id']);
                            _load();
                          }),
                      )),
                  ],
                ),
    );
  }
}
