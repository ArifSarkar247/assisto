import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/skeleton.dart';
import '../../services/error_kind.dart' show honestFailText; // qa2

/// PA Secretary Mode · Letters / notices / memos — ADVANCED (#107, §14).
///
/// A formal-document generator. Pick a TYPE (letter / notice / memo /
/// application), fill a few fields (to / from / subject / body points / date),
/// and get a correctly-STRUCTURED formal document assembled from a fixed
/// template — the body is the owner's own words, formatted. The assembled
/// document is editable, copy/share-able and savable (as a 'pa/letters' row).
///
/// Honest "AI-generated — review" marker (the STRUCTURE is generated, nothing is
/// fabricated); a "connect an AI key for an AI-written body" seam is shown and
/// never fakes prose. The fixed formal phrases (date label, salutation,
/// closing, headings) are localised Bangla/English from the .arb — this file
/// has ZERO Bangla literals. All structure mirrors
/// backend/core/logic/pa_letters.py so previews are identical offline.
///
/// Endpoints (generic api helpers, no api.dart edit):
///   listItems('pa/letters')            → saved documents
///   createItem('pa/letters', body)     → save
///   updateItem('pa/letters', id, body) → re-save edits
///   deleteItem('pa/letters', id)       → remove
class LettersScreen extends StatefulWidget {
  const LettersScreen({super.key});
  @override
  State<LettersScreen> createState() => _LettersScreenState();
}

// ---- constants (mirror pa_letters.py) -------------------------------------
const String _tLetter = 'letter';
const String _tNotice = 'notice';
const String _tMemo = 'memo';
const String _tApplication = 'application';
const List<String> _types = [_tLetter, _tNotice, _tMemo, _tApplication];

// line roles
const String _rDate = 'date';
const String _rRecipient = 'recipient';
const String _rSender = 'sender';
const String _rSubject = 'subject';
const String _rHeading = 'heading';
const String _rSalutation = 'salutation';
const String _rBody = 'body';
const String _rClosing = 'closing';
const String _rLabel = 'label';

// neutral phrase keys → localised via _phrase()
const String _phTo = 'to';
const String _phFrom = 'from';
const String _phDate = 'date';
const String _phSubject = 'subject';
const String _phDear = 'dear';
const String _phRespected = 'respected';
const String _phYoursSincerely = 'yours_sincerely';
const String _phYoursFaithfully = 'yours_faithfully';
const String _phNotice = 'notice';
const String _phMemo = 'memo';

class _Line {
  final String role;
  final String text;
  final String phrase;
  const _Line(this.role, this.text, this.phrase);
}

class _LettersScreenState extends State<LettersScreen> {
  List<Map<String, dynamic>> _saved = [];
  bool _loading = true, _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

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
      _saved = await context.read<AppState>().api.listItems('pa/letters');
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _open(AppLocalizations tr, {Map<String, dynamic>? existing}) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => _LetterEditor(existing: existing)),
    );
    if (saved == true) await _load();
  }

  Future<void> _delete(Map<String, dynamic> r, AppLocalizations tr) async {
    final scheme = Theme.of(context).colorScheme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.paLetDeleteTitle),
        content: Text(tr.paLetDeleteBody((r['subject'] ?? '').toString())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr.cancel)),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: scheme.error, foregroundColor: scheme.onError),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr.delete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final id = r['id'];
    try {
      if (id is int) await context.read<AppState>().api.deleteItem('pa/letters', id);
      await _load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text(tr.deleteFailed)));
      }
    }
  }

  String _typeLabel(AppLocalizations tr, String t) {
    switch (t) {
      case _tNotice:
        return tr.paLetTypeNotice;
      case _tMemo:
        return tr.paLetTypeMemo;
      case _tApplication:
        return tr.paLetTypeApplication;
      default:
        return tr.paLetTypeLetter;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr.paLetTitle)),
      // qa1: the empty state already has this action as its CTA — one is enough
      floatingActionButton: (!_loading && !_error && _saved.isEmpty)
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _open(tr),
              icon: const Icon(Icons.add_rounded),
              label: Text(tr.paLetNew),
            ),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off_rounded,
                  tint: scheme.error,
                  title: tr.loadFailed,
                  message: honestFailText(tr, _failCause, otherwise: tr.paLetLoadError),
                  action: FilledButton.tonalIcon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(tr.retry)),
                )
              : _saved.isEmpty
                  ? StateMessage(
                      icon: Icons.description_rounded,
                      title: tr.paLetWelcomeTitle,
                      message: tr.paLetWelcomeBody,
                      action: FilledButton.icon(
                        onPressed: () => _open(tr),
                        icon: const Icon(Icons.add_rounded),
                        label: Text(tr.paLetNew),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.separated(
                        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
                        itemCount: _saved.length,
                        separatorBuilder: (_, __) => const SizedBox(height: Gap.sm),
                        itemBuilder: (_, i) {
                          final r = _saved[i];
                          final type = (r['type'] ?? _tLetter).toString();
                          return Card(
                            margin: EdgeInsets.zero,
                            child: ListTile(
                              leading: Icon(_typeIcon(type), color: scheme.primary),
                              title: Text((r['subject'] ?? '').toString(),
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(
                                  '${_typeLabel(tr, type)} · ${(r['to'] ?? '').toString()}',
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                              trailing: PopupMenuButton<String>(
                                onSelected: (v) {
                                  if (v == 'open') _open(tr, existing: r);
                                  if (v == 'delete') _delete(r, tr);
                                },
                                itemBuilder: (_) => [
                                  PopupMenuItem(value: 'open', child: Text(tr.paLetOpen)),
                                  PopupMenuItem(value: 'delete', child: Text(tr.delete)),
                                ],
                              ),
                              onTap: () => _open(tr, existing: r),
                            ),
                          );
                        },
                      ),
                    ),
    );
  }

  IconData _typeIcon(String t) {
    switch (t) {
      case _tNotice:
        return Icons.campaign_rounded;
      case _tMemo:
        return Icons.sticky_note_2_rounded;
      case _tApplication:
        return Icons.assignment_rounded;
      default:
        return Icons.mail_outline_rounded;
    }
  }
}

/// The compose / edit screen: fields + a live preview assembled exactly like
/// pa_letters.build(). Save writes a 'pa/letters' row.
class _LetterEditor extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _LetterEditor({this.existing});
  @override
  State<_LetterEditor> createState() => _LetterEditorState();
}

class _LetterEditorState extends State<_LetterEditor> {
  late String _type = _types.contains((widget.existing?['type'] ?? '').toString())
      ? widget.existing!['type'].toString()
      : _tLetter;
  late final TextEditingController _to =
      TextEditingController(text: widget.existing?['to']?.toString() ?? '');
  late final TextEditingController _from =
      TextEditingController(text: widget.existing?['from']?.toString() ?? '');
  late final TextEditingController _subject =
      TextEditingController(text: widget.existing?['subject']?.toString() ?? '');
  late final TextEditingController _body =
      TextEditingController(text: widget.existing?['body_points']?.toString() ?? '');
  late final TextEditingController _date =
      TextEditingController(text: widget.existing?['date']?.toString() ?? '');
  bool _saving = false;

  @override
  void dispose() {
    _to.dispose();
    _from.dispose();
    _subject.dispose();
    _body.dispose();
    _date.dispose();
    super.dispose();
  }

  // ---- deterministic mirror of pa_letters.build() --------------------------
  List<String> _points() => _body.text
      .replaceAll('\r\n', '\n')
      .split('\n')
      .map((s) => s.trim().replaceAll(RegExp(r'\s+'), ' '))
      .where((s) => s.isNotEmpty)
      .toList();

  List<_Line> _assemble() {
    final to = _to.text.trim();
    final from = _from.text.trim();
    final subject = _subject.text.trim();
    final date = _date.text.trim();
    final points = _points();
    final lines = <_Line>[];

    void body() {
      for (final p in points) {
        lines.add(_Line(_rBody, p, ''));
      }
    }

    switch (_type) {
      case _tMemo:
        lines.add(const _Line(_rHeading, '', _phMemo));
        lines.add(_Line(_rLabel, to, _phTo));
        lines.add(_Line(_rLabel, from, _phFrom));
        lines.add(_Line(_rLabel, date, _phDate));
        lines.add(_Line(_rLabel, subject, _phSubject));
        body();
        break;
      case _tNotice:
        lines.add(const _Line(_rHeading, '', _phNotice));
        if (date.isNotEmpty) lines.add(_Line(_rDate, date, _phDate));
        lines.add(_Line(_rSubject, subject, _phSubject));
        if (to.isNotEmpty) lines.add(_Line(_rRecipient, to, _phTo));
        body();
        break;
      case _tApplication:
        if (date.isNotEmpty) lines.add(_Line(_rDate, date, _phDate));
        lines.add(_Line(_rRecipient, to, _phTo));
        lines.add(_Line(_rSubject, subject, _phSubject));
        lines.add(const _Line(_rSalutation, '', _phRespected));
        body();
        lines.add(const _Line(_rClosing, '', _phYoursFaithfully));
        if (from.isNotEmpty) lines.add(_Line(_rSender, from, _phFrom));
        break;
      default: // letter
        if (date.isNotEmpty) lines.add(_Line(_rDate, date, _phDate));
        lines.add(_Line(_rRecipient, to, _phTo));
        lines.add(_Line(_rSubject, subject, _phSubject));
        lines.add(const _Line(_rSalutation, '', _phDear));
        body();
        lines.add(const _Line(_rClosing, '', _phYoursSincerely));
        if (from.isNotEmpty) lines.add(_Line(_rSender, from, _phFrom));
    }
    return lines;
  }

  List<String> _validate() {
    final problems = <String>[];
    if (_subject.text.trim().isEmpty) problems.add('empty_subject');
    if (_type != _tNotice && _to.text.trim().isEmpty) problems.add('empty_recipient');
    return problems;
  }

  String _phrase(AppLocalizations tr, String key) {
    switch (key) {
      case _phTo:
        return tr.paLetPhraseTo;
      case _phFrom:
        return tr.paLetPhraseFrom;
      case _phDate:
        return tr.paLetPhraseDate;
      case _phSubject:
        return tr.paLetPhraseSubject;
      case _phDear:
        return tr.paLetPhraseDear;
      case _phRespected:
        return tr.paLetPhraseRespected;
      case _phYoursSincerely:
        return tr.paLetPhraseYoursSincerely;
      case _phYoursFaithfully:
        return tr.paLetPhraseYoursFaithfully;
      case _phNotice:
        return tr.paLetPhraseNotice;
      case _phMemo:
        return tr.paLetPhraseMemo;
      default:
        return '';
    }
  }

  /// Render the structured lines to a single plain-text string (for copy/share
  /// and the preview body). Labelled/role lines get their localised phrase.
  String _render(AppLocalizations tr) {
    final out = <String>[];
    for (final ln in _assemble()) {
      switch (ln.role) {
        case _rHeading:
          out.add(_phrase(tr, ln.phrase).toUpperCase());
          out.add('');
          break;
        case _rLabel:
          out.add('${_phrase(tr, ln.phrase)}: ${ln.text}');
          break;
        case _rDate:
          out.add('${_phrase(tr, ln.phrase)}: ${ln.text}');
          break;
        case _rRecipient:
          out.add('${_phrase(tr, ln.phrase)} ${ln.text}');
          break;
        case _rSender:
          out.add('${_phrase(tr, ln.phrase)} ${ln.text}');
          break;
        case _rSubject:
          out.add('${_phrase(tr, ln.phrase)}: ${ln.text}');
          break;
        case _rSalutation:
          out.add('${_phrase(tr, ln.phrase)},');
          break;
        case _rClosing:
          out.add('');
          out.add('${_phrase(tr, ln.phrase)},');
          break;
        default: // body
          out.add(ln.text);
      }
    }
    return out.join('\n');
  }

  Future<void> _save(AppLocalizations tr) async {
    setState(() => _saving = true);
    final body = <String, dynamic>{
      'type': _type,
      'to': _to.text.trim(),
      'from': _from.text.trim(),
      'subject': _subject.text.trim(),
      'body_points': _body.text.trim(),
      'date': _date.text.trim(),
    };
    try {
      final api = context.read<AppState>().api;
      final id = widget.existing?['id'];
      if (id is int) {
        await api.updateItem('pa/letters', id, body);
      } else {
        await api.createItem('pa/letters', body);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text(tr.saveFailed)));
      }
    }
  }

  String _typeLabel(AppLocalizations tr, String t) {
    switch (t) {
      case _tNotice:
        return tr.paLetTypeNotice;
      case _tMemo:
        return tr.paLetTypeMemo;
      case _tApplication:
        return tr.paLetTypeApplication;
      default:
        return tr.paLetTypeLetter;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final problems = _validate();
    final rendered = _render(tr);
    return Scaffold(
      appBar: AppBar(title: Text(widget.existing == null ? tr.paLetNew : tr.paLetEdit)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 32),
        children: [
          Text(tr.paLetTypeLabel, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.sm, children: [
            for (final t in _types)
              ChoiceChip(
                label: Text(_typeLabel(tr, t)),
                selected: _type == t,
                onSelected: (_) => setState(() => _type = t),
              ),
          ]),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _to,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: _type == _tNotice ? tr.paLetToOptional : tr.paLetToField,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _from,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
                labelText: tr.paLetFromField, border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _subject,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
                labelText: tr.paLetSubjectField, border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _date,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
                labelText: tr.paLetDateField,
                helperText: tr.paLetDateHelp,
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _body,
            onChanged: (_) => setState(() {}),
            maxLines: 6,
            minLines: 4,
            decoration: InputDecoration(
              labelText: tr.paLetBodyField,
              helperText: tr.paLetBodyHelp,
              helperMaxLines: 2,
              border: const OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: Gap.md),
          _aiSeamCard(tr, scheme),
          const SizedBox(height: Gap.lg),
          Row(children: [
            Icon(Icons.info_outline_rounded, size: 15, color: scheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Expanded(
              child: Text(tr.f6BwTemplateMarker, // truth: template, not AI
                  style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5)),
            ),
          ]),
          const SizedBox(height: Gap.sm),
          Text(tr.paLetPreviewLabel,
              style: Theme.of(context)
                  .textTheme
                  .labelLarge
                  ?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.xs),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(Gap.md),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(Radii.sm),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: SelectableText(
              rendered.trim().isEmpty ? tr.paLetPreviewEmpty : rendered,
              style: const TextStyle(fontSize: 14, height: 1.5),
            ),
          ),
          const SizedBox(height: Gap.md),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: rendered));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context)
                    ..clearSnackBars()
                    ..showSnackBar(SnackBar(content: Text(tr.copied)));
                },
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: Text(tr.copy),
              ),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => Share.share(rendered),
                icon: const Icon(Icons.share_rounded, size: 18),
                label: Text(tr.share),
              ),
            ),
          ]),
          const SizedBox(height: Gap.sm),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: (problems.isEmpty && !_saving) ? () => _save(tr) : null,
              icon: const Icon(Icons.save_rounded, size: 18),
              label: Text(tr.save),
            ),
          ),
          if (problems.isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            Text(
              problems.contains('empty_subject')
                  ? tr.paLetNeedSubject
                  : tr.paLetNeedRecipient,
              style: TextStyle(color: scheme.error, fontSize: 12.5),
            ),
          ],
        ],
      ),
    );
  }

  Widget _aiSeamCard(AppLocalizations tr, ColorScheme scheme) => Container(
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Radii.sm),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.lock_outline_rounded, size: 18, color: scheme.primary),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr.paLetAiSeamTitle,
                  style: const TextStyle(fontWeight: FontWeight.w700, height: 1.4)),
              const SizedBox(height: 2),
              Text(tr.paLetAiSeamBody,
                  style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5, height: 1.4)),
            ]),
          ),
        ]),
      );
}
