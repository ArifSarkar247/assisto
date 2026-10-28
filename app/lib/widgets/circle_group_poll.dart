import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'package:assisto/widgets/app_sheet.dart';

/// A poll draft produced by the composer. Question + option labels are USER
/// TEXT; the group chat encrypts them per recipient before sending (the server
/// stores ciphertext and tallies by option INDEX only — see
/// core/logic/circle_groups.new_poll / tally_poll).
class CircleGroupPollDraft {
  final String question;
  final List<String> options;
  final bool multi;
  const CircleGroupPollDraft({
    required this.question,
    required this.options,
    required this.multi,
  });
}

const int _kPollMinOptions = 2; // circle_groups.POLL_MIN_OPTIONS
const int _kPollMaxOptions = 12; // circle_groups.POLL_MAX_OPTIONS

/// Poll composer bottom sheet. Returns a [CircleGroupPollDraft] or null.
Future<CircleGroupPollDraft?> showCircleGroupPollComposer(
    BuildContext context) {
  return showAppSheet<CircleGroupPollDraft>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => const _PollComposer(),
  );
}

class _PollComposer extends StatefulWidget {
  const _PollComposer();
  @override
  State<_PollComposer> createState() => _PollComposerState();
}

class _PollComposerState extends State<_PollComposer> {
  final _question = TextEditingController();
  final List<TextEditingController> _options = [
    TextEditingController(),
    TextEditingController(),
  ];
  bool _multi = false;

  @override
  void dispose() {
    _question.dispose();
    for (final c in _options) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _valid {
    if (_question.text.trim().isEmpty) return false;
    final filled = _options.where((c) => c.text.trim().isNotEmpty).length;
    return filled >= _kPollMinOptions;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg + bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.circleGroupCreatePoll,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Gap.md),
            TextField(
              controller: _question,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: t.circleGroupPollQuestion,
                prefixIcon: const Icon(Icons.help_outline_rounded),
              ),
            ),
            const SizedBox(height: Gap.md),
            for (var i = 0; i < _options.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.sm),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _options[i],
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          labelText: t.circleGroupPollOption('${i + 1}'),
                          isDense: true,
                        ),
                      ),
                    ),
                    if (_options.length > _kPollMinOptions)
                      IconButton(
                        icon: const Icon(Icons.remove_circle_outline_rounded),
                        onPressed: () =>
                            setState(() => _options.removeAt(i).dispose()),
                      ),
                  ],
                ),
              ),
            if (_options.length < _kPollMaxOptions)
              TextButton.icon(
                icon: const Icon(Icons.add_rounded),
                label: Text(t.circleGroupPollAddOption),
                onPressed: () =>
                    setState(() => _options.add(TextEditingController())),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t.circleGroupPollMultiSelect),
              value: _multi,
              onChanged: (v) => setState(() => _multi = v),
            ),
            const SizedBox(height: Gap.sm),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _valid
                    ? () => Navigator.pop(
                          context,
                          CircleGroupPollDraft(
                            question: _question.text.trim(),
                            options: _options
                                .map((c) => c.text.trim())
                                .where((s) => s.isNotEmpty)
                                .toList(),
                            multi: _multi,
                          ),
                        )
                    : null,
                child: Text(t.circleGroupPollSend),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Renders a poll inside the chat: decrypted question + options with live vote
/// counts and the viewer's selection. Counts come from the server tally (by
/// option index); the labels are decrypted on-device by the chat screen and
/// passed in via [poll]['options'] (a List<String>).
class CircleGroupPollCard extends StatefulWidget {
  final Map<String, dynamic> poll;
  final ValueChanged<List<int>> onVote;
  const CircleGroupPollCard(
      {super.key, required this.poll, required this.onVote});

  @override
  State<CircleGroupPollCard> createState() => _CircleGroupPollCardState();
}

class _CircleGroupPollCardState extends State<CircleGroupPollCard> {
  late Set<int> _selected;

  @override
  void initState() {
    super.initState();
    final mine = (widget.poll['my_vote'] as List?)?.cast<int>() ?? const [];
    _selected = mine.toSet();
  }

  bool get _multi => widget.poll['multi'] == true;
  bool get _closed => widget.poll['closed'] == true;

  List<String> get _options {
    final raw = widget.poll['options'] as List?;
    if (raw != null) return raw.map((e) => '$e').toList();
    final n = (widget.poll['option_count'] as int?) ?? 0;
    return List.generate(n, (i) => '${i + 1}');
  }

  List<int> get _counts {
    final c = widget.poll['counts'] as List?;
    if (c == null) return List.filled(_options.length, 0);
    return c.map((e) => (e as num).toInt()).toList();
  }

  int get _total {
    final c = _counts;
    return c.fold(0, (a, b) => a + b);
  }

  void _toggle(int i) {
    if (_closed) return;
    setState(() {
      if (_multi) {
        if (_selected.contains(i)) {
          _selected.remove(i);
        } else {
          _selected.add(i);
        }
      } else {
        _selected = {i};
      }
    });
    widget.onVote(_selected.toList()..sort());
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final counts = _counts;
    final total = _total;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.poll_rounded, size: 18),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Text('${widget.poll['question'] ?? ''}',
                      style: Theme.of(context).textTheme.titleSmall),
                ),
                if (_closed)
                  Text(t.circleGroupPollClosed,
                      style: TextStyle(color: scheme.onSurfaceVariant)),
              ],
            ),
            const SizedBox(height: Gap.sm),
            for (var i = 0; i < _options.length; i++)
              _optionRow(i, _options[i],
                  i < counts.length ? counts[i] : 0, total, scheme),
            const SizedBox(height: Gap.xs),
            Text(t.circleGroupPollVotes('$total'),
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }

  Widget _optionRow(
      int i, String label, int count, int total, ColorScheme scheme) {
    final frac = total == 0 ? 0.0 : count / total;
    final chosen = _selected.contains(i);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: InkWell(
        onTap: () => _toggle(i),
        borderRadius: BorderRadius.circular(Radii.sm),
        child: Stack(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(Radii.sm),
              child: LinearProgressIndicator(
                value: frac,
                minHeight: 40,
                backgroundColor: scheme.surfaceContainerHighest,
                color: scheme.primaryContainer,
              ),
            ),
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.md),
                child: Row(
                  children: [
                    Icon(
                      chosen
                          ? (_multi
                              ? Icons.check_box_rounded
                              : Icons.radio_button_checked_rounded)
                          : (_multi
                              ? Icons.check_box_outline_blank_rounded
                              : Icons.radio_button_unchecked_rounded),
                      size: 18,
                    ),
                    const SizedBox(width: Gap.sm),
                    Expanded(
                        child: Text(label, overflow: TextOverflow.ellipsis)),
                    Text('$count'),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
