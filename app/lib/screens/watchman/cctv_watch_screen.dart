import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/cv_empty.dart';
import '../../widgets/local_counter.dart';
import 'cctv_grid_screen.dart' show CctvStill;
import 'cctv_team_source.dart';
import 'watchman_source.dart';
import 'watchman_widgets.dart';

/// cctvteam (W11, audit F5) — PRIVATE neighbourhood watch. A user may share
/// ONE photo they chose (from a camera or an alert) with ONE private My
/// Circle community group they belong to. Never public (public communities
/// are not offered and the server refuses them), never automatic (an explicit
/// confirm every time), auto-deletes after 6 / 24 / 72 h (24 h default),
/// report + block on every post. Faces are NOT blurred — said plainly.
class CctvWatchScreen extends StatefulWidget {
  final CctvTeamSource source;
  const CctvWatchScreen({super.key, required this.source});

  @override
  State<CctvWatchScreen> createState() => _CctvWatchScreenState();
}

class _CctvWatchScreenState extends State<CctvWatchScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _groups = const [];
  String _note = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await widget.source.watchGroups();
      _groups = wmList(d['groups']);
      _note = (d['note'] ?? '').toString();
    } catch (e) {
      _error = wmError(e) ?? '';
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.ctmWatchTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: withNavBarInset(context, const EdgeInsets.fromLTRB(16, 12, 16, 32)),
                children: [
                  if (_error != null) ...[
                    Text(_error!.isEmpty ? t.wmLoadErrorBody : _error!),
                    const SizedBox(height: 8),
                    OutlinedButton(
                        style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                        onPressed: _load,
                        child: Text(t.wmRetry)),
                  ] else if (_groups.isEmpty)
                    CvEmptyBlock(
                      icon: Icons.diversity_3_rounded,
                      title: t.ctmWatchEmptyTitle,
                      benefit: t.ctmWatchEmptyBenefit,
                      primaryIcon: Icons.refresh_rounded,
                      primaryLabel: t.ctmWatchEmptyRefresh,
                      onPrimary: _load,
                      steps: [t.ctmWatchEmptyStep1, t.ctmWatchEmptyStep2, t.ctmWatchEmptyStep3],
                    )
                  else ...[
                    Text(t.ctmWatchIntro),
                    const SizedBox(height: 8),
                    for (final g in _groups)
                      Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          key: ValueKey('ctm-watch-group-${g['id']}'),
                          minVerticalPadding: 12,
                          leading: const CircleAvatar(child: Icon(Icons.lock_rounded)),
                          title: Text((g['name'] ?? '').toString()),
                          subtitle: Text('${g['community'] ?? ''} · '
                              '${t.ctmWatchMembers(wmDigits(lang, (g['members'] as num?)?.toInt() ?? 0))}'),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => CctvWatchGroupScreen(
                                  source: widget.source,
                                  groupId: (g['id'] as num).toInt(),
                                  name: (g['name'] ?? '').toString()))),
                        ),
                      ),
                  ],
                  if (_note.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _PrivacyNote(text: _note),
                  ],
                ],
              ),
            ),
    );
  }
}

class _PrivacyNote extends StatelessWidget {
  final String text;
  const _PrivacyNote({required this.text});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.privacy_tip_outlined),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
        ]),
      ),
    );
  }
}

class CctvWatchGroupScreen extends StatefulWidget {
  final CctvTeamSource source;
  final int groupId;
  final String name;
  const CctvWatchGroupScreen({super.key, required this.source, required this.groupId, required this.name});

  @override
  State<CctvWatchGroupScreen> createState() => _CctvWatchGroupScreenState();
}

class _CctvWatchGroupScreenState extends State<CctvWatchGroupScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _posts = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _posts = wmList((await widget.source.watchPosts(widget.groupId))['posts']);
    } catch (e) {
      _error = wmError(e) ?? '';
    }
    if (mounted) setState(() => _loading = false);
  }

  void _snack(String s) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  Future<void> _report(Map<String, dynamic> p) async {
    final t = AppLocalizations.of(context);
    final res = await showAppSheet<(String, bool)>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ReportSheet(author: (p['author_name'] ?? '').toString()),
    );
    if (res == null) return;
    try {
      await widget.source.watchReport((p['id'] as num).toInt(), res.$1, block: res.$2);
      _snack(t.ctmWatchReported);
    } catch (e) {
      _snack(wmError(e) ?? t.wmGenericError);
    }
    await _load();
  }

  Future<void> _delete(Map<String, dynamic> p) async {
    final t = AppLocalizations.of(context);
    try {
      await widget.source.watchDelete((p['id'] as num).toInt());
      _snack(t.ctmWatchDeleted);
    } catch (e) {
      _snack(wmError(e) ?? t.wmGenericError);
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.name)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: withNavBarInset(context, const EdgeInsets.fromLTRB(16, 12, 16, 32)),
                children: [
                  if (_error != null)
                    Text(_error!.isEmpty ? t.wmLoadErrorBody : _error!)
                  else if (_posts.isEmpty)
                    CvEmptyBlock(
                      compact: true,
                      icon: Icons.photo_library_outlined,
                      title: t.ctmWatchNoPostsTitle,
                      benefit: t.ctmWatchNoPostsBenefit,
                      primaryIcon: Icons.refresh_rounded,
                      primaryLabel: t.ctmWatchEmptyRefresh,
                      onPrimary: _load,
                      steps: [t.ctmWatchShareStep1, t.ctmWatchShareStep2, t.ctmWatchShareStep3],
                    ),
                  for (final p in _posts)
                    Card(
                      clipBehavior: Clip.antiAlias,
                      margin: const EdgeInsets.only(bottom: 12),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        AspectRatio(
                          aspectRatio: 16 / 9,
                          child: CctvStill(source: widget.source, url: (p['image_url'] ?? '').toString(), width: 720),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            if ((p['caption'] ?? '').toString().isNotEmpty)
                              Text((p['caption'] ?? '').toString(),
                                  style: Theme.of(context).textTheme.titleSmall),
                            const SizedBox(height: 4),
                            Text(t.ctmWatchBy((p['author_name'] ?? '').toString(),
                                ctmTime(lang, p['created']?.toString()))),
                            Text(t.ctmWatchUntil(ctmTime(lang, p['expires_at']?.toString())),
                                style: Theme.of(context).textTheme.bodySmall),
                          ]),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                          child: Wrap(spacing: 8, children: [
                            if (p['mine'] == true)
                              TextButton.icon(
                                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                                icon: const Icon(Icons.delete_outline_rounded),
                                label: Text(t.ctmWatchDelete),
                                onPressed: () => _delete(p),
                              )
                            else
                              TextButton.icon(
                                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                                icon: const Icon(Icons.flag_outlined),
                                label: Text(t.ctmWatchReport),
                                onPressed: () => _report(p),
                              ),
                          ]),
                        ),
                      ]),
                    ),
                ],
              ),
            ),
    );
  }
}

class _ReportSheet extends StatefulWidget {
  final String author;
  const _ReportSheet({required this.author});

  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  String _reason = 'private';
  bool _block = false;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final reasons = {
      'private': t.ctmReasonPrivate,
      'wrong_person': t.ctmReasonWrongPerson,
      'abuse': t.ctmReasonAbuse,
      'spam': t.ctmReasonSpam,
      'other': t.ctmReasonOther,
    };
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.ctmWatchReport, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(t.ctmReportHelp),
        for (final e in reasons.entries)
          RadioListTile<String>(
            value: e.key,
            groupValue: _reason,
            title: Text(e.value),
            onChanged: (v) => setState(() => _reason = v ?? 'other'),
          ),
        SwitchListTile(
          value: _block,
          title: Text(t.ctmBlockAuthor(widget.author)),
          subtitle: Text(t.ctmBlockHelp),
          onChanged: (v) => setState(() => _block = v),
        ),
        const SizedBox(height: 8),
        FilledButton(
          key: const ValueKey('ctm-report-send'),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
          onPressed: () => Navigator.of(context).pop((_reason, _block)),
          child: Text(t.ctmReportSend),
        ),
      ]),
    );
  }
}

/// Share ONE photo (a camera's newest still, or one alert's photo) with one
/// private group — explicit confirm, expiry chosen, privacy said plainly.
Future<bool> showCctvWatchShareSheet(BuildContext context, CctvTeamSource source,
    {int? camera, int? event}) async {
  final ok = await showAppSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => CctvWatchShareSheet(source: source, camera: camera, event: event),
  );
  return ok == true;
}

class CctvWatchShareSheet extends StatefulWidget {
  final CctvTeamSource source;
  final int? camera;
  final int? event;
  const CctvWatchShareSheet({super.key, required this.source, this.camera, this.event});

  @override
  State<CctvWatchShareSheet> createState() => _CctvWatchShareSheetState();
}

class _CctvWatchShareSheetState extends State<CctvWatchShareSheet> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _groups = const [];
  List<int> _hours = const [6, 24, 72];
  int? _group;
  int _h = 24;
  bool _confirm = false;
  bool _sending = false;
  String _note = '';
  final _caption = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _caption.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await widget.source.watchGroups();
      _groups = wmList(d['groups']);
      _hours = (d['hours'] is List)
          ? [for (final h in d['hours'] as List) (h as num).toInt()]
          : const [6, 24, 72];
      _h = (d['default_hours'] as num?)?.toInt() ?? 24;
      _note = (d['note'] ?? '').toString();
      if (_groups.length == 1) _group = (_groups.first['id'] as num).toInt();
    } catch (e) {
      _error = wmError(e) ?? '';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _send() async {
    final t = AppLocalizations.of(context);
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.source.watchShare({
        'group': _group,
        if (widget.event != null) 'event': widget.event,
        if (widget.event == null && widget.camera != null) 'camera': widget.camera,
        'caption': _caption.text.trim(),
        'hours': _h,
        'confirm': true,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.ctmWatchShared)));
      Navigator.of(context).pop(true);
      return;
    } catch (e) {
      _error = wmError(e) ?? t.wmGenericError;
    }
    if (mounted) setState(() => _sending = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    if (_loading) {
      return const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()));
    }
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.ctmShareToWatch, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        if (_groups.isEmpty) ...[
          Text(t.ctmWatchEmptyBenefit),
          const SizedBox(height: 8),
          Text('${wmDigits(lang, 1)}. ${t.ctmWatchEmptyStep1}'),
          Text('${wmDigits(lang, 2)}. ${t.ctmWatchEmptyStep2}'),
          const SizedBox(height: 12),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t.wmCancel),
          ),
        ] else ...[
          Text(t.ctmPickGroup, style: Theme.of(context).textTheme.labelLarge),
          for (final g in _groups)
            RadioListTile<int>(
              value: (g['id'] as num).toInt(),
              groupValue: _group,
              title: Text((g['name'] ?? '').toString()),
              subtitle: Text((g['community'] ?? '').toString()),
              onChanged: (v) => setState(() => _group = v),
            ),
          const SizedBox(height: 4),
          Text(t.ctmDeleteAfter, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 4),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final h in _hours)
              ChoiceChip(
                label: Text(t.ctmHours(wmDigits(lang, h))),
                selected: _h == h,
                onSelected: (_) => setState(() => _h = h),
              ),
          ]),
          const SizedBox(height: 12),
          TextField(
            controller: _caption,
            maxLength: 200,
            buildCounter: localCounter,
            decoration: InputDecoration(
              labelText: t.ctmCaption,
              hintText: t.ctmCaptionHint,
              border: const OutlineInputBorder(),
            ),
          ),
          if (_note.isNotEmpty) _PrivacyNote(text: _note),
          CheckboxListTile(
            key: const ValueKey('ctm-watch-confirm'),
            value: _confirm,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(t.ctmWatchConfirm),
            onChanged: (v) => setState(() => _confirm = v ?? false),
          ),
          if (_error != null && _error!.isNotEmpty)
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          const SizedBox(height: 8),
          FilledButton.icon(
            key: const ValueKey('ctm-watch-send'),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
            icon: _sending
                ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.send_rounded),
            label: Text(t.ctmWatchSend),
            // disabled until a group is picked and the user confirmed
            onPressed: _sending || _group == null || !_confirm ? null : _send,
          ),
        ],
      ]),
    );
  }
}
