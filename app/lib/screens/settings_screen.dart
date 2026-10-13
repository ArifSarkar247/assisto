import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:intl/intl.dart';

import '../state.dart';
import '../config.dart';
import '../models.dart';
import '../l10n/app_localizations.dart';
import 'subscriptions_screen.dart';
import 'battery_guidance_screen.dart';

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

  Future<void> _downloadOpen(BuildContext context, String path, String filename) async {
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final bytes = await app.api.getBytes(path);
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/$filename');
      await f.writeAsBytes(bytes);
      await OpenFilex.open(f.path);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('এক্সপোর্ট ব্যর্থ: $e')));
    }
  }

  Future<void> _invite(BuildContext context) async {
    final app = context.read<AppState>();
    try {
      final inv = await app.api.invite();
      if (!context.mounted) return;
      showDialog(context: context, builder: (_) => AlertDialog(
        title: const Text('ইনভাইট কোড'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          SelectableText(inv['code'] ?? '',
              style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text('${inv['invited'] ?? 0} জন যোগ দিয়েছেন'),
          const SizedBox(height: 8),
          SelectableText(inv['share_text'] ?? '', textAlign: TextAlign.center),
        ]),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('ঠিক আছে'))]));
    } catch (_) {}
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
    final t = AppLocalizations.of(context);
    final u = app.user;
    final level = u?.autonomyLevel ?? 2;
    final lang = app.locale?.languageCode ?? 'bn';
    return Scaffold(
      appBar: AppBar(title: Text(t.settingsTitle)),
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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(t.settingsLanguage,
                style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          RadioListTile<String>(
            value: 'bn',
            groupValue: lang,
            onChanged: (v) => app.setLocale(const Locale('bn')),
            title: Text(t.languageBangla),
            dense: true,
          ),
          RadioListTile<String>(
            value: 'en',
            groupValue: lang,
            onChanged: (v) => app.setLocale(const Locale('en')),
            title: Text(t.languageEnglish),
            dense: true,
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(t.settingsAppearance,
                style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          RadioListTile<ThemeMode>(
            value: ThemeMode.system,
            groupValue: app.themeMode,
            onChanged: (v) => app.setThemeMode(v!),
            title: Text(t.themeSystem),
            dense: true,
          ),
          RadioListTile<ThemeMode>(
            value: ThemeMode.light,
            groupValue: app.themeMode,
            onChanged: (v) => app.setThemeMode(v!),
            title: Text(t.themeLight),
            dense: true,
          ),
          RadioListTile<ThemeMode>(
            value: ThemeMode.dark,
            groupValue: app.themeMode,
            onChanged: (v) => app.setThemeMode(v!),
            title: Text(t.themeDark),
            dense: true,
          ),
          const Divider(),
          const _SafetySection(),
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
            leading: const Icon(Icons.table_chart_outlined),
            title: const Text('Excel-এ এক্সপোর্ট'),
            onTap: () => _downloadOpen(context, '/export/excel', 'assisto-export.xlsx'),
          ),
          ListTile(
            leading: const Icon(Icons.picture_as_pdf_outlined),
            title: const Text('PDF-এ এক্সপোর্ট'),
            onTap: () => _downloadOpen(context, '/export/pdf', 'assisto-export.pdf'),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.autorenew),
            title: Text(t.subscriptions),
            subtitle: Text(t.subscriptionsHint),
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const SubscriptionsScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.battery_charging_full_outlined),
            title: const Text('রিমাইন্ডার নির্ভরযোগ্য করুন / Reliable reminders'),
            subtitle: const Text('ব্যাটারি অপটিমাইজেশন থেকে ছাড় (Samsung/Xiaomi/Realme…)'),
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const BatteryGuidanceScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.tune),
            title: const Text('ইনপুট সোর্স অনুমতি'),
            subtitle: const Text('ছবি, শেয়ার, ভয়েস, নোটিফিকেশন — চালু/বন্ধ'),
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const SourcesScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.support_agent_outlined),
            title: const Text('সাহায্য / সমস্যা রিপোর্ট'),
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const SupportScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.card_giftcard_outlined),
            title: const Text('বন্ধুদের ইনভাইট করুন'),
            onTap: () => _invite(context),
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

// ---------------- per-source permissions ----------------
class SourcesScreen extends StatefulWidget {
  const SourcesScreen({super.key});
  @override
  State<SourcesScreen> createState() => _SourcesScreenState();
}

class _SourcesScreenState extends State<SourcesScreen> {
  List<Map<String, dynamic>> _sources = [];
  bool _loading = true;
  static const _labels = {
    'photo': 'ছবি থেকে',
    'share': 'শেয়ার/ফরোয়ার্ড',
    'voice': 'বাংলা ভয়েস',
    'notification': 'নোটিফিকেশন (bKash/ব্যাংক)',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await context.read<AppState>().api.sources();
      setState(() {
        _sources = s;
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return Scaffold(
      appBar: AppBar(title: const Text('ইনপুট সোর্স অনুমতি')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('AI কোন কোন উৎস থেকে তথ্য নেবে — আপনি ঠিক করেন। '
                      'যেকোনোটা বন্ধ রাখতে পারেন।',
                      style: TextStyle(fontSize: 13, color: Colors.grey)),
                ),
                for (final s in _sources)
                  SwitchListTile(
                    title: Text(_labels[s['source']] ?? s['source']),
                    value: s['enabled'] == true,
                    onChanged: (v) async {
                      setState(() => s['enabled'] = v);
                      await app.api.toggleSource(s['source'], v);
                    },
                  ),
              ],
            ),
    );
  }
}

// ---------------- support / bug report ----------------
class SupportScreen extends StatefulWidget {
  const SupportScreen({super.key});
  @override
  State<SupportScreen> createState() => _SupportScreenState();
}

class _SupportScreenState extends State<SupportScreen> {
  final _msg = TextEditingController();
  String _kind = 'support';
  bool _sending = false;
  bool _sent = false;

  @override
  void dispose() {
    _msg.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_msg.text.trim().isEmpty) return;
    setState(() => _sending = true);
    try {
      await context.read<AppState>().api
          .sendSupport(_kind, _msg.text.trim(), AppConfig.appVersionLabel);
      setState(() => _sent = true);
    } catch (_) {
    } finally {
      setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('সাহায্য / সমস্যা')),
      body: _sent
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.check_circle, color: Colors.green, size: 56),
                  SizedBox(height: 12),
                  Text('ধন্যবাদ! আপনার বার্তা পেয়েছি।', textAlign: TextAlign.center),
                ]),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'support', label: Text('সাহায্য')),
                    ButtonSegment(value: 'bug', label: Text('সমস্যা')),
                  ],
                  selected: {_kind},
                  onSelectionChanged: (s) => setState(() => _kind = s.first),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _msg,
                  maxLines: 6,
                  decoration: const InputDecoration(
                      labelText: 'আপনার বার্তা', alignLabelWithHint: true),
                ),
                const SizedBox(height: 14),
                FilledButton(
                  onPressed: _sending ? null : _send,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: _sending
                        ? const SizedBox(
                            height: 20, width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('পাঠান'),
                  ),
                ),
              ],
            ),
    );
  }
}


/// Safety settings: accident/fall detection (configurable countdown) + a note
/// about per-medicine reminder follow-up. OFF by default; clear bn/en text.
class _SafetySection extends StatefulWidget {
  const _SafetySection();
  @override
  State<_SafetySection> createState() => _SafetySectionState();
}

class _SafetySectionState extends State<_SafetySection> {
  late bool _fall;
  late double _sec;

  @override
  void initState() {
    super.initState();
    final u = context.read<AppState>().user;
    _fall = u?.fallDetect ?? false;
    _sec = (u?.fallCountdownSec ?? 120).toDouble().clamp(30, 600);
  }

  void _save() => context.read<AppState>().saveProfile(
      {'fall_detect': _fall, 'fall_countdown_sec': _sec.round()});

  @override
  Widget build(BuildContext context) {
    final en = context.watch<AppState>().locale?.languageCode == 'en';
    final t = AppLocalizations.of(context);
    final mins = (_sec / 60);
    final label = _sec < 60
        ? '${_sec.round()} ${t.sec}'
        : '${mins.toStringAsFixed(mins % 1 == 0 ? 0 : 1)} ${t.min}';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Text(t.safety,
            style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
      SwitchListTile(
        value: _fall,
        onChanged: (v) {
          setState(() => _fall = v);
          _save();
        },
        title: Text(t.accidentFallDetection),
        subtitle: Text(t.onAStrongImpactAn,
            style: const TextStyle(fontSize: 12)),
        isThreeLine: true,
      ),
      if (_fall)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.timeToRespondValue(label),
                style: const TextStyle(fontSize: 12)),
            Slider(
              value: _sec,
              min: 30,
              max: 600,
              divisions: 19,
              label: label,
              onChanged: (v) => setState(() => _sec = v),
              onChangeEnd: (_) => _save(),
            ),
            Text(t.n30Sec10MinDefault,
                style: TextStyle(fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ]),
        ),
      ListTile(
        leading: const Icon(Icons.medication_outlined),
        title: Text(t.medicineReminderFollowUp),
        subtitle: Text(t.setPerMedicineReRemind,
            style: const TextStyle(fontSize: 12)),
        isThreeLine: true,
      ),
    ]);
  }
}
