import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../../services/error_kind.dart' show honestFailText;
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/local_counter.dart';
import '../../widgets/local_digits.dart';
import '../../widgets/skeleton.dart';

/// p2career (flag career_plus): CV style + language, summary, government-style
/// personal details, optional photo, the key-free ATS check, ATS-friendly PDF
/// (English, server reportlab) / print page (any language — the browser draws
/// Bangla conjuncts correctly), and AI polish through the server's AI router
/// (credits; never invents facts).
///
/// Reads/patches the SAME single `cv` row the builder uses (PATCH merges, so
/// the builder's fields are never touched from here except when the user
/// applies an AI polish — then this screen pops `true` and the builder
/// reloads). Zero Bangla literals: every string is an AppLocalizations getter.
class CvExportScreen extends StatefulWidget {
  final int recordId;
  const CvExportScreen({super.key, required this.recordId});

  @override
  State<CvExportScreen> createState() => _CvExportScreenState();
}

const _formats = ['fresher', 'experienced', 'govt'];
const _personalKeys = ['father', 'mother', 'dob', 'nationality', 'religion', 'permanent_address'];

class _CvExportScreenState extends State<CvExportScreen> {
  bool _loading = true, _busy = false, _changed = false;
  Object? _failCause;
  bool _failed = false;
  String _format = 'fresher';
  String _cvLang = 'en';
  String? _photo; // data: URI
  Map<String, dynamic>? _ats;
  final _summary = TextEditingController();
  final Map<String, TextEditingController> _personal = {
    for (final k in _personalKeys) k: TextEditingController(),
  };

  AppLocalizations get t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _cvLang = Localizations.localeOf(context).languageCode == 'bn' ? 'bn' : 'en';
      _load();
    });
  }

  @override
  void dispose() {
    _summary.dispose();
    for (final c in _personal.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final api = context.read<AppState>().api;
      final rows = await api.listItems('cv');
      final r = rows.firstWhere((x) => (x['id'] as num?)?.toInt() == widget.recordId,
          orElse: () => rows.isNotEmpty ? rows.first : <String, dynamic>{});
      final f = '${r['format'] ?? ''}';
      if (_formats.contains(f)) _format = f;
      final l = '${r['cv_lang'] ?? ''}';
      if (l == 'bn' || l == 'en') _cvLang = l;
      _summary.text = '${r['summary'] ?? ''}';
      final p = r['personal'] is Map ? (r['personal'] as Map) : const {};
      for (final k in _personalKeys) {
        _personal[k]!.text = '${p[k] ?? ''}';
      }
      final ph = r['photo'];
      _photo = ph is String && ph.startsWith('data:image/') ? ph : null;
      _ats = await api.getJson('/career/cv/ats');
    } catch (e) {
      _failed = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String m) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(m)));

  Future<bool> _patch(Map<String, dynamic> body) async {
    try {
      final api = context.read<AppState>().api;
      await api.updateItem('cv', widget.recordId, body);
      _ats = await api.getJson('/career/cv/ats');
      return true;
    } catch (_) {
      if (mounted) _toast(t.saveFailed);
      return false;
    }
  }

  Future<void> _saveDetails() async {
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    final ok = await _patch({
      'format': _format,
      'cv_lang': _cvLang,
      'summary': _summary.text.trim(),
      'personal': {for (final k in _personalKeys) k: _personal[k]!.text.trim()},
    });
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) _toast(t.crrSaved);
  }

  Future<void> _pickPhoto() async {
    try {
      final x = await ImagePicker()
          .pickImage(source: ImageSource.gallery, maxWidth: 400, maxHeight: 480, imageQuality: 70);
      if (x == null || !mounted) return;
      final bytes = await x.readAsBytes();
      if (bytes.length > 280000) {
        _toast(t.crrPhotoTooBig);
        return;
      }
      final uri = 'data:image/jpeg;base64,${base64Encode(bytes)}';
      setState(() => _busy = true);
      if (await _patch({'photo': uri}) && mounted) setState(() => _photo = uri);
    } catch (_) {
      if (mounted) _toast(t.crrPhotoFailed);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _removePhoto() async {
    setState(() => _busy = true);
    if (await _patch({'photo': ''}) && mounted) setState(() => _photo = null);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _downloadPdf() async {
    setState(() => _busy = true);
    try {
      await _saveDetailsQuiet();
      final api = context.read<AppState>().api;
      final bytes = await api.getBytes('/career/cv/pdf?lang=en');
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/assisto-cv.pdf');
      await f.writeAsBytes(bytes);
      await Share.shareXFiles([XFile(f.path, mimeType: 'application/pdf')]);
    } catch (_) {
      if (mounted) _toast(t.crrPdfFailed);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _saveDetailsQuiet() => _patch({
        'format': _format,
        'cv_lang': _cvLang,
        'summary': _summary.text.trim(),
        'personal': {for (final k in _personalKeys) k: _personal[k]!.text.trim()},
      });

  Future<void> _openPrint() async {
    setState(() => _busy = true);
    try {
      await _saveDetailsQuiet();
      if (!mounted) return;
      final r = await context.read<AppState>().api.postJson('/career/cv/print-link', {'lang': _cvLang});
      final ok = await launchUrl(Uri.parse('${r['url']}'), mode: LaunchMode.externalApplication);
      if (!ok && mounted) _toast(t.crrOpenFailed);
    } catch (_) {
      if (mounted) _toast(t.crrPdfFailed);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _polish() async {
    setState(() => _busy = true);
    Map<String, dynamic> r;
    try {
      await _saveDetailsQuiet();
      if (!mounted) return;
      r = await context.read<AppState>().api.postJson('/career/cv/polish', {'lang': _cvLang});
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        _toast(honestFailText(t, e));
      }
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (r['ai_used'] != true) {
      _toast('${r['message'] ?? t.crrAiNotReady}');
      return;
    }
    final summary = '${r['summary'] ?? ''}';
    final exp = (r['experience'] as List? ?? const []).whereType<Map>().toList();
    final use = await showAppSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (c) => AppSheetBody(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(t.crrAiResult, style: Theme.of(c).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(t.crrAiCheckNote, style: Theme.of(c).textTheme.bodySmall),
            const SizedBox(height: 12),
            if (summary.isNotEmpty) Text(summary),
            for (final e in exp)
              for (final b in (e['bullets'] as List? ?? const []))
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('• $b'),
                ),
            const SizedBox(height: 16),
            Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t.crrAiNotNow)),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(t.crrAiUse)),
            ]),
          ],
        ),
      ),
    );
    if (use != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final api = context.read<AppState>().api;
      final rows = await api.listItems('cv');
      final row = rows.firstWhere((x) => (x['id'] as num?)?.toInt() == widget.recordId,
          orElse: () => <String, dynamic>{});
      final cur = (row['experience'] as List? ?? const []).whereType<Map>().toList();
      final merged = <Map<String, dynamic>>[
        for (var i = 0; i < cur.length; i++)
          {
            ...cur[i].cast<String, dynamic>(),
            if (i < exp.length) 'bullets': (exp[i]['bullets'] as List? ?? const []).join('\n'),
          }
      ];
      if (await _patch({'summary': summary, 'experience': merged}) && mounted) {
        _summary.text = summary;
        _changed = true;
        _toast(t.crrAiApplied);
      }
    } catch (_) {
      if (mounted) _toast(t.saveFailed);
    }
    if (mounted) setState(() => _busy = false);
  }

  String _fmtLabel(String f) => switch (f) {
        'experienced' => t.crrFmtExperienced,
        'govt' => t.crrFmtGovt,
        _ => t.crrFmtFresher,
      };

  String _fmtHelp(String f) => switch (f) {
        'experienced' => t.crrFmtHelpExperienced,
        'govt' => t.crrFmtHelpGovt,
        _ => t.crrFmtHelpFresher,
      };

  String _atsLabel(String id) => switch (id) {
        'name' => t.crrAtsName,
        'phone' => t.crrAtsPhone,
        'email' => t.crrAtsEmail,
        'summary' => t.crrAtsSummary,
        'education' => t.crrAtsEducation,
        'skills' => t.crrAtsSkills,
        'experience' => t.crrAtsExperience,
        'numbers' => t.crrAtsNumbers,
        _ => t.crrAtsLength,
      };

  String _personalLabel(String k) => switch (k) {
        'father' => t.crrFather,
        'mother' => t.crrMother,
        'dob' => t.crrDob,
        'nationality' => t.crrNationality,
        'religion' => t.crrReligion,
        _ => t.crrPermAddress,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        appBar: AppBar(title: Text(t.crrCvExportTitle, maxLines: 2)),
        body: _loading
            ? const SkeletonList()
            : _failed
                ? StateMessage(
                    icon: Icons.cloud_off_rounded,
                    title: honestFailText(t, _failCause),
                    action: FilledButton.tonalIcon(
                        onPressed: _load, icon: const Icon(Icons.refresh_rounded), label: Text(t.retry)))
                : AbsorbPointer(
                    absorbing: _busy,
                    child: ListView(
                      padding: withNavBarInset(context, const EdgeInsets.fromLTRB(16, 12, 16, 32)),
                      children: [
                        if (_busy) const LinearProgressIndicator(),
                        _section(context, t.crrCvFormat, [
                          Wrap(spacing: 8, runSpacing: 8, children: [
                            for (final f in _formats)
                              ChoiceChip(
                                label: Text(_fmtLabel(f)),
                                selected: _format == f,
                                onSelected: (_) => setState(() => _format = f),
                              ),
                          ]),
                          const SizedBox(height: 8),
                          Text(_fmtHelp(_format), style: Theme.of(context).textTheme.bodySmall),
                          const SizedBox(height: 12),
                          Text(t.crrCvLang, style: Theme.of(context).textTheme.labelLarge),
                          const SizedBox(height: 6),
                          Wrap(spacing: 8, runSpacing: 8, children: [
                            ChoiceChip(
                                label: Text(t.crrLangBn),
                                selected: _cvLang == 'bn',
                                onSelected: (_) => setState(() => _cvLang = 'bn')),
                            ChoiceChip(
                                label: Text(t.crrLangEn),
                                selected: _cvLang == 'en',
                                onSelected: (_) => setState(() => _cvLang = 'en')),
                          ]),
                        ]),
                        _section(context, t.crrSummary, [
                          TextField(
                            controller: _summary,
                            minLines: 3,
                            maxLines: 6,
                            maxLength: 900,
                            buildCounter: localCounter,
                            decoration: InputDecoration(hintText: t.crrSummaryHint),
                          ),
                        ]),
                        if (_format == 'govt')
                          _section(context, t.crrPersonal, [
                            for (final k in _personalKeys)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: TextField(
                                  controller: _personal[k],
                                  maxLength: 200,
                                  buildCounter: localCounter,
                                  decoration: InputDecoration(labelText: _personalLabel(k)),
                                ),
                              ),
                          ]),
                        _section(context, t.crrPhoto, [
                          Text(t.crrPhotoHelp, style: Theme.of(context).textTheme.bodySmall),
                          const SizedBox(height: 8),
                          Row(children: [
                            if (_photo != null)
                              Padding(
                                padding: const EdgeInsetsDirectional.only(end: 12),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.memory(base64Decode(_photo!.split(',').last),
                                      width: 64, height: 76, fit: BoxFit.cover,
                                      semanticLabel: t.crrPhoto),
                                ),
                              ),
                            Expanded(
                              child: Wrap(spacing: 8, runSpacing: 8, children: [
                                OutlinedButton.icon(
                                    onPressed: _pickPhoto,
                                    icon: const Icon(Icons.add_a_photo_outlined),
                                    label: Text(t.crrPhotoAdd)),
                                if (_photo != null)
                                  TextButton.icon(
                                      onPressed: _removePhoto,
                                      icon: const Icon(Icons.delete_outline_rounded),
                                      label: Text(t.crrPhotoRemove)),
                              ]),
                            ),
                          ]),
                        ]),
                        Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: FilledButton.tonalIcon(
                              onPressed: _saveDetails,
                              icon: const Icon(Icons.save_outlined),
                              label: Text(t.crrSaveDetails)),
                        ),
                        const SizedBox(height: 8),
                        if (_ats != null) _atsCard(context, scheme),
                        _section(context, t.crrPdfTitle, [
                          if (_cvLang == 'en')
                            FilledButton.icon(
                                onPressed: _downloadPdf,
                                icon: const Icon(Icons.picture_as_pdf_outlined),
                                label: Text(t.crrPdfDownload)),
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                              onPressed: _openPrint,
                              icon: const Icon(Icons.print_outlined),
                              label: Text(t.crrPrintPage)),
                          const SizedBox(height: 8),
                          Text(t.crrPrintHelp, style: Theme.of(context).textTheme.bodySmall),
                        ]),
                        _section(context, t.crrAiPolish, [
                          Text(t.crrAiPolishHelp, style: Theme.of(context).textTheme.bodySmall),
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                              onPressed: _polish,
                              icon: const Icon(Icons.auto_fix_high_rounded),
                              label: Text(t.crrAiPolish)),
                        ]),
                      ],
                    ),
                  ),
      ),
    );
  }

  Widget _atsCard(BuildContext context, ColorScheme scheme) {
    final checks = (_ats!['checks'] as List? ?? const []).whereType<Map>().toList();
    final score = (_ats!['score'] as num?)?.toInt() ?? 0;
    return _section(context, t.crrAtsTitle, [
      Text(t.crrAtsScore(ld(context, score)),
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: score >= 80 ? AssistoTokens.of(context).success : scheme.onSurface, fontWeight: FontWeight.w700)),
      const SizedBox(height: 6),
      for (final c in checks)
        ListTile(
          contentPadding: EdgeInsets.zero,
          minVerticalPadding: 4,
          leading: Icon(c['ok'] == true ? Icons.check_circle_rounded : Icons.error_outline_rounded,
              color: c['ok'] == true ? AssistoTokens.of(context).success : scheme.error),
          title: Text(_atsLabel('${c['id']}')),
        ),
    ]);
  }

  Widget _section(BuildContext context, String title, List<Widget> children) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 10),
              ...children,
            ],
          ),
        ),
      );
}
