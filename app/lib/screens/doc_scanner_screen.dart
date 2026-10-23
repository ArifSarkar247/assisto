import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import '../widgets/permission_reason.dart';
import '../services/error_kind.dart' show honestFailText; // qa2

/// DOCUMENT SCANNER / organiser — ADVANCED, KEY-GATED OCR (#29, SPEC v2.1 §21).
///
/// A document CAPTURE + ORGANISE tool. The user adds a document (a photo from
/// the camera/gallery picker, or a plain manual entry), gives it a TITLE +
/// optional NOTES, TAGS it by type (NID / passport / certificate / bill /
/// receipt / other), and gets a searchable, filterable list back. This
/// COMPLEMENTS — does not duplicate — the secure vault: the focus here is
/// scan/organise/tag, not encrypted storage.
///
/// HONEST OCR, KEY-GATED: reading text OUT of the image (OCR) is a DOCUMENTED
/// key-gated seam. Without an OCR key (Integrations → ocr) the tool works fully
/// as a manual organiser and NEVER fabricates extracted text — the UI shows an
/// honest "connect an OCR key to auto-read text" state. The whole tool works
/// with no key.
///
/// STORAGE SEAM: this screen holds no server blob. A document's image is
/// referenced by `image_ref` — the local file path from the picker (the way
/// other media screens keep a local path). A future upload through an existing
/// media endpoint could swap in a server document id; the organiser treats
/// `image_ref` as an opaque handle.
///
/// The on-screen logic mirrors backend/core/logic/doc_scanner.py VERBATIM
/// (type coerce/suggest, validate, filter/search, type counts) so the live view
/// is deterministic and identical offline. ZERO Bangla literals — every string
/// is an AppLocalizations getter.
///
/// Persistence (generic api helpers, no api.dart edit):
///   listItems('docscan/items') → [{id, title, doc_type, image_ref, notes,
///                                   date, extracted_text}]
/// create/delete on the same path. Each row round-trips as {id, ...data}
/// through one flexible per-user JSON collection (PaCollectionItem precedent).
class DocScannerScreen extends StatefulWidget {
  const DocScannerScreen({super.key});
  @override
  State<DocScannerScreen> createState() => _DocScannerScreenState();
}

const String _itemsPath = 'docscan/items';

// Kept in lockstep with doc_scanner.py DOC_TYPES.
const List<String> _docTypes = [
  'nid',
  'passport',
  'certificate',
  'bill',
  'receipt',
  'other'
];

String _today() {
  final n = DateTime.now();
  return '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
}

class _DocScannerScreenState extends State<DocScannerScreen> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true, _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

  String _filter = 'all'; // 'all' or a DOC_TYPE
  final TextEditingController _search = TextEditingController();

  // OCR is key-gated. There is no client-visible key check here (owner-only),
  // so the honest default is LOCKED: the UI shows "connect an OCR key". A real
  // auto-read is routed server-side when the owner connects the `ocr` key.
  bool get _ocrReady => false;

  AppLocalizations get t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      _items = await context.read<AppState>().api.listItems(_itemsPath);
    } catch (e) {
      _error = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String msg) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(msg)));

  Future<String?> _pickImage() async {
    final src = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: Text(AppLocalizations.of(ctx).camera),
            onTap: () => Navigator.pop(ctx, ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: Text(AppLocalizations.of(ctx).gallery),
            onTap: () => Navigator.pop(ctx, ImageSource.gallery),
          ),
        ]),
      ),
    );
    if (src == null) return null;
    if (src == ImageSource.camera && mounted) {
      if (!await showPermissionReason(context, PermKind.camera)) return null;
    }
    final x = await ImagePicker().pickImage(source: src, imageQuality: 70);
    return x?.path; // local path handle — the organiser never reads it
  }

  Future<void> _addOrEdit([Map<String, dynamic>? existing]) async {
    final title =
        TextEditingController(text: (existing?['title'] ?? '').toString());
    final notes =
        TextEditingController(text: (existing?['notes'] ?? '').toString());
    String type = normaliseType((existing?['doc_type'] ?? 'other').toString());
    String? imageRef = (existing?['image_ref'] ?? '').toString().isEmpty
        ? null
        : (existing?['image_ref']).toString();
    bool typeTouched = existing != null;

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final t = AppLocalizations.of(ctx);
        return StatefulBuilder(builder: (ctx, setM) {
          return Padding(
            padding: EdgeInsets.only(
              left: Gap.lg,
              right: Gap.lg,
              top: Gap.lg,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + Gap.lg,
            ),
            child: SingleChildScrollView(
              child:
                  Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(existing == null ? t.dsAddTitle : t.dsEditTitle,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: Gap.lg),
                TextField(
                  controller: title,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    labelText: t.dsFieldTitle,
                    hintText: t.dsFieldTitleHint,
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (v) {
                    if (!typeTouched) {
                      final g = suggestType(v, notes.text);
                      setM(() => type = g);
                    }
                  },
                ),
                const SizedBox(height: Gap.lg),
                Text(t.dsType,
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
                const SizedBox(height: Gap.sm),
                Wrap(
                  spacing: Gap.sm,
                  runSpacing: Gap.sm,
                  children: [
                    for (final ty in _docTypes)
                      ChoiceChip(
                        selected: ty == type,
                        onSelected: (_) => setM(() {
                          type = ty;
                          typeTouched = true;
                        }),
                        avatar: Icon(_typeIcon(ty), size: 16),
                        label: Text(_typeLabel(t, ty)),
                      ),
                  ],
                ),
                const SizedBox(height: Gap.lg),
                TextField(
                  controller: notes,
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText: t.dsNotes,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: Gap.lg),
                OutlinedButton.icon(
                  onPressed: () async {
                    final p = await _pickImage();
                    if (p != null) setM(() => imageRef = p);
                  },
                  icon: const Icon(Icons.add_a_photo_outlined, size: 18),
                  label: Text(imageRef == null ? t.dsAddImage : t.dsChangeImage),
                ),
                if (imageRef != null) ...[
                  const SizedBox(height: Gap.xs),
                  Text(t.dsImageAttached,
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(ctx).colorScheme.primary)),
                ],
                const SizedBox(height: Gap.lg),
                // honest key-gated OCR seam
                _OcrSeamCard(ready: _ocrReady),
                const SizedBox(height: Gap.lg),
                Row(children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: Text(t.cancel),
                    ),
                  ),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: FilledButton(
                      onPressed: () {
                        if (title.text.trim().isEmpty) {
                          ScaffoldMessenger.of(ctx)
                            ..clearSnackBars()
                            ..showSnackBar(
                                SnackBar(content: Text(t.dsTitleRequired)));
                          return;
                        }
                        Navigator.pop(ctx, true);
                      },
                      child: Text(t.save),
                    ),
                  ),
                ]),
              ]),
            ),
          );
        });
      },
    );

    if (saved != true) return;
    final body = {
      'title': title.text.trim(),
      'doc_type': type,
      'image_ref': imageRef ?? '',
      'notes': notes.text.trim(),
      'date': (existing?['date'] ?? _today()).toString(),
      // HONEST: never fabricated here; only the key-gated OCR seam fills it.
      'extracted_text': (existing?['extracted_text'] ?? '').toString(),
    };
    try {
      if (existing != null && existing['id'] != null) {
        await context
            .read<AppState>()
            .api
            .updateItem(_itemsPath, (existing['id'] as num).toInt(), body);
      } else {
        await context.read<AppState>().api.createItem(_itemsPath, body);
      }
      await _load();
      if (mounted) _toast(t.dsSaved);
    } catch (_) {
      if (mounted) _toast(t.saveFailed);
    }
  }

  Future<void> _delete(Map<String, dynamic> d) async {
    final id = (d['id'] as num?)?.toInt();
    if (id == null) return;
    try {
      await context.read<AppState>().api.deleteItem(_itemsPath, id);
      await _load();
      if (mounted) _toast(t.commonDeleted);
    } catch (_) {
      if (mounted) _toast(t.saveFailed);
    }
  }

  List<Map<String, dynamic>> get _visible =>
      filterDocs(_items, docType: _filter, query: _search.text);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.dsTitle)),
      floatingActionButton: _items.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _addOrEdit(),
              icon: const Icon(Icons.add_a_photo_outlined),
              label: Text(t.dsAddTitle),
            ),
      body: _loading
          ? const SkeletonList(count: 5)
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off,
                  tint: scheme.error,
                  title: t.loadFailed,
                  message: honestFailText(t, _failCause, otherwise: t.dsLoadError),
                  action: FilledButton.tonalIcon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label: Text(t.retry)),
                )
              : _body(),
    );
  }

  Widget _body() {
    final counts = typeCounts(_items);
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.sm),
        child: TextField(
          controller: _search,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: t.dsSearchHint,
            isDense: true,
            border: const OutlineInputBorder(),
            suffixIcon: _search.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () => setState(() => _search.clear()),
                  ),
          ),
        ),
      ),
      SizedBox(
        height: 44,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
          children: [
            _filterChip('all', t.dsFilterAll, counts['total'] ?? 0),
            for (final ty in _docTypes)
              _filterChip(ty, _typeLabel(t, ty), counts[ty] ?? 0),
          ],
        ),
      ),
      const SizedBox(height: Gap.sm),
      Expanded(child: _list()),
    ]);
  }

  Widget _filterChip(String value, String label, int count) {
    return Padding(
      padding: const EdgeInsets.only(right: Gap.sm),
      child: FilterChip(
        selected: _filter == value,
        onSelected: (_) => setState(() => _filter = value),
        label: Text(count > 0 ? '$label ($count)' : label),
      ),
    );
  }

  Widget _list() {
    final vis = _visible;
    if (_items.isEmpty) {
      return StateMessage(
        icon: Icons.document_scanner_outlined,
        title: t.dsEmptyTitle,
        message: t.dsEmptyBody,
        action: FilledButton.tonalIcon(
          onPressed: () => _addOrEdit(),
          icon: const Icon(Icons.add_a_photo_outlined, size: 18),
          label: Text(t.dsAddTitle),
        ),
      );
    }
    if (vis.isEmpty) {
      return StateMessage(
        icon: Icons.search_off,
        title: t.dsNoMatchTitle,
        message: t.dsNoMatchBody,
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xxl),
        itemCount: vis.length,
        separatorBuilder: (_, __) => const SizedBox(height: Gap.md),
        itemBuilder: (_, i) => _tile(vis[i]),
      ),
    );
  }

  Widget _tile(Map<String, dynamic> d) {
    final scheme = Theme.of(context).colorScheme;
    final type = normaliseType((d['doc_type'] ?? 'other').toString());
    final notes = (d['notes'] ?? '').toString().trim();
    final hasImage = (d['image_ref'] ?? '').toString().trim().isNotEmpty;
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        onTap: () => _addOrEdit(d),
        leading: CircleAvatar(
          backgroundColor: scheme.secondaryContainer,
          child: Icon(_typeIcon(type),
              size: 20, color: scheme.onSecondaryContainer),
        ),
        title: Text((d['title'] ?? '').toString(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Text(_typeLabel(t, type),
                    style: TextStyle(color: scheme.onSurfaceVariant)),
                if (hasImage) ...[
                  const SizedBox(width: Gap.sm),
                  Icon(Icons.image_outlined,
                      size: 14, color: scheme.onSurfaceVariant),
                ],
              ]),
              if (notes.isNotEmpty)
                Text(notes,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: scheme.onSurfaceVariant, fontSize: 12.5)),
            ]),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: t.delete,
          onPressed: () => _delete(d),
        ),
      ),
    );
  }
}

// ======================================================================
// On-device Dart mirror of backend/core/logic/doc_scanner.py.
// DETERMINISTIC organiser — normalise/suggest a type, validate, filter/search,
// tally. PURE: holds no bytes, runs NO OCR, invents nothing. The honest OCR
// seam is key-gated (Integrations `ocr`) and routed elsewhere; extracted text
// is NEVER fabricated here.
// ======================================================================

const Map<String, List<String>> _typeHints = {
  'nid': ['nid', 'national id', 'smart card', 'voter'],
  'passport': ['passport', 'mrp', 'e-passport'],
  'certificate': [
    'certificate',
    'certi',
    'degree',
    'diploma',
    'marksheet',
    'transcript',
    'ssc',
    'hsc'
  ],
  'bill': [
    'bill',
    'invoice',
    'utility',
    'electric',
    'gas',
    'water',
    'wasa',
    'desco',
    'palli'
  ],
  'receipt': ['receipt', 'memo', 'voucher', 'payment slip', 'money receipt'],
};

String _clean(String? s) =>
    (s ?? '').trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');

String normaliseType(String? docType) {
  final t = _clean(docType).toLowerCase();
  return _docTypes.contains(t) ? t : 'other';
}

/// Deterministic FALLBACK type guess from title/notes keywords. Not OCR; never
/// reads the image. First matching type in _docTypes order wins. Mirrors
/// `doc_scanner.py::suggest_type`.
String suggestType(String title, [String notes = '']) {
  final hay = '${_clean(title)} ${_clean(notes)}'.toLowerCase();
  for (final ty in _docTypes) {
    for (final kw in (_typeHints[ty] ?? const <String>[])) {
      if (hay.contains(kw)) return ty;
    }
  }
  return 'other';
}

/// Problem keys (empty ⇒ valid). The UI localises these.
List<String> validateDoc(String title,
    {String docType = 'other', String imageRef = '', String notes = ''}) {
  final out = <String>[];
  if (_clean(title).isEmpty) out.add('title_required');
  if (!_docTypes.contains(_clean(docType).toLowerCase())) out.add('bad_type');
  return out;
}

/// Filter + search a list of document rows, deterministically. `docType` null /
/// '' / 'all' keeps every type; `query` is a case-insensitive substring against
/// title + notes + any already-extracted_text (searchable once the OCR key
/// fills it — never fabricated). Stable + non-mutating. Mirrors
/// `doc_scanner.py::filter_items`.
List<Map<String, dynamic>> filterDocs(List<Map<String, dynamic>> items,
    {String? docType, String query = ''}) {
  final q = _clean(query).toLowerCase();
  String? want;
  final dt = _clean(docType).toLowerCase();
  if (docType != null && dt.isNotEmpty && dt != 'all') {
    want = normaliseType(docType);
  }
  final out = <Map<String, dynamic>>[];
  for (final it in items) {
    final t = normaliseType((it['doc_type'] ?? '').toString());
    if (want != null && t != want) continue;
    if (q.isNotEmpty) {
      final hay = [
        _clean((it['title'] ?? '').toString()),
        _clean((it['notes'] ?? '').toString()),
        _clean((it['extracted_text'] ?? '').toString()),
      ].join(' ').toLowerCase();
      if (!hay.contains(q)) continue;
    }
    out.add(it);
  }
  return out;
}

/// Per-type tally (every type zero-filled) + 'total'. Mirrors
/// `doc_scanner.py::type_counts`.
Map<String, int> typeCounts(List<Map<String, dynamic>> items) {
  final counts = {for (final ty in _docTypes) ty: 0};
  var total = 0;
  for (final it in items) {
    counts[normaliseType((it['doc_type'] ?? '').toString())] =
        (counts[normaliseType((it['doc_type'] ?? '').toString())] ?? 0) + 1;
    total++;
  }
  counts['total'] = total;
  return counts;
}

// ------------------------------------------------------------ label helpers

String _typeLabel(AppLocalizations t, String ty) {
  switch (ty) {
    case 'nid':
      return t.dsTypeNid;
    case 'passport':
      return t.dsTypePassport;
    case 'certificate':
      return t.dsTypeCertificate;
    case 'bill':
      return t.dsTypeBill;
    case 'receipt':
      return t.dsTypeReceipt;
    default:
      return t.dsTypeOther;
  }
}

IconData _typeIcon(String ty) {
  switch (ty) {
    case 'nid':
      return Icons.badge_outlined;
    case 'passport':
      return Icons.flight_outlined;
    case 'certificate':
      return Icons.workspace_premium_outlined;
    case 'bill':
      return Icons.receipt_long_outlined;
    case 'receipt':
      return Icons.receipt_outlined;
    default:
      return Icons.description_outlined;
  }
}

/// The honest key-gated OCR seam card. LOCKED: "connect an OCR key to auto-read
/// text"; READY (owner connected the ocr key): auto-read may be offered server
/// side. Never fabricates extracted text either way.
class _OcrSeamCard extends StatelessWidget {
  final bool ready;
  const _OcrSeamCard({required this.ready});
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(ready ? Icons.auto_fix_high_outlined : Icons.lock_outline,
            size: 18, color: scheme.primary),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(ready ? t.dsOcrReadyTitle : t.dsOcrLockedTitle,
                style:
                    const TextStyle(fontWeight: FontWeight.w700, height: 1.4)),
            const SizedBox(height: 2),
            Text(ready ? t.dsOcrReadyBody : t.dsOcrLockedBody,
                style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12.5,
                    height: 1.4)),
          ]),
        ),
      ]),
    );
  }
}
