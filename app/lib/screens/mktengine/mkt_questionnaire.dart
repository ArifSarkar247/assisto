import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../widgets/app_sheet.dart' show withNavBarInset;
import '../../widgets/local_counter.dart';
import '../../widgets/local_digits.dart';
import 'mkt_source.dart';

/// mktengine — the guided business questionnaire (server-defined steps,
/// Bangla first). Every step is saved as a draft (partial), so leaving half
/// way loses nothing. Pops `true` once the plan was generated.
class MktQuestionnaireScreen extends StatefulWidget {
  final MktSource source;
  final List<Map<String, dynamic>> questions;
  final Map<String, dynamic> answers;
  final int initialStep;
  const MktQuestionnaireScreen(
      {super.key, required this.source, required this.questions, this.answers = const {}, this.initialStep = 0});

  @override
  State<MktQuestionnaireScreen> createState() => _MktQuestionnaireScreenState();
}

class _MktQuestionnaireScreenState extends State<MktQuestionnaireScreen> {
  late int _step = widget.initialStep.clamp(0, widget.questions.isEmpty ? 0 : widget.questions.length - 1);
  late final Map<String, dynamic> _a = Map<String, dynamic>.from(widget.answers);
  final _text = TextEditingController();
  bool _busy = false;
  String? _err;

  @override
  void initState() {
    super.initState();
    _syncText();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Map<String, dynamic> get _q => widget.questions[_step];

  void _syncText() {
    if (widget.questions.isEmpty) return;
    if (_q['type'] == 'text') _text.text = '${_a[_q['key']] ?? ''}';
  }

  bool get _answered {
    final v = _a[_q['key']];
    if (_q['required'] != true) return true;
    if (v is List) return v.isNotEmpty;
    return v != null && '$v'.trim().isNotEmpty;
  }

  bool get _last => _step == widget.questions.length - 1;

  Future<void> _next() async {
    final t = AppLocalizations.of(context);
    if (_q['type'] == 'text') {
      final s = _text.text.trim();
      if (s.isEmpty) {
        _a.remove(_q['key']);
      } else {
        _a[_q['key']] = s;
      }
    }
    if (!_answered) {
      setState(() => _err = t.mktAnswerFirst);
      return;
    }
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      if (_last) {
        await widget.source.saveAnswers(_a);
        await widget.source.generate();
        if (mounted) Navigator.of(context).pop(true);
        return;
      }
      await widget.source.saveAnswers({_q['key'] as String: _a[_q['key']]}, partial: true);
      if (!mounted) return;
      setState(() {
        _step++;
        _syncText();
      });
    } catch (e) {
      if (mounted) setState(() => _err = mktError(e) ?? t.mktGenericError);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _back() {
    if (_step == 0) {
      Navigator.of(context).pop(false);
      return;
    }
    setState(() {
      _step--;
      _err = null;
      _syncText();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (widget.questions.isEmpty) {
      return Scaffold(appBar: AppBar(title: Text(t.mktQuestionsTitle)), body: Center(child: Text(t.mktGenericError)));
    }
    final total = widget.questions.length;
    final q = _q;
    return Scaffold(
      appBar: AppBar(title: Text(t.mktQuestionsTitle)),
      body: ListView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(16, 12, 16, 24)),
        children: [
          Text(t.mktStepOf(ld(context, _step + 1), ld(context, total)),
              style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: (_step + 1) / total, minHeight: 6, semanticsLabel: t.mktStepOf(ld(context, _step + 1), ld(context, total))),
          const SizedBox(height: 20),
          Text('${q['label'] ?? ''}', style: Theme.of(context).textTheme.titleLarge),
          if (q['required'] != true) ...[
            const SizedBox(height: 4),
            Text(t.mktOptional, style: Theme.of(context).textTheme.bodySmall),
          ],
          if (q['type'] == 'multi') ...[
            const SizedBox(height: 4),
            Text(t.mktPickMany, style: Theme.of(context).textTheme.bodySmall),
          ],
          const SizedBox(height: 12),
          ..._input(q, t),
          if (_err != null) ...[
            const SizedBox(height: 12),
            Text(_err!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 20),
          Wrap(spacing: 12, runSpacing: 12, alignment: WrapAlignment.spaceBetween, children: [
            OutlinedButton(
              style: OutlinedButton.styleFrom(minimumSize: const Size(110, 48)),
              onPressed: _busy ? null : _back,
              child: Text(_step == 0 ? t.mktCancel : t.mktBack),
            ),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(150, 48)),
              onPressed: _busy ? null : _next,
              child: _busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(_last ? t.mktBuildPlan : t.mktNext),
            ),
          ]),
          if (_last) ...[
            const SizedBox(height: 12),
            Text(t.mktBuildHint, style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ),
    );
  }

  List<Widget> _input(Map<String, dynamic> q, AppLocalizations t) {
    final key = q['key'] as String;
    final opts = mktList(q['options']);
    switch (q['type']) {
      case 'single':
        return [
          RadioGroup<String>(
            groupValue: _a[key] as String?,
            onChanged: (v) => setState(() {
              _a[key] = v;
              _err = null;
            }),
            child: Column(children: [
              for (final o in opts)
                RadioListTile<String>(
                  value: '${o['value']}',
                  title: Text('${o['label']}'),
                  contentPadding: EdgeInsets.zero,
                ),
            ]),
          ),
        ];
      case 'multi':
        final sel = List<String>.from((_a[key] as List?) ?? const []);
        return [
          for (final o in opts)
            CheckboxListTile(
              value: sel.contains('${o['value']}'),
              title: Text('${o['label']}'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              onChanged: (v) => setState(() {
                final val = '${o['value']}';
                if (v == true) {
                  if (val == 'none') sel.clear();
                  sel.remove('none');
                  sel.add(val);
                } else {
                  sel.remove(val);
                }
                _a[key] = sel;
                _err = null;
              }),
            ),
        ];
      default:
        return [
          TextField(
            controller: _text,
            maxLength: 200,
            buildCounter: localCounter,
            minLines: 1,
            maxLines: 3,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              hintText: '${q['hint'] ?? ''}',
            ),
          ),
        ];
    }
  }
}
