import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:intl/intl.dart';

import '../state.dart';
import '../config.dart';
import '../models.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  static const _autonomy = {
    1: ['শুধু মনে করাবে', 'কিছু করার আগে সবসময় জিজ্ঞেস করবে'],
    2: ['পরামর্শ দেবে', 'কাজ সাজিয়ে দেবে, আপনি ট্যাপ করে চালাবেন'],
    3: ['অনুমোদন নিয়ে করবে', 'তৈরি করে রাখবে, এক অনুমোদনে চলবে'],
    4: ['নিজে করবে', 'এই নির্দিষ্ট কাজে অটো (টাকা/বাইরের কাজে কখনো নয়)'],
  };

  Future<void> _export(BuildContext context) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final raw = await app.api.exportRaw();
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/assisto-export.json');
      await f.writeAsString(raw);
      if (!context.mounted) return;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('আপনার ডাটা এক্সপোর্ট'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: SelectableText(
                raw.length > 4000 ? '${raw.substring(0, 4000)}…' : raw,
                style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('ঠিক আছে')),
          ],
        ),
      );
      messenger.showSnackBar(
          SnackBar(content: Text('সেভ হয়েছে: ${f.path}')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('এক্সপোর্ট ব্যর্থ: $e')));
    }
  }

  Future<void> _deleteAccount(BuildContext context) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('অ্যাকাউন্ট মুছে ফেলবেন?'),
        content: const Text(
            'আপনার সব ডাটা (মেমোরি, অডিট লগ) স্থায়ীভাবে মুছে যাবে। '
            'এটা ফেরানো যাবে না।'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('বাতিল')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('মুছে ফেলুন')),
        ],
      ),
    );
    if (ok == true) {
      try {
        await app.deleteAccount();
      } catch (e) {
        messenger.showSnackBar(SnackBar(content: Text('ব্যর্থ: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final u = app.user;
    final level = u?.autonomyLevel ?? 2;
    return Scaffold(
      appBar: AppBar(title: const Text('সেটিংস')),
      body: ListView(
        children: [
          ListTile(
            leading: const CircleAvatar(child: Icon(Icons.person)),
            title: Text(u?.name.isNotEmpty == true ? u!.name : 'আপনি'),
            subtitle: Text([u?.phone, u?.email]
                .where((e) => e != null && e.isNotEmpty)
                .join(' · ')),
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text('স্বাধীনতার ধাপ (Autonomy dial)',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 2, 16, 4),
            child: Text('AI কতটা নিজে করবে — আপনি ঠিক করেন।',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ),
          for (final e in _autonomy.entries)
            RadioListTile<int>(
              value: e.key,
              groupValue: level,
              onChanged: (v) => app.setAutonomy(v!),
              title: Text(e.value[0]),
              subtitle: Text(e.value[1],
                  style: const TextStyle(fontSize: 12)),
              dense: true,
            ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.receipt_long_outlined),
            title: const Text('এজেন্ট কী করেছে (অডিট লগ)'),
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const AuditScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: const Text('আমার ডাটা এক্সপোর্ট'),
            subtitle: const Text('সব তথ্য JSON হিসেবে'),
            onTap: () => _export(context),
          ),
          ListTile(
            leading: const Icon(Icons.delete_forever_outlined,
                color: Colors.red),
            title: const Text('অ্যাকাউন্ট ও সব ডাটা মুছে ফেলুন',
                style: TextStyle(color: Colors.red)),
            onTap: () => _deleteAccount(context),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('লগআউট'),
            onTap: () => app.logout(),
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'আপনার ডাটা বিক্রি হয় না। শেয়ার না করলে বাইরে কিছু যায় না। '
              'AI মানুষ নয় — এটা একটা AI সহকারী।',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: Text(
              'সংস্করণ ${AppConfig.appVersionLabel}\nসার্ভার: ${AppConfig.apiBase}',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }
}

class AuditScreen extends StatefulWidget {
  const AuditScreen({super.key});
  @override
  State<AuditScreen> createState() => _AuditScreenState();
}

class _AuditScreenState extends State<AuditScreen> {
  late Future<List<AuditEntry>> _future;

  @override
  void initState() {
    super.initState();
    _future = context.read<AppState>().api.audit();
  }

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('d MMM, h:mm a');
    return Scaffold(
      appBar: AppBar(title: const Text('এজেন্ট কী করেছে')),
      body: FutureBuilder<List<AuditEntry>>(
        future: _future,
        builder: (ctx, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
                child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('লোড করা গেল না (অফলাইন?)\n${snap.error}',
                  textAlign: TextAlign.center),
            ));
          }
          final items = snap.data ?? [];
          if (items.isEmpty) {
            return const Center(child: Text('এখনো কোনো কাজ নেই।'));
          }
          return ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final a = items[i];
              return ListTile(
                dense: true,
                leading: const Icon(Icons.check_circle_outline, size: 20),
                title: Text(a.action),
                subtitle: Text(fmt.format(a.createdAt.toLocal())),
              );
            },
          );
        },
      ),
    );
  }
}
