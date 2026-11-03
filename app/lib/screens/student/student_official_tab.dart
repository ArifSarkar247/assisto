// p3guides (owner PART 3, flag official_corners): Student corner "Official
// dates" tab. Official scholarship / board exam / admission pages only (from
// GET /official-info/student, dated + cached offline). We never invent a date:
// the student reads it on the official notice and taps "Save a deadline", which
// adds a kind='deadline' item to the existing Tracker (student/assignments) so
// the overdue / today / upcoming board reminds them. No books (unlicensed) —
// textbooks link to NCTB's free official site.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart' show withNavBarInset;
import '../../widgets/guide_service_card.dart' show p3gDate;
import '../../widgets/local_counter.dart';
import '../../widgets/local_digits.dart';
import '../../widgets/official_info_cache.dart';
import '../../widgets/skeleton.dart';

const String kStudentAssignPath = 'student/assignments';

class StudentOfficialTab extends StatefulWidget {
  /// Called after a deadline was saved (the parent reloads the Tracker).
  final VoidCallback onSaved;
  const StudentOfficialTab({super.key, required this.onSaved});
  @override
  State<StudentOfficialTab> createState() => _StudentOfficialTabState();
}

class _StudentOfficialTabState extends State<StudentOfficialTab>
    with AutomaticKeepAliveClientMixin {
  Map<String, dynamic>? _d;
  bool _loading = true, _fromCache = false;
  String _lang = '';

  @override
  bool get wantKeepAlive => true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final lang = Localizations.localeOf(context).languageCode;
    if (lang != _lang) {
      _lang = lang;
      _load();
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final r = await loadOfficialInfo(context.read<AppState>().api, 'student', _lang);
    if (!mounted) return;
    setState(() {
      _d = r.data;
      _fromCache = r.fromCache;
      _loading = false;
    });
  }

  Future<void> _open(String url) async {
    if (url.isEmpty) return;
    final uri = Uri.parse(url);
    final ok = await canLaunchUrl(uri) &&
        await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      final tr = AppLocalizations.of(context);
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(tr.guideCouldNotOpen)));
    }
  }

  Future<void> _saveDeadline() async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => const _DeadlineDialog(),
    );
    if (saved == true && mounted) {
      final tr = AppLocalizations.of(context);
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(tr.p3gDeadlineSaved)));
      widget.onSaved();
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) return const SkeletonList();
    final pad = withNavBarInset(context, const EdgeInsets.all(Gap.lg));
    final saveBtn = FilledButton.icon(
      key: const ValueKey('p3g-save-deadline'),
      onPressed: _saveDeadline,
      icon: const Icon(Icons.event_rounded),
      label: Text(tr.p3gSaveDeadline),
    );
    final d = _d;
    if (d == null) {
      // Saving a deadline still works (the date comes from the notice).
      return ListView(padding: pad, children: [
        StateMessage(
          icon: Icons.cloud_download_rounded,
          title: tr.loadFailed,
          message: tr.p3gNeedNetOnce,
          action: FilledButton.tonalIcon(
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(tr.retry),
          ),
        ),
        const SizedBox(height: Gap.lg),
        saveBtn,
      ]);
    }
    final muted = AType.bodySmall.copyWith(color: scheme.onSurfaceVariant);
    return ListView(
      key: const ValueKey('p3g-student-official'),
      padding: pad,
      children: [
        if (_fromCache)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.sm),
            child: Text(tr.p3gFromCache, style: muted),
          ),
        Text(tr.p3gDeadlineHow, style: AType.bodyMedium),
        const SizedBox(height: Gap.sm),
        saveBtn,
        const SizedBox(height: Gap.lg),
        for (final g in (d['groups'] as List? ?? const []).whereType<Map>())
          Card(
            margin: const EdgeInsets.only(bottom: Gap.md),
            child: Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${g['title'] ?? ''}',
                    style: AType.titleMedium.copyWith(fontWeight: FontWeight.w800)),
                if ('${g['note'] ?? ''}'.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: Gap.xs),
                    child: Text('${g['note']}', style: AType.bodyMedium),
                  ),
                for (final l in officialLinks(g['links']))
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton.icon(
                      onPressed: () => _open(l.url),
                      icon: const Icon(Icons.open_in_new_rounded, size: 16),
                      label: Text(l.label),
                    ),
                  ),
              ]),
            ),
          ),
        if ('${d['books_note'] ?? ''}'.isNotEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${d['books_note']}', style: AType.bodyMedium),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    onPressed: () => _open('${d['books_source'] ?? ''}'),
                    icon: const Icon(Icons.menu_book_rounded, size: 16),
                    label: Text(tr.p3gOpenNctb),
                  ),
                ),
              ]),
            ),
          ),
        if ('${d['checked'] ?? ''}'.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Gap.md),
            child: Text(tr.p3gLastChecked(ld(context, p3gDate('${d['checked']}'))),
                key: const ValueKey('p3g-checked'), style: muted),
          ),
      ],
    );
  }
}

class _DeadlineDialog extends StatefulWidget {
  const _DeadlineDialog();
  @override
  State<_DeadlineDialog> createState() => _DeadlineDialogState();
}

class _DeadlineDialogState extends State<_DeadlineDialog> {
  final _title = TextEditingController();
  DateTime? _due;
  bool _saving = false;
  String? _err;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _due ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 3),
    );
    if (d != null) setState(() => _due = d);
  }

  String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _save() async {
    final tr = AppLocalizations.of(context);
    if (_title.text.trim().isEmpty || _due == null) {
      setState(() => _err = tr.studentTitleRequired);
      return;
    }
    setState(() {
      _saving = true;
      _err = null;
    });
    try {
      await context.read<AppState>().api.createItem(kStudentAssignPath, {
        'title': _title.text.trim(),
        'kind': 'deadline',
        'due_date': _iso(_due!),
        'done': false,
      });
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _err = tr.saveFailed;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final due = _due;
    return AlertDialog(
      scrollable: true,
      title: Text(tr.p3gSaveDeadline),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(
          key: const ValueKey('p3g-deadline-title'),
          controller: _title,
          maxLength: 80,
          buildCounter: localCounter,
          decoration: InputDecoration(labelText: tr.p3gDeadlineTitleHint),
        ),
        OutlinedButton.icon(
          key: const ValueKey('p3g-deadline-date'),
          onPressed: _pick,
          icon: const Icon(Icons.calendar_month_rounded),
          label: Text(due == null
              ? tr.p3gDeadlinePickDate
              : ld(context, p3gDate(_iso(due)))),
        ),
        if (_err != null)
          Padding(
            padding: const EdgeInsets.only(top: Gap.sm),
            child: Text(_err!, style: AType.bodyMedium.copyWith(color: scheme.error)),
          ),
      ]),
      actions: [
        TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context, false),
            child: Text(tr.cancel)),
        FilledButton(
          key: const ValueKey('p3g-deadline-save'),
          onPressed: _saving ? null : _save,
          child: Text(tr.save),
        ),
      ],
    );
  }
}
