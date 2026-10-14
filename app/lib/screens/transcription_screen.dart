import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';

/// CALL & VOICE-NOTE TRANSCRIPTION — ADVANCED, KEY-GATED (#92, SPEC v2.1 §21).
///
/// A voice-note / recording ORGANISER that is fully useful with NO key: add an
/// entry (title, duration, date, optional audio reference, optional consent
/// flag for call recordings), type or edit a transcript + free notes by hand,
/// and browse a searchable list with a header roll-up (count, total duration,
/// how many are transcribed).
///
/// HONEST, KEY-GATED (NEVER FABRICATES A TRANSCRIPT):
///   * Auto speech-to-text is a DOCUMENTED key-gated seam shown as an honest
///     "connect a transcription key to auto-transcribe" card (_SttSeamCard).
///     This screen NEVER invents transcript text; a manually typed transcript
///     is clearly labelled "typed by you".
///   * Real audio capture (microphone / call recording) is a device seam — a
///     row stores only a reference string + duration, never audio bytes.
///   * Recording a phone call is subject to local law + all-party consent; the
///     add/edit sheet surfaces a consent acknowledgement that never defaults on.
///
/// The on-screen logic mirrors backend/core/logic/transcription.py (duration
/// clamp/format, word-count, search, stats, source rules) so the list is
/// deterministic and identical offline.
///
/// Honest states: welcome (first use) · loading · error · empty-search. ZERO
/// Bangla literals — every string is an AppLocalizations getter (৳ exempt).
///
/// Persistence (generic api helpers, no api.dart edit):
///   listItems('transcribe/notes') → [{id, title, duration, date, audio_ref,
///                                      consent_ack, transcript, source, notes}]
/// create/update/delete on the same path. Each row round-trips as {id, ...data}
/// through one flexible per-user JSON collection (PaCollectionItem precedent).
class TranscriptionScreen extends StatefulWidget {
  const TranscriptionScreen({super.key});
  @override
  State<TranscriptionScreen> createState() => _TranscriptionScreenState();
}

const String _notesPath = 'transcribe/notes';

String _today() {
  final n = DateTime.now();
  return '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
}

/// Clamp a duration to int seconds in [0, 24h] — mirror of transcription.clamp_duration.
int _clampDuration(dynamic v) {
  final n = (v is int) ? v : int.tryParse('${v ?? ''}') ?? 0;
  if (n < 0) return 0;
  const maxD = 24 * 3600;
  return n > maxD ? maxD : n;
}

/// Format int seconds as M:SS or H:MM:SS — mirror of transcription.fmt_duration.
String _fmtDuration(int seconds) {
  final s = _clampDuration(seconds);
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = s % 60;
  final two = (int x) => x.toString().padLeft(2, '0');
  if (h > 0) return '$h:${two(m)}:${two(sec)}';
  return '$m:${two(sec)}';
}

class _TranscriptionScreenState extends State<TranscriptionScreen> {
  List<Map<String, dynamic>> _notes = [];
  bool _loading = true, _error = false;
  String _query = '';

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
      _notes = await context.read<AppState>().api.listItems(_notesPath);
    } catch (_) {
      _error = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String msg) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(msg)));

  /// Case-insensitive search over title / transcript / notes — mirror of
  /// transcription.search_notes (order preserved).
  List<Map<String, dynamic>> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _notes;
    return _notes.where((n) {
      final hay = [
        n['title'],
        n['transcript'],
        n['notes'],
      ].map((e) => '${e ?? ''}').join(' ').toLowerCase();
      return hay.contains(q);
    }).toList();
  }

  Future<void> _openEditor([Map<String, dynamic>? existing]) async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _NoteEditorSheet(existing: existing),
    );
    if (result == null) return;
    final api = context.read<AppState>().api;
    try {
      if (existing != null && existing['id'] is int) {
        await api.updateItem(_notesPath, existing['id'] as int, result);
      } else {
        await api.createItem(_notesPath, result);
      }
      await _load();
    } catch (_) {
      if (mounted) _toast(AppLocalizations.of(context).saveFailed);
    }
  }

  Future<void> _delete(Map<String, dynamic> note) async {
    final tr = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(tr.tnDeleteTitle),
        content: Text(tr.tnDeleteBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr.delete)),
        ],
      ),
    );
    if (ok != true || note['id'] is! int) return;
    try {
      await context.read<AppState>().api.deleteItem(_notesPath, note['id'] as int);
      await _load();
    } catch (_) {
      if (mounted) _toast(AppLocalizations.of(context).saveFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return Scaffold(
          appBar: AppBar(title: Text(tr.tnTitle)),
          body: const SkeletonList());
    }
    if (_error) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.tnTitle)),
        body: StateMessage(
          icon: Icons.cloud_off,
          tint: scheme.error,
          title: tr.loadFailed,
          message: tr.tnLoadError,
          action: FilledButton.tonalIcon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: Text(tr.retry)),
        ),
      );
    }
    final list = _filtered;
    return Scaffold(
      appBar: AppBar(title: Text(tr.tnTitle)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(),
        icon: const Icon(Icons.add),
        label: Text(tr.tnAddNote),
      ),
      body: _notes.isEmpty
          ? _Welcome(onAdd: () => _openEditor())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
                children: [
                  _StatsHeader(notes: _notes),
                  const SizedBox(height: Gap.sm),
                  const _SttSeamCard(),
                  const SizedBox(height: Gap.md),
                  TextField(
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText: tr.tnSearchHint,
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (v) => setState(() => _query = v),
                  ),
                  const SizedBox(height: Gap.md),
                  if (list.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: Gap.xl),
                      child: StateMessage(
                        icon: Icons.search_off,
                        title: tr.tnNoResultsTitle,
                        message: tr.tnNoResultsBody,
                      ),
                    )
                  else
                    ...list.map((n) => _NoteCard(
                          note: n,
                          onTap: () => _openEditor(n),
                          onDelete: () => _delete(n),
                        )),
                ],
              ),
            ),
    );
  }
}

// ======================= welcome (first use) =======================
class _Welcome extends StatelessWidget {
  final VoidCallback onAdd;
  const _Welcome({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(Gap.lg),
      children: [
        const SizedBox(height: Gap.xl),
        Icon(Icons.graphic_eq, size: 56, color: scheme.primary),
        const SizedBox(height: Gap.md),
        Text(tr.tnWelcomeTitle,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.sm),
        Text(tr.tnWelcomeBody,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
        const SizedBox(height: Gap.lg),
        const _SttSeamCard(),
        const SizedBox(height: Gap.xl),
        Center(
          child: FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: Text(tr.tnAddNote),
          ),
        ),
      ],
    );
  }
}

// ======================= stats header =======================
class _StatsHeader extends StatelessWidget {
  final List<Map<String, dynamic>> notes;
  const _StatsHeader({required this.notes});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    var totalDur = 0;
    var transcribed = 0;
    for (final n in notes) {
      totalDur += _clampDuration(n['duration']);
      if ('${n['transcript'] ?? ''}'.trim().isNotEmpty) transcribed++;
    }
    return Card(
      color: scheme.primaryContainer.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(children: [
          Expanded(
              child: _Stat(
                  label: tr.tnStatCount, value: '${notes.length}')),
          Expanded(
              child: _Stat(
                  label: tr.tnStatDuration,
                  value: _fmtDuration(totalDur))),
          Expanded(
              child: _Stat(
                  label: tr.tnStatTranscribed,
                  value: '$transcribed/${notes.length}')),
        ]),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label, value;
  const _Stat({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(children: [
      Text(value,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      const SizedBox(height: 2),
      Text(label,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
    ]);
  }
}

// ======================= STT seam (key-gated) =======================
class _SttSeamCard extends StatelessWidget {
  const _SttSeamCard();

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.secondaryContainer.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.auto_awesome, size: 20, color: scheme.secondary),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tr.tnSttSeamTitle,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(tr.tnSttSeamBody,
                      style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                          height: 1.35)),
                ]),
          ),
        ]),
      ),
    );
  }
}

// ======================= note card =======================
class _NoteCard extends StatelessWidget {
  final Map<String, dynamic> note;
  final VoidCallback onTap, onDelete;
  const _NoteCard(
      {required this.note, required this.onTap, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final transcript = '${note['transcript'] ?? ''}'.trim();
    final hasTranscript = transcript.isNotEmpty;
    final source = '${note['source'] ?? ''}';
    final dur = _clampDuration(note['duration']);
    final date = '${note['date'] ?? ''}';
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: scheme.primaryContainer,
          child: Icon(Icons.mic_none, color: scheme.onPrimaryContainer),
        ),
        title: Text('${note['title'] ?? ''}',
            maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 2),
            Wrap(spacing: Gap.sm, runSpacing: 4, children: [
              if (dur > 0)
                _Chip(icon: Icons.schedule, label: _fmtDuration(dur)),
              if (date.isNotEmpty) _Chip(icon: Icons.event, label: date),
              if (hasTranscript)
                _Chip(
                  icon: source == 'auto' ? Icons.auto_awesome : Icons.edit_note,
                  label: source == 'auto'
                      ? tr.tnSourceAuto
                      : tr.tnSourceManual,
                  tint: scheme.tertiary,
                )
              else
                _Chip(
                    icon: Icons.pending_outlined,
                    label: tr.tnNoTranscript,
                    tint: scheme.onSurfaceVariant),
            ]),
            if (hasTranscript) ...[
              const SizedBox(height: 4),
              Text(transcript,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.onSurfaceVariant)),
            ],
          ],
        ),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: tr.delete,
          onPressed: onDelete,
        ),
        isThreeLine: hasTranscript,
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? tint;
  const _Chip({required this.icon, required this.label, this.tint});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = tint ?? scheme.onSurfaceVariant;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 13, color: c),
      const SizedBox(width: 3),
      Text(label, style: TextStyle(fontSize: 11, color: c)),
    ]);
  }
}

// ======================= add / edit sheet =======================
class _NoteEditorSheet extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const _NoteEditorSheet({this.existing});
  @override
  State<_NoteEditorSheet> createState() => _NoteEditorSheetState();
}

class _NoteEditorSheetState extends State<_NoteEditorSheet> {
  late final TextEditingController _title;
  late final TextEditingController _minutes;
  late final TextEditingController _seconds;
  late final TextEditingController _date;
  late final TextEditingController _audioRef;
  late final TextEditingController _transcript;
  late final TextEditingController _notes;
  bool _consentAck = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing ?? {};
    final dur = _clampDuration(e['duration']);
    _title = TextEditingController(text: '${e['title'] ?? ''}');
    _minutes = TextEditingController(text: dur > 0 ? '${dur ~/ 60}' : '');
    _seconds = TextEditingController(text: dur > 0 ? '${dur % 60}' : '');
    _date = TextEditingController(
        text: '${e['date'] ?? ''}'.isEmpty ? _today() : '${e['date']}');
    _audioRef = TextEditingController(text: '${e['audio_ref'] ?? ''}');
    _transcript = TextEditingController(text: '${e['transcript'] ?? ''}');
    _notes = TextEditingController(text: '${e['notes'] ?? ''}');
    _consentAck = e['consent_ack'] == true;
  }

  @override
  void dispose() {
    for (final c in [
      _title,
      _minutes,
      _seconds,
      _date,
      _audioRef,
      _transcript,
      _notes
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final tr = AppLocalizations.of(context);
    if (_title.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(tr.tnTitleRequired)));
      return;
    }
    final mins = int.tryParse(_minutes.text.trim()) ?? 0;
    final secs = int.tryParse(_seconds.text.trim()) ?? 0;
    final transcript = _transcript.text.trim();
    // Source rule mirrors transcription.normalize_note: text present + no key
    // path means a human typed it => 'manual'. Empty => '' (no claim).
    final source = transcript.isEmpty ? '' : 'manual';
    Navigator.pop(context, {
      'title': _title.text.trim(),
      'duration': _clampDuration(mins * 60 + secs),
      'date': _date.text.trim(),
      'audio_ref': _audioRef.text.trim(),
      'consent_ack': _consentAck,
      'transcript': transcript,
      'source': source,
      'notes': _notes.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final editing = widget.existing != null;
    return Padding(
      padding: EdgeInsets.only(
        left: Gap.lg,
        right: Gap.lg,
        top: Gap.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + Gap.lg,
      ),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(editing ? tr.tnEditNote : tr.tnAddNote,
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _title,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
                labelText: tr.tnFieldTitle, border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _minutes,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                    labelText: tr.tnFieldMinutes,
                    border: const OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: TextField(
                controller: _seconds,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                    labelText: tr.tnFieldSeconds,
                    border: const OutlineInputBorder()),
              ),
            ),
          ]),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _date,
            decoration: InputDecoration(
                labelText: tr.tnFieldDate,
                hintText: 'YYYY-MM-DD',
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _audioRef,
            decoration: InputDecoration(
                labelText: tr.tnFieldAudioRef,
                helperText: tr.tnAudioRefHelp,
                helperMaxLines: 3,
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.sm),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _consentAck,
            onChanged: (v) => setState(() => _consentAck = v ?? false),
            title: Text(tr.tnConsentLabel, style: const TextStyle(fontSize: 13)),
            subtitle:
                Text(tr.tnConsentBody, style: const TextStyle(fontSize: 11)),
            controlAffinity: ListTileControlAffinity.leading,
          ),
          const SizedBox(height: Gap.sm),
          TextField(
            controller: _transcript,
            maxLines: 5,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
                labelText: tr.tnFieldTranscript,
                helperText: tr.tnTranscriptHelp,
                helperMaxLines: 3,
                alignLabelWithHint: true,
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _notes,
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
                labelText: tr.tnFieldNotes,
                alignLabelWithHint: true,
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.sm),
          Text(tr.tnSttSeamBody,
              style: TextStyle(
                  fontSize: 11, color: scheme.onSurfaceVariant, height: 1.3)),
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
              child: FilledButton(onPressed: _save, child: Text(tr.save)),
            ),
          ]),
        ]),
      ),
    );
  }
}
