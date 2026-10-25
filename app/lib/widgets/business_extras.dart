import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../business_ai_api.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import 'business_ui.dart';

/// AI extras (PAID) — a morning-summary card + mocked "review step" sheets for
/// voice entry, paper-khata digitising, and payment matching. Each AI output is
/// a DRAFT the owner reviews before anything is saved (never auto-applied).

/// Morning summary card: "overnight: N msgs, N orders, N need you".
/// Silently renders nothing if the plan is not active (PAID) or on error, so a
/// FREE dashboard stays clean. Tap routes via [onOpenInbox] when provided.
class MorningSummaryCard extends StatefulWidget {
  final VoidCallback? onOpenInbox;
  const MorningSummaryCard({super.key, this.onOpenInbox});
  @override
  State<MorningSummaryCard> createState() => _MorningSummaryCardState();
}

class _MorningSummaryCardState extends State<MorningSummaryCard> {
  Map<String, dynamic>? _s;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _s = await context.read<AppState>().api.aiMorningSummary();
    } catch (_) {
      // PAID/gated or error -> stay hidden.
      _s = null;
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading || _s == null) return const SizedBox.shrink();
    final tr = AppLocalizations.of(context);
    final text = (_s!['text'] ?? '').toString();
    if (text.isEmpty) return const SizedBox.shrink();
    return Container(
      decoration: BoxDecoration(
        gradient: Brand.gradient,
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      padding: const EdgeInsets.all(Gap.lg),
      child: Row(children: [
        const Icon(Icons.wb_sunny_rounded, color: Colors.white),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Text(text,
              style: const TextStyle(color: Colors.white, height: 1.4, fontWeight: FontWeight.w600)),
        ),
        if (widget.onOpenInbox != null)
          TextButton(
            onPressed: widget.onOpenInbox,
            child: Text(tr.bizOpen, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          ),
      ]),
    );
  }
}

/// Opens the voice-entry review sheet (PAID · transcription key-gated mock).
Future<void> showVoiceEntrySheet(BuildContext context) =>
    _showReviewSheet(context, _ExtraKind.voice);

/// Opens the paper-khata review sheet (PAID · OCR/vision key-gated mock).
Future<void> showPaperKhataSheet(BuildContext context) =>
    _showReviewSheet(context, _ExtraKind.paperKhata);

/// Opens the payment-match review sheet (PAID — reuses money parse rules).
Future<void> showPaymentMatchSheet(BuildContext context) =>
    _showReviewSheet(context, _ExtraKind.paymentMatch);

enum _ExtraKind { voice, paperKhata, paymentMatch }

Future<void> _showReviewSheet(BuildContext context, _ExtraKind kind) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _ReviewSheet(kind: kind),
  );
}

class _ReviewSheet extends StatefulWidget {
  final _ExtraKind kind;
  const _ReviewSheet({required this.kind});
  @override
  State<_ReviewSheet> createState() => _ReviewSheetState();
}

class _ReviewSheetState extends State<_ReviewSheet> {
  final _input = TextEditingController();
  bool _busy = false;
  bool _locked = false;
  Map<String, dynamic>? _result;
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final api = context.read<AppState>().api;
    try {
      switch (widget.kind) {
        case _ExtraKind.voice:
          _result = await api.aiVoiceEntry(_input.text.trim());
          break;
        case _ExtraKind.paperKhata:
          _result = await api.aiPaperKhata();
          break;
        case _ExtraKind.paymentMatch:
          _result = await api.aiMatchPayment(_input.text.trim());
          break;
      }
    } catch (e) {
      if (isUpgradeRequired(e)) {
        _locked = true;
      } else {
        _error = e.toString();
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  String _title(AppLocalizations tr) {
    switch (widget.kind) {
      case _ExtraKind.voice:
        return tr.bizVoiceEntryTitle;
      case _ExtraKind.paperKhata:
        return tr.bizPaperKhataTitle;
      case _ExtraKind.paymentMatch:
        return tr.bizPaymentMatchTitle;
    }
  }

  bool get _needsInput => widget.kind != _ExtraKind.paperKhata;

  String _hint(AppLocalizations tr) {
    switch (widget.kind) {
      case _ExtraKind.voice:
        return tr.bizVoiceEntryHint;
      case _ExtraKind.paymentMatch:
        return tr.bizPaymentMatchHint;
      case _ExtraKind.paperKhata:
        return '';
    }
  }

  String _mockNote(AppLocalizations tr) {
    switch (widget.kind) {
      case _ExtraKind.voice:
        return tr.bizVoiceNeedsKey;
      case _ExtraKind.paperKhata:
        return tr.bizPaperKhataNeedsKey;
      case _ExtraKind.paymentMatch:
        return ''; // no key needed (rules only)
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: Gap.lg,
        right: Gap.lg,
        top: Gap.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + Gap.lg,
      ),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_title(tr),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.md),
        if (_locked)
          BizNote(text: tr.bizAiGateLine, icon: Icons.auto_awesome_rounded)
        else ...[
          if (_mockNote(tr).isNotEmpty) ...[
            BizMockBanner(text: _mockNote(tr)),
            const SizedBox(height: Gap.md),
          ],
          if (_needsInput) ...[
            TextField(
              controller: _input,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(hintText: _hint(tr)),
            ),
            const SizedBox(height: Gap.md),
          ],
          if (_result != null) _reviewResult(tr),
          if (_error != null) ...[
            BizNote(text: _error!, icon: Icons.error_outline_rounded, tint: Brand.danger),
            const SizedBox(height: Gap.md),
          ],
          Row(children: [
            Expanded(
              child: FilledButton(
                onPressed: _busy ? null : _run,
                child: Text(_result == null ? tr.bizRunDraft : tr.bizRedo),
              ),
            ),
            // m2-reality: a "Confirm & save" button here only closed the sheet
            // (nothing was written to the ledger). Hidden until the real
            // ledger write exists — the draft above stays readable.
          ]),
        ],
      ]),
    );
  }

  Widget _reviewResult(AppLocalizations tr) {
    final r = _result!;
    final text = (r['text'] ?? '').toString();
    final rows = ((r['rows'] ?? (r['draft'] != null ? [r['draft']] : [])) as List)
        .cast<dynamic>();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      BizCard(
        title: tr.bizReviewDraft,
        icon: Icons.fact_check_rounded,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (text.isNotEmpty) Text(text, style: const TextStyle(height: 1.4)),
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.only(top: Gap.sm),
              child: Text(row.toString()),
            ),
        ]),
      ),
      const SizedBox(height: Gap.md),
    ]);
  }
}
