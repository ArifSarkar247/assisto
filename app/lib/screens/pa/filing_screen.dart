import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/skeleton.dart';
import '../../services/error_kind.dart' show honestFailText; // qa2

/// PA SECRETARY MODE · DOCUMENT FILING cabinet — ADVANCED, KEY-GATED OCR
/// (#109, SPEC v2.1 §14 / §21).
///
/// A filing cabinet the PA keeps for the owner: file a document into a folder
/// (contracts / invoices / letters / reports / other), with a TITLE, free TAGS,
/// NOTES and a filing DATE, then SEARCH / FILTER the cabinet. It complements —
/// does not duplicate — the document scanner (#29) and the encrypted vault; the
/// focus here is ORGANISING correspondence into retrievable folders.
///
/// HONEST OCR, KEY-GATED: auto-READING a filed scan's text (OCR) is a DOCUMENTED
/// key-gated seam. Without an OCR key (Integrations → ocr) the cabinet works
/// fully as a MANUAL filing tool and NEVER fabricates extracted text — the UI
/// shows an honest "connect an OCR key to auto-extract text / title" card
/// (_OcrSeamCard). The whole tool works with no key.
///
/// STORAGE SEAM: this screen holds no server blob. A filed scan is referenced by
/// `image_ref` — an opaque handle the UI fills with a local path or a server
/// media id. The cabinet never reads it. `extracted_text` is NEVER fabricated
/// here; only the key-gated OCR seam fills it, and it becomes searchable then.
///
/// The on-screen logic mirrors backend/core/logic/pa_filing.py VERBATIM
/// (category coerce/suggest, tag normalise, validate, filter/search, counts) so
/// the live view is deterministic and identical offline. ZERO Bangla literals —
/// every string is an AppLocalizations getter.
///
/// Persistence (generic api helpers, no api.dart edit):
///   listItems('pa/filing') → [{id, title, category, image_ref, notes, date,
///                               tags, extracted_text}]
/// create / update / delete on the same path. Each row round-trips as
/// {id, ...build_item(...)} (PaCollectionItem precedent).
class FilingScreen extends StatefulWidget {
  const FilingScreen({super.key});
  @override
  State<FilingScreen> createState() => _FilingScreenState();
}

// Folder keys — mirror pa_filing.py CATEGORIES (first-seen order).
const List<String> _kCategories = [
  'contracts',
  'invoices',
  'letters',
  'reports',
  'other',
];

class _FilingScreenState extends State<FilingScreen> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true, _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

  String? _fCategory; // null ⇒ all folders
  String _query = '';
  String _tag = '';

  // OCR auto-read is key-gated (Integrations → ocr), owner-only. The honest
  // default is LOCKED here; a real auto-extract routes server-side when the
  // owner connects the `ocr` key. We NEVER fabricate extracted text.
  bool get _ocrReady => false;

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
      _rows = await context.read<AppState>().api.listItems('pa/filing');
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  // ---- deterministic mirror of pa_filing.py --------------------------------
  List<Map<String, dynamic>> get _filtered =>
      filterFiled(_rows, category: _fCategory, query: _query, tag: _tag);

  Map<String, int> get _counts => categoryCounts(_rows);
  List<String> get _tags => allFiledTags(_rows);

  // ---- actions -------------------------------------------------------------
  Future<void> _addOrEdit(AppLocalizations tr,
      {Map<String, dynamic>? existing}) async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _FilingForm(existing: existing, ocrReady: _ocrReady),
    );
    if (result == null) return;
    try {
      if (existing != null && existing['id'] is int) {
        await context
            .read<AppState>()
            .api
            .updateItem('pa/filing', existing['id'] as int, result);
      } else {
        await context.read<AppState>().api.createItem('pa/filing', result);
      }
      await _load();
      if (mounted) _toast(tr.paFileSaved);
    } catch (_) {
      if (mounted) _toast(tr.saveFailed);
    }
  }

  Future<void> _delete(Map<String, dynamic> r, AppLocalizations tr) async {
    final scheme = Theme.of(context).colorScheme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.paFileDeleteTitle),
        content: Text(tr.paFileDeleteBody((r['title'] ?? '').toString())),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: Text(tr.cancel)),
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
      if (id is int) {
        await context.read<AppState>().api.deleteItem('pa/filing', id);
      }
      await _load();
      if (mounted) _toast(tr.paFileDeleted);
    } catch (_) {
      if (mounted) _toast(tr.deleteFailed);
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---- build ---------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr.paFileTitle)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _loading ? null : () => _addOrEdit(tr),
        icon: const Icon(Icons.create_new_folder_outlined),
        label: Text(tr.paFileAdd),
      ),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off,
                  tint: scheme.error,
                  title: tr.loadFailed,
                  message: honestFailText(tr, _failCause, otherwise: tr.paFileLoadError),
                  action: FilledButton.tonalIcon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label: Text(tr.retry)),
                )
              : _rows.isEmpty
                  ? _welcome(tr)
                  : _cabinet(tr, scheme),
    );
  }

  Widget _welcome(AppLocalizations tr) => ListView(
        padding: const EdgeInsets.all(Gap.lg),
        children: [
          StateMessage(
            icon: Icons.folder_copy_outlined,
            tint: Brand.blue,
            title: tr.paFileWelcomeTitle,
            message: tr.paFileWelcomeBody,
            action: FilledButton.icon(
              onPressed: () => _addOrEdit(tr),
              icon: const Icon(Icons.create_new_folder_outlined),
              label: Text(tr.paFileAdd),
            ),
          ),
          const SizedBox(height: Gap.lg),
          _OcrSeamCard(ready: _ocrReady),
        ],
      );

  Widget _cabinet(AppLocalizations tr, ColorScheme scheme) {
    final list = _filtered;
    return Column(children: [
      _OcrSeamCard(ready: _ocrReady),
      _folderBar(tr),
      _searchBar(tr),
      if (_tags.isNotEmpty) _tagBar(tr),
      Expanded(
        child: list.isEmpty
            ? StateMessage(
                icon: Icons.search_off,
                title: tr.paFileNoMatchTitle,
                message: tr.paFileNoMatchBody,
                action: TextButton(
                  onPressed: () => setState(() {
                    _fCategory = null;
                    _query = '';
                    _tag = '';
                  }),
                  child: Text(tr.paFileClearFilters),
                ),
              )
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView.separated(
                  padding:
                      const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, 96),
                  itemCount: list.length,
                  separatorBuilder: (_, __) => const SizedBox(height: Gap.sm),
                  itemBuilder: (_, i) => _card(list[i], tr, scheme),
                ),
              ),
      ),
    ]);
  }

  Widget _folderBar(AppLocalizations tr) {
    final c = _counts;
    Widget chip(String label, bool selected, VoidCallback onTap) => Padding(
          padding: const EdgeInsets.only(right: Gap.sm),
          child: FilterChip(
            label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            selected: selected,
            onSelected: (_) => onTap(),
          ),
        );
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding:
            const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
        children: [
          chip(tr.paFileFolderAll('${c['total'] ?? 0}'), _fCategory == null,
              () => setState(() => _fCategory = null)),
          for (final cat in _kCategories)
            chip(
              '${_categoryLabel(tr, cat)} (${c[cat] ?? 0})',
              _fCategory == cat,
              () => setState(
                  () => _fCategory = _fCategory == cat ? null : cat),
            ),
        ],
      ),
    );
  }

  Widget _searchBar(AppLocalizations tr) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.sm),
        child: TextField(
          onChanged: (v) => setState(() => _query = v),
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.search),
            hintText: tr.paFileSearchHint,
            border: const OutlineInputBorder(),
          ),
        ),
      );

  Widget _tagBar(AppLocalizations tr) => SizedBox(
        height: 44,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: Gap.md),
          children: [
            for (final tg in _tags)
              Padding(
                padding: const EdgeInsets.only(right: Gap.sm),
                child: FilterChip(
                  avatar: const Icon(Icons.sell_outlined, size: 16),
                  label: Text(tg),
                  selected: _tag == tg,
                  onSelected: (_) =>
                      setState(() => _tag = _tag == tg ? '' : tg),
                ),
              ),
          ],
        ),
      );

  Widget _card(
      Map<String, dynamic> r, AppLocalizations tr, ColorScheme scheme) {
    final cat = normaliseCategory(r['category']);
    final tags = normaliseFiledTags(r['tags']);
    final notes = (r['notes'] ?? '').toString().trim();
    final dateStr = (r['date'] ?? '').toString().trim();
    final extracted = (r['extracted_text'] ?? '').toString().trim();
    final hasImage = (r['image_ref'] ?? '').toString().trim().isNotEmpty;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(_categoryIcon(cat), size: 20, color: scheme.primary),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text((r['title'] ?? '').toString(),
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 15),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: (v) {
                if (v == 'edit') _addOrEdit(tr, existing: r);
                if (v == 'delete') _delete(r, tr);
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'edit', child: Text(tr.edit)),
                PopupMenuItem(value: 'delete', child: Text(tr.delete)),
              ],
            ),
          ]),
          const SizedBox(height: 4),
          Wrap(spacing: Gap.sm, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            _pill(_categoryLabel(tr, cat), scheme.primary),
            if (hasImage)
              _meta(Icons.image_outlined, tr.paFileScanAttached, scheme),
            if (dateStr.isNotEmpty)
              _meta(Icons.event, _fmtDate(dateStr, tr), scheme),
          ]),
          if (notes.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            Text(notes,
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.3),
                maxLines: 3,
                overflow: TextOverflow.ellipsis),
          ],
          if (tags.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            Wrap(spacing: 6, runSpacing: 4, children: [
              for (final tg in tags) _pill('#$tg', Brand.purple),
            ]),
          ],
          // HONEST: extracted text only appears once the key-gated OCR seam
          // fills it server-side. We never fabricate it; when absent and no key
          // is connected, the seam card above explains how to enable it.
          if (extracted.isNotEmpty) ...[
            const Divider(height: Gap.xl),
            Row(children: [
              Icon(Icons.text_snippet_outlined,
                  size: 15, color: scheme.secondary),
              const SizedBox(width: 4),
              Text(tr.paFileExtractedLabel,
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: scheme.secondary)),
            ]),
            const SizedBox(height: 2),
            Text(extracted,
                style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                maxLines: 4,
                overflow: TextOverflow.ellipsis),
          ],
        ]),
      ),
    );
  }

  String _categoryLabel(AppLocalizations tr, String c) {
    switch (c) {
      case 'contracts':
        return tr.paFileCatContracts;
      case 'invoices':
        return tr.paFileCatInvoices;
      case 'letters':
        return tr.paFileCatLetters;
      case 'reports':
        return tr.paFileCatReports;
      default:
        return tr.paFileCatOther;
    }
  }

  IconData _categoryIcon(String c) {
    switch (c) {
      case 'contracts':
        return Icons.handshake_outlined;
      case 'invoices':
        return Icons.receipt_long_outlined;
      case 'letters':
        return Icons.mail_outline;
      case 'reports':
        return Icons.assessment_outlined;
      default:
        return Icons.description_outlined;
    }
  }

  String _fmtDate(String iso, AppLocalizations tr) {
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    return DateFormat('d MMM yyyy', tr.localeName).format(d);
  }

  Widget _pill(String text, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 3),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(Radii.pill),
        ),
        child: Text(text,
            style: TextStyle(
                color: c, fontSize: 11.5, fontWeight: FontWeight.w700)),
      );

  Widget _meta(IconData icon, String text, ColorScheme scheme) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: scheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(text,
              style:
                  TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
        ],
      );
}

/// Honest key-gated OCR seam card. Shows the "connect an OCR key to auto-extract
/// text / title" state when no key is connected; a short "auto-read available"
/// note otherwise. It NEVER fabricates extracted text.
class _OcrSeamCard extends StatelessWidget {
  final bool ready;
  const _OcrSeamCard({required this.ready});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 0),
      child: Card(
        margin: EdgeInsets.zero,
        color: scheme.secondaryContainer.withValues(alpha: 0.4),
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(ready ? Icons.auto_awesome : Icons.lock_outline,
                size: 20, color: scheme.secondary),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(ready ? tr.paFileOcrReadyTitle : tr.paFileOcrSeamTitle,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(ready ? tr.paFileOcrReadyBody : tr.paFileOcrSeamBody,
                        style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                            height: 1.35)),
                  ]),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Add / edit form — bottom sheet. Returns the body map (build_item shape) or
/// null on cancel.
class _FilingForm extends StatefulWidget {
  final Map<String, dynamic>? existing;
  final bool ocrReady;
  const _FilingForm({this.existing, required this.ocrReady});
  @override
  State<_FilingForm> createState() => _FilingFormState();
}

class _FilingFormState extends State<_FilingForm> {
  late final TextEditingController _title =
      TextEditingController(text: widget.existing?['title']?.toString() ?? '');
  late final TextEditingController _notes =
      TextEditingController(text: widget.existing?['notes']?.toString() ?? '');
  late final TextEditingController _tags = TextEditingController(
      text: normaliseFiledTags(widget.existing?['tags']).join(', '));
  late String _category =
      normaliseCategory(widget.existing?['category'] ?? 'other');
  DateTime? _date;
  bool _touchedCategory = false;

  @override
  void initState() {
    super.initState();
    final d = widget.existing?['date'];
    if (d != null) _date = DateTime.tryParse(d.toString());
    if (widget.existing != null) _touchedCategory = true;
  }

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    _tags.dispose();
    super.dispose();
  }

  // Suggest a folder from the title as the user types (deterministic mirror of
  // suggest_category) — only until they pick one explicitly.
  void _maybeSuggest() {
    if (_touchedCategory) return;
    final guess = suggestCategory(_title.text, _notes.text);
    if (guess != _category) setState(() => _category = guess);
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final insets = MediaQuery.of(context).viewInsets.bottom;
    final fmt = DateFormat('d MMM yyyy', tr.localeName);
    final titleOk = _title.text.trim().isNotEmpty;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + insets),
      child: SingleChildScrollView(
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.existing == null ? tr.paFileAdd : tr.paFileEdit,
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: Gap.lg),
              TextField(
                controller: _title,
                onChanged: (_) {
                  setState(() {});
                  _maybeSuggest();
                },
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                    labelText: tr.paFileTitleLabel,
                    hintText: tr.paFileTitleHint,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              Text(tr.paFileFolderLabel,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: Gap.xs),
              Wrap(spacing: Gap.sm, children: [
                for (final cat in _kCategories)
                  ChoiceChip(
                    label: Text(_catLabel(tr, cat)),
                    selected: _category == cat,
                    onSelected: (_) => setState(() {
                      _category = cat;
                      _touchedCategory = true;
                    }),
                  ),
              ]),
              const SizedBox(height: Gap.md),
              TextField(
                controller: _tags,
                decoration: InputDecoration(
                    labelText: tr.paFileTagsLabel,
                    hintText: tr.paFileTagsHint,
                    helperText: tr.paFileTagsHelper,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              OutlinedButton.icon(
                onPressed: () async {
                  final base = _date ?? DateTime.now();
                  final d = await showDatePicker(
                    context: context,
                    initialDate: base,
                    firstDate: DateTime(base.year - 10),
                    lastDate: DateTime(base.year + 5),
                  );
                  if (d != null) setState(() => _date = d);
                },
                icon: const Icon(Icons.event),
                label: Text(_date == null
                    ? tr.paFileSetDate
                    : fmt.format(_date!)),
              ),
              const SizedBox(height: Gap.md),
              TextField(
                controller: _notes,
                onChanged: (_) => _maybeSuggest(),
                maxLines: 3,
                decoration: InputDecoration(
                    labelText: tr.paFileNotesLabel,
                    border: const OutlineInputBorder()),
              ),
              const SizedBox(height: Gap.md),
              // Honest OCR seam inside the form: filing a scan is manual; an
              // auto-read needs the key and NEVER fabricates text.
              _OcrSeamCard(ready: widget.ocrReady),
              const SizedBox(height: Gap.lg),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(tr.cancel),
                  ),
                ),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: FilledButton(
                    onPressed: titleOk ? _save : null,
                    child: Text(tr.save),
                  ),
                ),
              ]),
            ]),
      ),
    );
  }

  void _save() {
    final body = buildFiledItem(
      title: _title.text,
      category: _category,
      imageRef: (widget.existing?['image_ref'] ?? '').toString(),
      notes: _notes.text,
      date: _date == null
          ? ''
          : DateFormat('yyyy-MM-dd').format(_date!),
      tags: _tags.text,
    );
    // Preserve any already-extracted text (filled only by the OCR seam) so an
    // edit never drops it; we never invent it here.
    final ex = (widget.existing?['extracted_text'] ?? '').toString();
    if (ex.isNotEmpty) body['extracted_text'] = ex;
    Navigator.pop(context, body);
  }

  String _catLabel(AppLocalizations tr, String c) {
    switch (c) {
      case 'contracts':
        return tr.paFileCatContracts;
      case 'invoices':
        return tr.paFileCatInvoices;
      case 'letters':
        return tr.paFileCatLetters;
      case 'reports':
        return tr.paFileCatReports;
      default:
        return tr.paFileCatOther;
    }
  }
}

// ======================================================================
// On-device Dart mirror of backend/core/logic/pa_filing.py.
// DETERMINISTIC organiser — normalise/suggest a category, normalise tags,
// validate, filter/search, tally. PURE: holds no bytes, runs NO OCR, invents
// nothing. The honest OCR seam is key-gated (Integrations `ocr`) and routed
// elsewhere; extracted_text is NEVER fabricated here.
// ======================================================================

const Map<String, List<String>> _categoryHints = {
  'contracts': [
    'contract', 'agreement', 'mou', 'nda', 'deed', 'lease', 'tenancy', 'chukti',
  ],
  'invoices': [
    'invoice', 'bill', 'receipt', 'voucher', 'payment', 'memo', 'quotation',
    'challan',
  ],
  'letters': [
    'letter', 'memo to', 'notice', 'circular', 'application', 'cover letter',
    'chithi',
  ],
  'reports': [
    'report', 'summary', 'statement', 'minutes', 'audit', 'survey', 'analysis',
  ],
};

String _cleanF(String? s) =>
    (s ?? '').trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');

String normaliseCategory(dynamic category) {
  final c = _cleanF(category?.toString()).toLowerCase();
  return _kCategories.contains(c) ? c : 'other';
}

/// Coerce tags (a List or a comma/newline string) into a de-duped, lower-cased
/// list in first-seen order. Mirrors pa_filing.py::normalise_tags.
List<String> normaliseFiledTags(dynamic tags) {
  final raw = <String>[];
  if (tags is String) {
    raw.addAll(tags.replaceAll('\n', ',').split(','));
  } else if (tags is List) {
    raw.addAll(tags.map((e) => e.toString()));
  }
  final out = <String>[];
  final seen = <String>{};
  for (final t in raw) {
    final c = _cleanF(t).toLowerCase();
    if (c.isNotEmpty && !seen.contains(c)) {
      seen.add(c);
      out.add(c);
    }
  }
  return out;
}

/// Deterministic FALLBACK folder guess from title/notes keywords. Not OCR.
/// First matching category in _kCategories order wins. Mirrors suggest_category.
String suggestCategory(String title, [String notes = '']) {
  final hay = '${_cleanF(title)} ${_cleanF(notes)}'.toLowerCase();
  for (final cat in _kCategories) {
    for (final kw in (_categoryHints[cat] ?? const <String>[])) {
      if (hay.contains(kw)) return cat;
    }
  }
  return 'other';
}

/// Problem keys (empty ⇒ valid). The UI localises these.
List<String> validateFiled(String title, {String category = 'other'}) {
  final out = <String>[];
  if (_cleanF(title).isEmpty) out.add('title_required');
  if (!_kCategories.contains(_cleanF(category).toLowerCase())) {
    out.add('bad_category');
  }
  return out;
}

/// Normalise one document into the stored row shape. `extracted_text` is ALWAYS
/// '' here — only the key-gated OCR seam fills it; never fabricated. Mirrors
/// pa_filing.py::build_item.
Map<String, dynamic> buildFiledItem({
  required String title,
  String category = 'other',
  String imageRef = '',
  String notes = '',
  String date = '',
  dynamic tags,
}) {
  final t = _cleanF(title);
  final cat = normaliseCategory(category);
  final ref = _cleanF(imageRef);
  return {
    'title': t,
    'category': cat,
    'image_ref': ref,
    'notes': _cleanF(notes),
    'date': _cleanF(date),
    'tags': normaliseFiledTags(tags),
    'has_image': ref.isNotEmpty,
    'extracted_text': '', // never fabricated; OCR seam fills it
    'ocr_state': 'ocr_locked',
    'ai_required': false,
    'mock': true,
    'problems': validateFiled(t, category: category),
  };
}

/// Filter + search a list of filed rows. Mirrors pa_filing.py::filter_items.
List<Map<String, dynamic>> filterFiled(
  List<Map<String, dynamic>> items, {
  String? category,
  String query = '',
  String tag = '',
}) {
  final q = _cleanF(query).toLowerCase();
  final tg = _cleanF(tag).toLowerCase();
  String? want;
  final c = _cleanF(category).toLowerCase();
  if (category != null && c.isNotEmpty && c != 'all') {
    want = normaliseCategory(category);
  }
  final out = <Map<String, dynamic>>[];
  for (final it in items) {
    final cat = normaliseCategory(it['category']);
    if (want != null && cat != want) continue;
    final itemTags = normaliseFiledTags(it['tags']);
    if (tg.isNotEmpty && !itemTags.contains(tg)) continue;
    if (q.isNotEmpty) {
      final hay = [
        _cleanF(it['title']?.toString()),
        _cleanF(it['notes']?.toString()),
        itemTags.join(' '),
        _cleanF(it['extracted_text']?.toString()),
      ].join(' ').toLowerCase();
      if (!hay.contains(q)) continue;
    }
    out.add(it);
  }
  return out;
}

/// Per-category tally (every category zero-filled) + total. Mirrors
/// pa_filing.py::category_counts.
Map<String, int> categoryCounts(List<Map<String, dynamic>> items) {
  final counts = {for (final c in _kCategories) c: 0};
  var total = 0;
  for (final it in items) {
    final c = normaliseCategory(it['category']);
    counts[c] = (counts[c] ?? 0) + 1;
    total++;
  }
  counts['total'] = total;
  return counts;
}

/// Sorted, de-duped set of every tag across the cabinet. Mirrors all_tags.
List<String> allFiledTags(List<Map<String, dynamic>> items) {
  final seen = <String>{};
  for (final it in items) {
    seen.addAll(normaliseFiledTags(it['tags']));
  }
  final out = seen.toList()..sort();
  return out;
}
