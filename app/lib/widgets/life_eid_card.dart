import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';

/// Eid greeting + salami (eidi) card DRAFTS. Both are editable and never
/// auto-sent — the user shares them manually. Drafts are built by the backend
/// (core.logic.ramadan.eid_greeting_draft / salami_card_draft) from only the
/// names/amount the user supplies; no fabricated content.
class LifeEidCard extends StatefulWidget {
  const LifeEidCard({super.key});
  @override
  State<LifeEidCard> createState() => _LifeEidCardState();
}

class _LifeEidCardState extends State<LifeEidCard> {
  final _to = TextEditingController();
  final _from = TextEditingController();
  final _amount = TextEditingController();
  final _draft = TextEditingController();
  String _kind = 'greeting'; // 'greeting' | 'salami'
  bool _busy = false;

  @override
  void dispose() {
    _to.dispose();
    _from.dispose();
    _amount.dispose();
    _draft.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    setState(() => _busy = true);
    try {
      final body = {
        'kind': _kind,
        'to': _to.text.trim(),
        'from': _from.text.trim(),
        if (_kind == 'salami' && _amount.text.trim().isNotEmpty)
          'amount': _amount.text.trim(),
      };
      final r =
          await context.read<AppState>().api.postJson('/ramadan/eid-card', body);
      _draft.text = '${r['text'] ?? ''}';
    } catch (_) {
      // offline-safe local fallback (mirrors backend drafts)
      _draft.text = _localDraft();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // Mirror of ramadan.eid_greeting_draft / salami_card_draft (English only here;
  // the server returns the locale-correct text — this is just an offline guard).
  String _localDraft() {
    final to = _to.text.trim();
    final from = _from.text.trim();
    final toPart = to.isEmpty ? '' : ', $to';
    final fromPart = from.isEmpty ? '' : '\n- $from';
    if (_kind == 'salami') {
      final amt = _amount.text.trim();
      final amtPart = amt.isEmpty ? '' : ' ($amt Tk eidi)';
      return 'Eid Mubarak$toPart!$amtPart Here\'s a little something for you.$fromPart';
    }
    return 'Eid Mubarak$toPart! May this Eid bring you peace, health and joy.$fromPart';
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SegmentedButton<String>(
            segments: [
              ButtonSegment(value: 'greeting', label: Text(t.eidGreeting)),
              ButtonSegment(value: 'salami', label: Text(t.eidSalami)),
            ],
            selected: {_kind},
            onSelectionChanged: (s) => setState(() => _kind = s.first),
          ),
          const SizedBox(height: Gap.sm),
          TextField(
            controller: _to,
            decoration: InputDecoration(labelText: t.eidToLabel, isDense: true),
          ),
          const SizedBox(height: Gap.xs),
          TextField(
            controller: _from,
            decoration: InputDecoration(labelText: t.eidFromLabel, isDense: true),
          ),
          if (_kind == 'salami') ...[
            const SizedBox(height: Gap.xs),
            TextField(
              controller: _amount,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: t.eidAmountLabel, isDense: true),
            ),
          ],
          const SizedBox(height: Gap.sm),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              icon: _busy
                  ? const SizedBox(
                      width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.auto_awesome_rounded, size: 16),
              label: Text(t.eidGenerate),
              onPressed: _busy ? null : _generate,
            ),
          ),
          if (_draft.text.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            TextField(
              controller: _draft,
              maxLines: 4,
              decoration: InputDecoration(
                labelText: t.eidDraftLabel,
                helperText: t.eidEditableNote,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: Gap.sm),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.share_rounded, size: 16),
                  label: Text(t.eidShare),
                  onPressed: () => Share.share(_draft.text),
                ),
              ),
            ]),
          ],
        ]),
      ),
    );
  }
}
