import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';

/// Job hunter (feature 37). Add a job → match score from your own skills →
/// AI-tailored CV + cover letter (needs-key state). NEVER auto-applies.
class JobsScreen extends StatefulWidget {
  const JobsScreen({super.key});
  @override
  State<JobsScreen> createState() => _JobsScreenState();
}

class _JobsScreenState extends State<JobsScreen> {
  List<Map<String, dynamic>> _jobs = [];
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
      _jobs = await context.read<AppState>().api.listItems('jobs');
    } catch (_) {
      _error = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _add(String Function(String, String) tr) async {
    final title = TextEditingController();
    final company = TextEditingController();
    final jd = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('চাকরি যোগ', 'Add job')),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: title, decoration: InputDecoration(labelText: tr('পদ', 'Title'))),
            TextField(controller: company, decoration: InputDecoration(labelText: tr('কোম্পানি', 'Company'))),
            TextField(controller: jd, maxLines: 4,
                decoration: InputDecoration(labelText: tr('চাকরির বিবরণ', 'Job description'))),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('বাতিল', 'Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('যোগ', 'Add'))),
        ],
      ),
    );
    if (ok == true && title.text.trim().isNotEmpty) {
      await context.read<AppState>().api.createItem('jobs', {
        'title': title.text.trim(),
        'company': company.text.trim(),
        'jd': jd.text.trim(),
      });
      await _load();
    }
  }

  Future<void> _tailor(int id, String Function(String, String) tr) async {
    showDialog(context: context, barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()));
    try {
      final r = await context.read<AppState>().api.jobTailor(id);
      if (!mounted) return;
      Navigator.pop(context);
      if (r['needs_key'] == true) {
        showDialog(context: context, builder: (_) => AlertDialog(
          content: Text(tr('চালু হবে যখন AI key যোগ হবে।', 'Available when an AI key is added.')),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('ঠিক আছে', 'OK')))]));
        return;
      }
      final cv = (r['cv_text'] ?? '').toString();
      final cover = (r['cover_letter'] ?? '').toString();
      showDialog(context: context, builder: (_) => AlertDialog(
        title: Text(tr('তৈরি হয়েছে', 'Generated')),
        content: SizedBox(width: double.maxFinite, child: SingleChildScrollView(
          child: SelectableText('CV:\n$cv\n\n${tr('কভার লেটার', 'Cover letter')}:\n$cover'))),
        actions: [
          TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: 'CV:\n$cv\n\nCover:\n$cover'));
                ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(tr('কপি হয়েছে', 'Copied'))));
              },
              child: Text(tr('কপি', 'Copy'))),
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('বন্ধ', 'Close'))),
        ]));
      await _load();
    } catch (_) {
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final en = context.watch<AppState>().locale?.languageCode == 'en';
    String tr(String bn, String e) => en ? e : bn;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr('জব হান্টার', 'Job hunter'))),
      floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _add(tr), icon: const Icon(Icons.add), label: Text(tr('চাকরি', 'Job'))),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(icon: Icons.cloud_off, tint: scheme.error,
                  title: tr('লোড করা গেল না', "Couldn't load"),
                  action: FilledButton.tonalIcon(onPressed: _load,
                      icon: const Icon(Icons.refresh), label: Text(tr('আবার', 'Retry'))))
              : _jobs.isEmpty
                  ? StateMessage(icon: Icons.work_outline,
                      title: tr('কোনো চাকরি নেই', 'No jobs yet'),
                      message: tr('চাকরির বিবরণ যোগ করুন — আপনার দক্ষতার সাথে মিল দেখাব, CV বানিয়ে দেব।',
                          'Add a job description — I score the match and draft a CV. You approve & send.'))
                  : ListView(padding: const EdgeInsets.all(Gap.md), children: [
                      Padding(padding: const EdgeInsets.only(bottom: Gap.sm, left: 4),
                        child: Text(tr('কখনো নিজে থেকে আবেদন করি না — আপনি অনুমোদন করে নিজের মেইল থেকে পাঠান।',
                            'I never auto-apply — you approve and send from your own email.'),
                            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant))),
                      for (final j in _jobs)
                        Card(child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: ((j['match_score'] ?? 0) as int) >= 70
                                ? scheme.primaryContainer : scheme.surfaceContainerHighest,
                            child: Text('${j['match_score'] ?? 0}',
                                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                          ),
                          title: Text('${j['title'] ?? ''}'
                              '${(j['company'] ?? '').toString().isNotEmpty ? ' · ${j['company']}' : ''}'),
                          subtitle: Text(j['match_reason'] ?? '',
                              maxLines: 2, overflow: TextOverflow.ellipsis),
                          trailing: IconButton(
                            icon: const Icon(Icons.auto_awesome),
                            tooltip: tr('CV/কভার বানাও', 'Make CV/cover'),
                            onPressed: () => _tailor(j['id'], tr),
                          ),
                        )),
                    ]),
    );
  }
}
