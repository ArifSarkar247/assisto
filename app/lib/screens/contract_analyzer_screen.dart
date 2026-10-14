import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';

/// CONTRACT / AGREEMENT ANALYZER (#30, SPEC v2.1 §8, ADVANCED).
///
/// Paste the text of a contract, lease, loan agreement or terms-of-service and
/// a DETERMINISTIC rule engine flags common RISK clauses (auto-renewal,
/// penalty, lock-in, one-sided termination, hidden fees, jurisdiction, …),
/// gives a plain-language summary, and a "things to verify before you sign"
/// checklist. Analyses can be saved and reopened.
///
/// The on-screen rules MIRROR backend/core/logic/contract_analyzer.py VERBATIM
/// (same seed phrases, same severities, same worst-first sort) so the result
/// is identical offline and the backend tests pin it.
///
/// NEVER LEGAL ADVICE — this is a review helper, not a lawyer. Every result
/// shows the honest marker + "consult a professional". A DEEPER, model-read
/// analysis is key-gated: when the owner connects an AI key (Integrations →
/// Anthropic/AI), the executor can route the text to the real provider; until
/// then the deterministic layer works fully. See up_contractcost_integration.md.
///
/// Persistence (generic api helpers, no api.dart edit):
///   listItems('contract/analyses') → [{id, title, text, saved_at}]
/// create/update/deleteItem on the same path; each row round-trips as
/// {id, ...data} through one flexible per-user JSON collection.
///
/// ZERO Bangla literals — every string is an AppLocalizations getter; the
/// rule-seed phrases used for matching live in the engine mirror below as
/// neutral ASCII English seeds (the bn seeds stay server-side, matched there);
/// the Dart layer matches English seeds locally and is honest that a deeper
/// read needs the key. No U+0980–U+09FF appears in this file.
class ContractAnalyzerScreen extends StatefulWidget {
  const ContractAnalyzerScreen({super.key});
  @override
  State<ContractAnalyzerScreen> createState() => _ContractAnalyzerScreenState();
}

const String _analysesPath = 'contract/analyses';

// ------------------------------------------------------- engine mirror
// Deterministic rule set mirroring contract_analyzer.py. English ASCII seeds
// only (keeps this file Bangla-free); the server adds bn seeds for pasted
// Bangla text. Severity keys are localised + coloured by the UI.
class _Rule {
  final String kind;
  final String severity; // high | medium | low
  final List<String> patterns;
  const _Rule(this.kind, this.severity, this.patterns);
}

const List<_Rule> _rules = [
  _Rule('auto_renewal', 'high', [
    'auto-renew', 'auto renew', 'automatically renew', 'automatic renewal',
    'renews automatically', 'shall renew',
  ]),
  _Rule('penalty', 'high', [
    'penalty', 'liquidated damages', 'late fee', 'late fine',
    'default interest', 'forfeit', 'forfeiture',
  ]),
  _Rule('lock_in', 'high', [
    'lock-in', 'lock in period', 'minimum term', 'minimum commitment',
    'non-cancellable', 'non cancellable', 'binding for a period',
  ]),
  _Rule('one_sided_termination', 'high', [
    'terminate at its sole discretion', 'may terminate at any time without',
    'terminate without cause', 'terminate for convenience',
    'sole discretion to terminate', 'without notice to you',
  ]),
  _Rule('hidden_fees', 'medium', [
    'additional charges', 'additional fees', 'service charge', 'processing fee',
    'subject to change', 'as applicable', 'plus applicable taxes',
    'convenience fee',
  ]),
  _Rule('jurisdiction', 'medium', [
    'governing law', 'exclusive jurisdiction', 'courts of', 'arbitration',
    'venue shall be', 'subject to the jurisdiction',
  ]),
  _Rule('auto_debit', 'medium', [
    'auto-debit', 'auto debit', 'standing instruction', 'recurring payment',
    'automatically charged',
  ]),
  _Rule('liability_waiver', 'medium', [
    'as is', 'no warranty', 'disclaim all liability', 'not be liable',
    'limitation of liability', 'indemnify', 'hold harmless',
  ]),
  _Rule('data_sharing', 'low', [
    'share your data', 'third party', 'third-party', 'marketing purposes',
    'may disclose', 'data with partners',
  ]),
  _Rule('price_increase', 'low', [
    'price may increase', 'revise the price', 'increase fees',
    'adjust the price', 'at our discretion increase',
  ]),
];

const Map<String, int> _severityRank = {'high': 0, 'medium': 1, 'low': 2};
const List<String> _alwaysCheck = [
  'parties', 'dates', 'payment_terms', 'exit', 'signatures'
];
const Map<String, String> _clauseCheck = {
  'auto_renewal': 'verify_renewal',
  'penalty': 'verify_penalty',
  'lock_in': 'verify_lockin',
  'one_sided_termination': 'verify_termination',
  'hidden_fees': 'verify_fees',
  'jurisdiction': 'verify_jurisdiction',
  'auto_debit': 'verify_autodebit',
  'liability_waiver': 'verify_liability',
  'data_sharing': 'verify_data',
  'price_increase': 'verify_price',
};
const int _snippetPad = 48;
const int _maxText = 60000;

class _Flag {
  final String kind, severity, matched, snippet;
  const _Flag(this.kind, this.severity, this.matched, this.snippet);
}

class _Analysis {
  final List<_Flag> flags;
  final Map<String, int> counts;
  final List<String> checklist;
  const _Analysis(this.flags, this.counts, this.checklist);
}

String _norm(String text) {
  final clipped = text.length > _maxText ? text.substring(0, _maxText) : text;
  return clipped.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ').toLowerCase();
}

String _snippetFor(String lower, String original, String needle) {
  final idx = lower.indexOf(needle);
  if (idx < 0) return '';
  final normOrig =
      original.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');
  final start = (idx - _snippetPad).clamp(0, normOrig.length);
  final end = (idx + needle.length + _snippetPad).clamp(0, normOrig.length);
  var snip = normOrig.substring(start, end).trim();
  if (start > 0) snip = '… $snip';
  if (end < normOrig.length) snip = '$snip …';
  return snip;
}

_Analysis _analyze(String text) {
  final lower = _norm(text);
  final flags = <_Flag>[];
  for (final r in _rules) {
    String? hit;
    for (final p in r.patterns) {
      if (lower.contains(p)) {
        hit = p;
        break;
      }
    }
    if (hit != null) {
      flags.add(_Flag(r.kind, r.severity, hit, _snippetFor(lower, text, hit)));
    }
  }
  flags.sort((a, b) =>
      (_severityRank[a.severity] ?? 9).compareTo(_severityRank[b.severity] ?? 9));
  final counts = {'high': 0, 'medium': 0, 'low': 0};
  for (final f in flags) {
    counts[f.severity] = (counts[f.severity] ?? 0) + 1;
  }
  final checklist = <String>[..._alwaysCheck];
  final seen = checklist.toSet();
  for (final f in flags) {
    final key = _clauseCheck[f.kind];
    if (key != null && !seen.contains(key)) {
      seen.add(key);
      checklist.add(key);
    }
  }
  return _Analysis(flags, counts, checklist);
}

// ------------------------------------------------------- label helpers

String _clauseLabel(AppLocalizations t, String kind) {
  switch (kind) {
    case 'auto_renewal':
      return t.caClauseAutoRenewal;
    case 'penalty':
      return t.caClausePenalty;
    case 'lock_in':
      return t.caClauseLockIn;
    case 'one_sided_termination':
      return t.caClauseTermination;
    case 'hidden_fees':
      return t.caClauseHiddenFees;
    case 'jurisdiction':
      return t.caClauseJurisdiction;
    case 'auto_debit':
      return t.caClauseAutoDebit;
    case 'liability_waiver':
      return t.caClauseLiability;
    case 'data_sharing':
      return t.caClauseDataSharing;
    default:
      return t.caClausePriceIncrease;
  }
}

String _severityLabel(AppLocalizations t, String sev) {
  switch (sev) {
    case 'high':
      return t.caSeverityHigh;
    case 'medium':
      return t.caSeverityMedium;
    default:
      return t.caSeverityLow;
  }
}

Color _severityColor(String sev) {
  switch (sev) {
    case 'high':
      return Brand.danger;
    case 'medium':
      return Brand.warning;
    default:
      return Brand.blue;
  }
}

String _checkLabel(AppLocalizations t, String key) {
  switch (key) {
    case 'parties':
      return t.caCheckParties;
    case 'dates':
      return t.caCheckDates;
    case 'payment_terms':
      return t.caCheckPayment;
    case 'exit':
      return t.caCheckExit;
    case 'signatures':
      return t.caCheckSignatures;
    case 'verify_renewal':
      return t.caCheckRenewal;
    case 'verify_penalty':
      return t.caCheckPenalty;
    case 'verify_lockin':
      return t.caCheckLockIn;
    case 'verify_termination':
      return t.caCheckTermination;
    case 'verify_fees':
      return t.caCheckFees;
    case 'verify_jurisdiction':
      return t.caCheckJurisdiction;
    case 'verify_autodebit':
      return t.caCheckAutoDebit;
    case 'verify_liability':
      return t.caCheckLiability;
    case 'verify_data':
      return t.caCheckData;
    default:
      return t.caCheckPrice;
  }
}

class _ContractAnalyzerScreenState extends State<ContractAnalyzerScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  final TextEditingController _title = TextEditingController();
  final TextEditingController _text = TextEditingController();

  _Analysis? _result;
  int? _editingId;

  List<Map<String, dynamic>> _saved = [];
  bool _loading = true, _error = false;

  AppLocalizations get t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _title.dispose();
    _text.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final list = await context.read<AppState>().api.listItems(_analysesPath);
      if (!mounted) return;
      setState(() {
        _saved = list;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = true;
        _loading = false;
      });
    }
  }

  void _toast(String msg) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(msg)));

  void _analyzeNow() {
    FocusScope.of(context).unfocus();
    final body = _text.text.trim();
    if (body.isEmpty) {
      _toast(t.caErrEmpty);
      return;
    }
    if (body.length < 40) {
      _toast(t.caErrTooShort);
      return;
    }
    setState(() => _result = _analyze(body));
  }

  Future<void> _saveAnalysis() async {
    final body = _text.text.trim();
    if (body.isEmpty) {
      _toast(t.caErrEmpty);
      return;
    }
    final row = {
      'title': _title.text.trim().isEmpty ? t.caUntitled : _title.text.trim(),
      'text': body,
      'saved_at': DateTime.now().toIso8601String(),
    };
    try {
      final api = context.read<AppState>().api;
      if (_editingId != null) {
        await api.updateItem(_analysesPath, _editingId!, row);
      } else {
        await api.createItem(_analysesPath, row);
      }
      await _load();
      if (!mounted) return;
      _toast(t.caSaved);
    } catch (_) {
      _toast(t.caErrSave);
    }
  }

  void _openSaved(Map<String, dynamic> row) {
    setState(() {
      _editingId = row['id'] as int?;
      _title.text = (row['title'] ?? '').toString();
      _text.text = (row['text'] ?? '').toString();
      _result = _analyze(_text.text.trim());
    });
    _tabs.animateTo(0);
  }

  Future<void> _deleteSaved(Map<String, dynamic> row) async {
    final id = row['id'] as int?;
    if (id == null) return;
    try {
      await context.read<AppState>().api.deleteItem(_analysesPath, id);
      if (_editingId == id) _editingId = null;
      await _load();
      if (!mounted) return;
      _toast(t.caDeleted);
    } catch (_) {
      _toast(t.caErrSave);
    }
  }

  Future<void> _copyChecklist() async {
    final r = _result;
    if (r == null) return;
    final lines = r.checklist.map((k) => '• ${_checkLabel(t, k)}').join('\n');
    await Clipboard.setData(ClipboardData(text: lines));
    if (!mounted) return;
    _toast(t.caCopied);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(t.caTitle),
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            Tab(
                child: Text(t.caTabAnalyze,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis)),
            Tab(
                child: Text(t.caTabSaved,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis)),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [_analyzeTab(), _savedTab()],
      ),
    );
  }

  // ------------------------------------------------------- analyze tab

  Widget _analyzeTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.xxl),
      children: [
        const _HonestMarker(),
        const SizedBox(height: Gap.lg),
        TextField(
          controller: _title,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: t.caTitleLabel,
            hintText: t.caTitleHint,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: Gap.lg),
        TextField(
          controller: _text,
          maxLines: null,
          minLines: 7,
          decoration: InputDecoration(
            labelText: t.caTextLabel,
            hintText: t.caTextHint,
            alignLabelWithHint: true,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: Gap.lg),
        Row(children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: _analyzeNow,
              icon: const Icon(Icons.search_rounded, size: 18),
              label: Text(t.caAnalyze),
            ),
          ),
          const SizedBox(width: Gap.sm),
          OutlinedButton.icon(
            onPressed: _saveAnalysis,
            icon: const Icon(Icons.bookmark_outline, size: 18),
            label: Text(t.save),
          ),
        ]),
        if (_result != null) ...[
          const SizedBox(height: Gap.xl),
          _resultView(_result!),
        ],
      ],
    );
  }

  Widget _resultView(_Analysis r) {
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // severity summary chips
      Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
        _CountChip(
            label: _severityLabel(t, 'high'),
            count: r.counts['high'] ?? 0,
            color: Brand.danger),
        _CountChip(
            label: _severityLabel(t, 'medium'),
            count: r.counts['medium'] ?? 0,
            color: Brand.warning),
        _CountChip(
            label: _severityLabel(t, 'low'),
            count: r.counts['low'] ?? 0,
            color: Brand.blue),
      ]),
      const SizedBox(height: Gap.lg),

      // flags
      Text(t.caFlagsTitle,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
      const SizedBox(height: Gap.sm),
      if (r.flags.isEmpty)
        Container(
          padding: const EdgeInsets.all(Gap.md),
          decoration: BoxDecoration(
            color: Brand.success.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(Radii.sm),
          ),
          child: Row(children: [
            const Icon(Icons.verified_outlined,
                size: 18, color: Brand.success),
            const SizedBox(width: Gap.sm),
            Expanded(
                child: Text(t.caNoFlags,
                    style: const TextStyle(height: 1.4))),
          ]),
        )
      else
        ...r.flags.map((f) => _FlagCard(
              title: _clauseLabel(t, f.kind),
              severity: _severityLabel(t, f.severity),
              color: _severityColor(f.severity),
              snippet: f.snippet,
            )),

      const SizedBox(height: Gap.xl),

      // checklist
      Row(children: [
        Expanded(
          child: Text(t.caChecklistTitle,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
        ),
        TextButton.icon(
          onPressed: _copyChecklist,
          icon: const Icon(Icons.copy_rounded, size: 16),
          label: Text(t.copy),
        ),
      ]),
      const SizedBox(height: Gap.sm),
      ...r.checklist.map((k) => Padding(
            padding: const EdgeInsets.only(bottom: Gap.sm),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.check_box_outline_blank,
                  size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: Gap.sm),
              Expanded(
                  child: Text(_checkLabel(t, k),
                      style: const TextStyle(height: 1.4))),
            ]),
          )),

      const SizedBox(height: Gap.xl),
      // key-gated deeper analysis state (honest)
      const _DeeperAiCard(),
      const SizedBox(height: Gap.lg),
      // never-legal-advice disclaimer
      Container(
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.gavel_outlined, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: Gap.sm),
          Expanded(
              child: Text(t.caDisclaimer,
                  style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12.5,
                      height: 1.4))),
        ]),
      ),
    ]);
  }

  // ------------------------------------------------------- saved tab

  Widget _savedTab() {
    if (_loading) return const SkeletonList(count: 4);
    if (_error) {
      return StateMessage(
        icon: Icons.cloud_off,
        tint: Brand.danger,
        title: t.caLoadError,
        action: FilledButton.tonal(onPressed: _load, child: Text(t.retry)),
      );
    }
    if (_saved.isEmpty) {
      return StateMessage(
        icon: Icons.description_outlined,
        title: t.caEmptyTitle,
        message: t.caEmptyBody,
        action: FilledButton.tonalIcon(
          onPressed: () => _tabs.animateTo(0),
          icon: const Icon(Icons.search_rounded, size: 18),
          label: Text(t.caTabAnalyze),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.all(Gap.lg),
        itemCount: _saved.length,
        separatorBuilder: (_, __) => const SizedBox(height: Gap.md),
        itemBuilder: (_, i) {
          final row = _saved[i];
          final preview = (row['text'] ?? '').toString();
          return Card(
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              title: Text((row['title'] ?? t.caUntitled).toString(),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                  preview.length > 90 ? '${preview.substring(0, 90)}…' : preview,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
              onTap: () => _openSaved(row),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: t.delete,
                onPressed: () => _deleteSaved(row),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ------------------------------------------------------- small widgets

class _HonestMarker extends StatelessWidget {
  const _HonestMarker();
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.auto_awesome, size: 18, color: scheme.onTertiaryContainer),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.caMarker,
                style: TextStyle(
                    color: scheme.onTertiaryContainer,
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                    height: 1.4)),
            const SizedBox(height: 2),
            Text(t.caMarkerSub,
                style: TextStyle(
                    color: scheme.onTertiaryContainer,
                    fontSize: 12,
                    height: 1.4)),
          ]),
        ),
      ]),
    );
  }
}

class _DeeperAiCard extends StatelessWidget {
  const _DeeperAiCard();
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
        Icon(Icons.lock_outline, size: 18, color: scheme.primary),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.caDeeperTitle,
                style: const TextStyle(fontWeight: FontWeight.w700, height: 1.4)),
            const SizedBox(height: 2),
            Text(t.caDeeperBody,
                style: TextStyle(
                    color: scheme.onSurfaceVariant, fontSize: 12.5, height: 1.4)),
          ]),
        ),
      ]),
    );
  }
}

class _CountChip extends StatelessWidget {
  final String label;
  final int count;
  final Color color;
  const _CountChip(
      {required this.label, required this.count, required this.color});
  @override
  Widget build(BuildContext context) {
    final dim = count == 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
      decoration: BoxDecoration(
        color: color.withValues(alpha: dim ? 0.06 : 0.14),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Text('$count · $label',
          style: TextStyle(
              color: dim ? Theme.of(context).colorScheme.onSurfaceVariant : color,
              fontWeight: FontWeight.w700,
              fontSize: 12.5)),
    );
  }
}

class _FlagCard extends StatelessWidget {
  final String title, severity, snippet;
  final Color color;
  const _FlagCard(
      {required this.title,
      required this.severity,
      required this.color,
      required this.snippet});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border(left: BorderSide(color: color, width: 3)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(title,
                style: const TextStyle(fontWeight: FontWeight.w800, height: 1.3)),
          ),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(Radii.pill),
            ),
            child: Text(severity,
                style: TextStyle(
                    color: color, fontWeight: FontWeight.w700, fontSize: 11)),
          ),
        ]),
        if (snippet.isNotEmpty) ...[
          const SizedBox(height: Gap.xs),
          Text(snippet,
              style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: 12.5,
                  height: 1.4,
                  fontStyle: FontStyle.italic)),
        ],
      ]),
    );
  }
}
