import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/skeleton.dart';
import '../../world/world_api.dart';
import '../../world/world_widgets.dart';

/// p4-world BCS PRACTICE: a 10-question round from Assisto's own original
/// question bank (general knowledge, Bangla, English, maths). Answers are
/// checked on the server; each finished round is kept in the score history.
class WorldMcqScreen extends StatefulWidget {
  const WorldMcqScreen({super.key, this.api});
  final WorldApi? api;

  @override
  State<WorldMcqScreen> createState() => _WorldMcqScreenState();
}

class _WorldMcqScreenState extends State<WorldMcqScreen> {
  late final WorldApi api =
      widget.api ?? ApiWorldApi(context.read<AppState>().api);
  String _topic = 'mixed';
  List<Map<String, dynamic>> _topics = [];
  List<Map<String, dynamic>> _qs = [];
  List<Map<String, dynamic>> _history = [];
  final Map<String, int> _choice = {};
  int _i = 0;
  Map<String, dynamic>? _result;
  bool _loading = true;
  bool _error = false;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
      _result = null;
      _choice.clear();
      _i = 0;
    });
    try {
      final j = await api.mcq(_topic).timeout(const Duration(seconds: 20));
      if (!mounted) return;
      if (worldStatus(j) != 200) throw StateError('status');
      setState(() {
        _topics = worldList(j['topics']);
        _qs = worldList(j['questions']);
        _history = worldList(j['history']);
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = true;
        });
      }
    }
  }

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() => _submitting = true);
    final answers = [
      for (final q in _qs)
        {'id': q['id'], 'choice': _choice['${q['id']}'] ?? -1}
    ];
    try {
      final r = await api
          .mcqSubmit(_topic, answers, uwLang(context))
          .timeout(const Duration(seconds: 20));
      if (!mounted) return;
      if (worldStatus(r) != 200) throw StateError('status');
      setState(() {
        _result = r;
        _history = worldList(r['history']);
        _submitting = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).uwSaveFailed)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.uwMcqTitle)),
      body: _loading
          ? const SkeletonList()
          : _error
              ? StateMessage(
                  icon: Icons.cloud_off,
                  tint: scheme.error,
                  title: t.loadFailed,
                  message: t.uwOffline,
                  action: FilledButton.tonalIcon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label: Text(t.retry)))
              : ListView(
                  padding:
                      const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.xl),
                  children: [
                    Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
                      for (final tp in _topics)
                        ChoiceChip(
                          label: Text('${tp['name']}'),
                          selected: _topic == tp['id'],
                          onSelected: (_) {
                            if (_topic == tp['id']) return;
                            _topic = '${tp['id']}';
                            _load();
                          },
                        ),
                    ]),
                    const SizedBox(height: Gap.md),
                    if (_result != null)
                      ..._resultView(t, scheme)
                    else if (_qs.isNotEmpty)
                      _question(t, scheme),
                    if (_history.isNotEmpty) ...[
                      UwHeader(t.uwMcqHistory),
                      for (final h in _history.take(5))
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          leading: const Icon(Icons.history),
                          title: Text(t.uwMcqScore(
                              uwDigits(context, h['correct'] ?? 0),
                              uwDigits(context, h['total'] ?? 0))),
                          subtitle: Text(uwWhen(context, '${h['at'] ?? ''}')),
                        ),
                    ],
                    const SizedBox(height: Gap.md),
                    Text(t.uwMcqOriginal,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant)),
                  ],
                ),
    );
  }

  Widget _question(AppLocalizations t, ColorScheme scheme) {
    final q = _qs[_i];
    final id = '${q['id']}';
    final opts =
        (q['options'] as List?)?.map((e) => '$e').toList() ?? const <String>[];
    final last = _i == _qs.length - 1;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
              t.uwMcqProgress(
                  uwDigits(context, _i + 1), uwDigits(context, _qs.length)),
              style: Theme.of(context)
                  .textTheme
                  .labelLarge
                  ?.copyWith(color: scheme.primary)),
          const SizedBox(height: Gap.xs),
          LinearProgressIndicator(value: (_i + 1) / _qs.length),
          const SizedBox(height: Gap.md),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
                child: Text('${q['q']}',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(height: 1.4))),
            UwSpeakButton(text: '${q['q']} ${opts.join(', ')}', compact: true),
          ]),
          const SizedBox(height: Gap.sm),
          for (var k = 0; k < opts.length; k++)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.xs),
              child: ListTile(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(
                        color: _choice[id] == k
                            ? scheme.primary
                            : scheme.outlineVariant)),
                tileColor: _choice[id] == k ? scheme.primaryContainer : null,
                leading: Icon(
                    _choice[id] == k
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: _choice[id] == k
                        ? scheme.primary
                        : scheme.onSurfaceVariant),
                title: Text(opts[k]),
                onTap: () => setState(() => _choice[id] = k),
              ),
            ),
          const SizedBox(height: Gap.sm),
          Row(children: [
            if (_i > 0)
              TextButton(
                  onPressed: () => setState(() => _i--),
                  child: Text(t.uwMcqBack)),
            const Spacer(),
            FilledButton(
              onPressed: _choice[id] == null
                  ? null
                  : (last
                      ? (_submitting ? null : _submit)
                      : () => setState(() => _i++)),
              child: Text(last ? t.uwMcqFinish : t.uwMcqNext),
            ),
          ]),
        ]),
      ),
    );
  }

  List<Widget> _resultView(AppLocalizations t, ColorScheme scheme) {
    final r = _result!;
    final res = worldList(r['results']);
    return [
      Card(
        margin: EdgeInsets.zero,
        color: scheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Row(children: [
            Icon(Icons.emoji_events_outlined,
                color: scheme.onPrimaryContainer, size: 36),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Text(
                  t.uwMcqScore(uwDigits(context, r['correct'] ?? 0),
                      uwDigits(context, r['total'] ?? 0)),
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(color: scheme.onPrimaryContainer)),
            ),
          ]),
        ),
      ),
      const SizedBox(height: Gap.md),
      for (final x in res)
        Card(
          margin: const EdgeInsets.only(bottom: Gap.sm),
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(x['correct'] == true ? Icons.check_circle : Icons.cancel,
                    color: x['correct'] == true
                        ? Colors.green.shade600
                        : scheme.error),
                const SizedBox(width: Gap.sm),
                Expanded(
                    child: Text('${x['q']}',
                        style: const TextStyle(fontWeight: FontWeight.w600))),
              ]),
              const SizedBox(height: Gap.xs),
              Text(t.uwMcqRightAnswer(
                  '${(x['options'] as List?)?[(x['answer'] as num?)?.toInt() ?? 0] ?? ''}')),
              const SizedBox(height: 2),
              Text('${x['why'] ?? ''}',
                  style:
                      TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
            ]),
          ),
        ),
      FilledButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.refresh),
          label: Text(t.uwMcqAgain)),
    ];
  }
}
