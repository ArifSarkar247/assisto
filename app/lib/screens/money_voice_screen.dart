// Money by voice (feature #62, SPEC v2.1 §21) — ADVANCED.
//
// Speak an expense / income / loan and it gets logged — AFTER you confirm.
// Flow: mic permission (reason dialog) → honest device-gated speech-to-text →
// on-device parse (amount + type + category + counterparty, batch-aware) →
// a REVIEW step that names exactly what it understood and lets you fix any
// field → Confirm → write to the same SyncedRepos the money screen reads
// (txns for expense/income, loans for due-in/due-out). Nothing is logged until
// the user taps Confirm, so a wrong parse is never silently saved.
//
// HONESTY: speech-to-text is DEVICE/engine gated (mirrors voice_command_sheet).
// When no engine is available (`SpeechToText.initialize()` returns false) we
// show an explicit "voice not available" state and NEVER fabricate a
// transcript — we only ever parse words the device actually recognised.
//
// LANGUAGE GATE: every user-facing string comes from AppLocalizations
// (bilingual, keys in .phaseB/up_mvoice_arb.json). No Bangla literals here.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:speech_to_text/speech_to_text.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/permission_reason.dart';
import '../widgets/skeleton.dart';
import '../widgets/moneyvoice_parse.dart';
import 'money_common.dart';

enum _Phase { idle, listening, review, unavailable, error, done }

class MoneyVoiceScreen extends StatefulWidget {
  const MoneyVoiceScreen({super.key});
  @override
  State<MoneyVoiceScreen> createState() => _MoneyVoiceScreenState();
}

class _MoneyVoiceScreenState extends State<MoneyVoiceScreen>
    with SingleTickerProviderStateMixin {
  final SpeechToText _speech = SpeechToText();
  late final AnimationController _pulse;
  _Phase _phase = _Phase.idle;
  bool _ready = false;
  String _transcript = '';
  List<_Draft> _drafts = [];
  bool _saving = false;
  int _savedCount = 0;

  AppLocalizations get t => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1100))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _speech.cancel();
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _startListening() async {
    HapticFeedback.selectionClick();
    if (!_ready) {
      final okReason = await showPermissionReason(context, PermKind.mic);
      if (!okReason || !mounted) return;
      _ready = await _speech.initialize(
        onStatus: (s) {
          if ((s == 'done' || s == 'notListening') &&
              mounted &&
              _phase == _Phase.listening) {
            _finishListening();
          }
        },
        onError: (_) {
          if (mounted) setState(() => _phase = _Phase.error);
        },
      );
    }
    // HONEST device gate: no engine → explicit unavailable state, no fake text.
    if (!_ready) {
      if (mounted) setState(() => _phase = _Phase.unavailable);
      return;
    }
    setState(() {
      _phase = _Phase.listening;
      _transcript = '';
      _drafts = [];
    });
    await _speech.listen(
      onResult: (r) {
        if (mounted) setState(() => _transcript = r.recognizedWords);
      },
    );
  }

  void _finishListening() {
    _speech.stop();
    final text = _transcript.trim();
    if (text.isEmpty) {
      setState(() => _phase = _Phase.idle);
      return;
    }
    final entries = MoneyVoiceParser.parse(text);
    setState(() {
      _drafts = entries.map(_Draft.fromEntry).toList();
      _phase = _drafts.isEmpty ? _Phase.idle : _Phase.review;
    });
  }

  void _stopTap() {
    if (_phase == _Phase.listening) _finishListening();
  }

  bool get _anyConfirmable =>
      _drafts.any((d) => d.amount != null && d.type != null && !d.skip);

  Future<void> _confirmAll() async {
    HapticFeedback.mediumImpact();
    final app = context.read<AppState>();
    final accs =
        app.accounts.items.where((a) => a['serverId'] != null).toList();
    final defaultAcc = accs.isEmpty ? null : accs.first['serverId'] as int?;
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());

    setState(() => _saving = true);
    var saved = 0;
    for (final d in _drafts) {
      if (d.skip || d.amount == null || d.type == null) continue;
      final amt = d.amount.toString();
      switch (d.type!) {
        case MoneyVoiceType.expense:
        case MoneyVoiceType.income:
          // Logs to the same txns repo the Transactions tab reads.
          await app.txns.add({
            if (defaultAcc != null) 'account': defaultAcc,
            'kind': d.type == MoneyVoiceType.income ? 'income' : 'expense',
            'amount': amt,
            'category': d.category,
            'note': d.note,
            'date': today,
            'source': 'voice',
          });
          break;
        case MoneyVoiceType.dueIn:
        case MoneyVoiceType.dueOut:
          // due-in = you lent (loan given); due-out = you borrowed (loan taken).
          await app.loans.add({
            'kind': d.type == MoneyVoiceType.dueIn ? 'given' : 'taken',
            'person': d.counterparty ?? d.note,
            'amount': amt,
            'settled': false,
            'paid': '0',
            'repayments': <Map<String, dynamic>>[],
            'source': 'voice',
          });
          break;
      }
      saved++;
    }
    if (!mounted) return;
    setState(() {
      _saving = false;
      _savedCount = saved;
      _phase = _Phase.done;
    });
  }

  void _reset() => setState(() {
        _phase = _Phase.idle;
        _transcript = '';
        _drafts = [];
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t.mvoiceTitle)),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    switch (_phase) {
      case _Phase.idle:
      case _Phase.listening:
        return _speakPane();
      case _Phase.review:
        return _reviewPane();
      case _Phase.unavailable:
        return _message(Icons.mic_off_outlined, t.mvoiceUnavailableTitle,
            t.mvoiceUnavailableBody,
            action: FilledButton(
                onPressed: () => Navigator.pop(context),
                child: Text(t.mvoiceGotIt)));
      case _Phase.error:
        return _message(Icons.error_outline, t.mvoiceErrorTitle,
            t.mvoiceErrorBody,
            action: FilledButton.icon(
                onPressed: _startListening,
                icon: const Icon(Icons.refresh),
                label: Text(t.mvoiceRetry)));
      case _Phase.done:
        return _message(Icons.check_circle_outline, t.mvoiceDoneTitle,
            t.mvoiceDoneBody(_savedCount),
            tint: AssistoTokens.of(context).success,
            action: Column(mainAxisSize: MainAxisSize.min, children: [
              FilledButton.icon(
                  onPressed: _reset,
                  icon: const Icon(Icons.mic),
                  label: Text(t.mvoiceSpeakAgain)),
              const SizedBox(height: Gap.sm),
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(t.mvoiceDoneClose)),
            ]));
    }
  }

  // ------- SPEAK (idle + listening) -------
  Widget _speakPane() {
    final scheme = Theme.of(context).colorScheme;
    final listening = _phase == _Phase.listening;
    return ListView(
      padding: const EdgeInsets.all(Gap.xl),
      children: [
        const SizedBox(height: Gap.lg),
        Text(listening ? t.mvoiceListeningHint : t.mvoiceSpeakHint,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.45)),
        const SizedBox(height: Gap.xl),
        Center(
          child: Semantics(
            button: true,
            label: listening ? t.mvoiceStop : t.mvoiceTapToSpeak,
            child: GestureDetector(
              onTap: listening ? _stopTap : _startListening,
              child: AnimatedBuilder(
                animation: _pulse,
                builder: (_, child) {
                  final scale = listening ? 1 + _pulse.value * 0.12 : 1.0;
                  return Transform.scale(scale: scale, child: child);
                },
                child: Container(
                  width: 112,
                  height: 112,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: Brand.gradient,
                    boxShadow: listening
                        ? [
                            BoxShadow(
                                color: Brand.blue.withValues(alpha: 0.45),
                                blurRadius: 30,
                                spreadRadius: 5)
                          ]
                        : null,
                  ),
                  child: Icon(listening ? Icons.graphic_eq : Icons.mic,
                      size: 52, color: Colors.white),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: Gap.lg),
        if (listening && _transcript.isNotEmpty)
          Text('"$_transcript"',
              textAlign: TextAlign.center,
              style: AType.titleLarge.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.xl),
        if (listening)
          FilledButton.icon(
              onPressed: _stopTap,
              icon: const Icon(Icons.stop_circle_outlined),
              label: Text(t.mvoiceStop))
        else ...[
          // Examples so a first-timer knows what to say (empty state).
          _ExampleCard(
              icon: Icons.record_voice_over_outlined,
              lines: [t.mvoiceExample1, t.mvoiceExample2, t.mvoiceExample3]),
        ],
      ],
    );
  }

  // ------- REVIEW (what it understood; edit before logging) -------
  Widget _reviewPane() {
    final scheme = Theme.of(context).colorScheme;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.sm),
        child: Row(children: [
          Icon(Icons.fact_check_outlined, color: scheme.primary),
          const SizedBox(width: Gap.sm),
          Expanded(
              child: Text(t.mvoiceReviewTitle,
                  style: AType.titleLarge.copyWith(fontWeight: FontWeight.w800))),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
        child: Text(t.mvoiceReviewBody,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
      ),
      const SizedBox(height: Gap.md),
      Expanded(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
          children: [
            Container(
              margin: const EdgeInsets.only(bottom: Gap.md),
              padding: const EdgeInsets.all(Gap.md),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(Radii.md),
              ),
              child: Row(children: [
                Icon(Icons.hearing_outlined,
                    size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: Gap.sm),
                Expanded(
                    child: Text('"$_transcript"',
                        style: const TextStyle(
                            fontStyle: FontStyle.italic,
                            fontWeight: FontWeight.w600))),
              ]),
            ),
            for (int i = 0; i < _drafts.length; i++)
              _draftCard(i, _drafts[i], scheme),
          ],
        ),
      ),
      _reviewActions(scheme),
    ]);
  }

  Widget _draftCard(int i, _Draft d, ColorScheme scheme) {
    final complete = d.amount != null && d.type != null;
    return Card(
      child: Opacity(
        opacity: d.skip ? 0.5 : 1,
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(_typeIcon(d.type), color: _typeColor(d.type, scheme)),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(
                  d.note.isNotEmpty
                      ? d.note
                      : (d.counterparty ?? t.mvoiceEntryUnnamed),
                  style: AType.titleMedium.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              Text(d.amount != null ? tkFmt(d.amount) : t.mvoiceNoAmount,
                  style: TextStyle(fontFeatures: AFonts.tabular,
                      fontWeight: FontWeight.w800,
                      color: d.amount != null
                          ? _typeColor(d.type, scheme)
                          : scheme.error)),
              IconButton(
                tooltip: d.skip ? t.mvoiceInclude : t.mvoiceSkip,
                icon: Icon(d.skip
                    ? Icons.add_circle_outline
                    : Icons.remove_circle_outline),
                onPressed: () => setState(() => d.skip = !d.skip),
              ),
            ]),
            const SizedBox(height: Gap.sm),
            // Type chooser — fixes a wrong parse before logging.
            Wrap(spacing: Gap.sm, children: [
              for (final ty in MoneyVoiceType.values)
                ChoiceChip(
                  visualDensity: VisualDensity.compact,
                  label: Text(_typeLabel(ty)),
                  selected: d.type == ty,
                  onSelected: (_) => setState(() => d.type = ty),
                ),
            ]),
            const SizedBox(height: Gap.sm),
            Row(children: [
              Expanded(
                child: TextFormField(
                  initialValue: d.amount?.toString() ?? '',
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                      labelText: t.mvoiceFieldAmount, isDense: true),
                  onChanged: (v) => setState(() => d.amount = num.tryParse(v)),
                ),
              ),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: TextFormField(
                  initialValue: d.note,
                  decoration: InputDecoration(
                      labelText: t.mvoiceFieldNote, isDense: true),
                  onChanged: (v) => d.note = v,
                ),
              ),
            ]),
            if (d.type == MoneyVoiceType.dueIn ||
                d.type == MoneyVoiceType.dueOut) ...[
              const SizedBox(height: Gap.sm),
              TextFormField(
                initialValue: d.counterparty ?? '',
                decoration: InputDecoration(
                    labelText: t.mvoiceFieldPerson,
                    isDense: true,
                    prefixIcon: const Icon(Icons.person_outline, size: 18)),
                onChanged: (v) => d.counterparty = v.trim().isEmpty ? null : v,
              ),
            ],
            if (!complete)
              Padding(
                padding: const EdgeInsets.only(top: Gap.sm),
                child: Row(children: [
                  Icon(Icons.info_outline, size: 14, color: scheme.error),
                  const SizedBox(width: Gap.xs),
                  Expanded(
                      child: Text(t.mvoiceNeedsInfo,
                          style:
                              AType.bodySmall.copyWith(color: scheme.error))),
                ]),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _reviewActions(ColorScheme scheme) {
    return Container(
      padding: EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg,
          MediaQuery.of(context).viewInsets.bottom + Gap.lg),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _saving ? null : _reset,
            icon: const Icon(Icons.refresh, size: 18),
            label: Text(t.mvoiceSpeakAgain),
          ),
        ),
        const SizedBox(width: Gap.md),
        Expanded(
          flex: 2,
          child: FilledButton.icon(
            onPressed: (_anyConfirmable && !_saving) ? _confirmAll : null,
            icon: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.check, size: 18),
            label: Text(t.mvoiceConfirmLog),
          ),
        ),
      ]),
    );
  }

  Widget _message(IconData icon, String title, String body,
      {Widget? action, Color? tint}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: StateMessage(
            icon: icon, title: title, message: body, tint: tint, action: action),
      ),
    );
  }

  IconData _typeIcon(MoneyVoiceType? ty) => switch (ty) {
        MoneyVoiceType.income => Icons.south_west,
        MoneyVoiceType.expense => Icons.north_east,
        MoneyVoiceType.dueIn => Icons.call_received,
        MoneyVoiceType.dueOut => Icons.call_made,
        null => Icons.help_outline,
      };

  Color _typeColor(MoneyVoiceType? ty, ColorScheme scheme) => switch (ty) {
        MoneyVoiceType.income => AssistoTokens.of(context).success,
        MoneyVoiceType.expense => Theme.of(context).colorScheme.error,
        MoneyVoiceType.dueIn => Brand.blue,
        MoneyVoiceType.dueOut => AssistoTokens.of(context).warning,
        null => scheme.onSurfaceVariant,
      };

  String _typeLabel(MoneyVoiceType ty) => switch (ty) {
        MoneyVoiceType.income => t.mvoiceTypeIncome,
        MoneyVoiceType.expense => t.mvoiceTypeExpense,
        MoneyVoiceType.dueIn => t.mvoiceTypeDueIn,
        MoneyVoiceType.dueOut => t.mvoiceTypeDueOut,
      };
}

/// Mutable review-row state (the user can fix any field before logging).
class _Draft {
  num? amount;
  MoneyVoiceType? type;
  String? counterparty;
  String note;
  String category;
  bool skip;
  _Draft(
      {this.amount,
      this.type,
      this.counterparty,
      this.note = '',
      this.category = 'uncategorized',
      this.skip = false});

  factory _Draft.fromEntry(MoneyVoiceEntry e) => _Draft(
        amount: e.amount,
        type: e.type,
        counterparty: e.counterparty,
        note: e.note,
      );
}

class _ExampleCard extends StatelessWidget {
  final IconData icon;
  final List<String> lines;
  const _ExampleCard({required this.icon, required this.lines});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.all(Gap.lg),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 18, color: scheme.primary),
          const SizedBox(width: Gap.sm),
          Text(t.mvoiceExamplesTitle,
              style: const TextStyle(fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: Gap.sm),
        for (final l in lines)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Gap.xxs),
            child: Row(children: [
              const Text('• '),
              Expanded(
                  child: Text('"$l"',
                      style: TextStyle(color: scheme.onSurfaceVariant))),
            ]),
          ),
      ]),
    );
  }
}
