import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/local_counter.dart';
import '../../widgets/local_digits.dart';
import 'mkt_questionnaire.dart';
import 'mkt_source.dart';

/// mktengine — ASSISTO MARKETING ENGINE v1 (owner P3-D; flag
/// `marketing_engine`). A shop owner answers a short questionnaire; the
/// server builds a marketing SYSTEM (content, strategy, campaigns,
/// conversion) from the shop's REAL catalog prices, sales and CRM numbers.
/// The owner approves item by item; approved follow-ups really go out
/// through retention automation; Facebook posting only once Meta allows it
/// (copy / share otherwise, said honestly). No ads on this screen.
class MktEngineScreen extends StatefulWidget {
  final MktSource? source;

  /// Tests / gallery: the section shown first.
  final String initialSection;
  const MktEngineScreen({super.key, this.source, this.initialSection = 'content'});

  @override
  State<MktEngineScreen> createState() => _MktEngineScreenState();
}

const _sections = ['content', 'strategy', 'campaign', 'conversion'];

class _MktEngineScreenState extends State<MktEngineScreen> {
  late final MktSource _src = widget.source ?? ApiMktSource(context.read<AppState>().api);
  bool _loading = true;
  bool _featureOff = false;
  String? _error;
  Map<String, dynamic> _data = const {};
  late String _section = widget.initialSection;
  String? _busyId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _data = await _src.overview();
      _featureOff = false;
    } catch (e) {
      if (mktStatus(e) == 403) {
        _featureOff = true;
      } else {
        _error = mktError(e) ?? '';
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _openQuestions() async {
    final qs = mktList(_data['questions']);
    final ans = mktMap(_data['answers']);
    var start = 0;
    if (_data['plan'] == null) {
      start = qs.indexWhere((q) => !ans.containsKey(q['key']));
      if (start < 0) start = qs.length - 1;
    }
    final done = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => MktQuestionnaireScreen(source: _src, questions: qs, answers: ans, initialStep: start)));
    if (done == true) await _load();
  }

  Future<void> _regenerate() async {
    final t = AppLocalizations.of(context);
    setState(() => _busyId = '_gen');
    try {
      await _src.generate();
      if (mounted) _snack(t.mktRebuilt);
      await _load();
    } catch (e) {
      if (mounted) _snack(mktError(e) ?? t.mktGenericError);
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _run(String id, Future<void> Function() fn) async {
    final t = AppLocalizations.of(context);
    setState(() => _busyId = id);
    try {
      await fn();
      await _load();
    } catch (e) {
      if (mounted) _snack(mktError(e) ?? t.mktGenericError);
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _setStatus(Map<String, dynamic> it, String status) =>
      _run('${it['id']}', () => _src.editItem('${it['id']}', {'status': status}));

  Future<void> _edit(Map<String, dynamic> it) async {
    final t = AppLocalizations.of(context);
    final c = TextEditingController(text: '${it['body'] ?? ''}');
    final saved = await showAppSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            Text(t.mktEditTitle, style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(t.mktEditHint, style: Theme.of(ctx).textTheme.bodySmall),
            const SizedBox(height: 12),
            TextField(
              controller: c,
              minLines: 4,
              maxLines: 12,
              maxLength: 4000,
              buildCounter: localCounter,
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: () => Navigator.of(ctx).pop(c.text),
              child: Text(t.mktSave),
            ),
          ]),
        ),
      ),
    );
    if (saved == null || saved.trim().isEmpty || saved == it['body']) return;
    await _run('${it['id']}', () => _src.editItem('${it['id']}', {'body': saved}));
  }

  Future<void> _copy(Map<String, dynamic> it) async {
    final t = AppLocalizations.of(context);
    await Clipboard.setData(ClipboardData(text: '${it['body'] ?? ''}'));
    if (mounted) _snack(t.mktCopied);
  }

  Future<void> _share(Map<String, dynamic> it) async {
    final t = AppLocalizations.of(context);
    try {
      await Share.share('${it['body'] ?? ''}', subject: '${it['title'] ?? ''}');
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: '${it['body'] ?? ''}'));
      if (mounted) _snack(t.mktCopied);
    }
  }

  Future<void> _polish(Map<String, dynamic> it) => _run('${it['id']}', () async {
        await _src.polish('${it['id']}');
        if (mounted) _snack(AppLocalizations.of(context).mktPolished);
      });

  Future<void> _activate(Map<String, dynamic> it) => _run('${it['id']}', () async {
        await _src.activate('${it['id']}');
        if (mounted) _snack(AppLocalizations.of(context).mktActivated);
      });

  Future<void> _publish(Map<String, dynamic> it) => _run('${it['id']}', () async {
        await _src.publish('${it['id']}');
        if (mounted) _snack(AppLocalizations.of(context).mktPublished);
      });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final hasPlan = !_loading && _data['plan'] != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.mktTitle),
        actions: [
          if (hasPlan)
            IconButton(
              tooltip: t.mktEditAnswers,
              icon: const Icon(Icons.edit_note_rounded),
              onPressed: _openQuestions,
            ),
        ],
      ),
      body: _body(t),
    );
  }

  Widget _message(IconData icon, String title, String body, {Widget? action}) {
    return ListView(padding: withNavBarInset(context, const EdgeInsets.all(32)), children: [
      const SizedBox(height: 32),
      Icon(icon, size: 56, color: Theme.of(context).colorScheme.primary),
      const SizedBox(height: 16),
      Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      Text(body, textAlign: TextAlign.center),
      if (action != null) ...[const SizedBox(height: 20), Center(child: action)],
    ]);
  }

  Widget _body(AppLocalizations t) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_featureOff) return _message(Icons.lock_clock_outlined, t.mktOffTitle, t.mktOffBody);
    if (_error != null) {
      return _message(Icons.cloud_off_rounded, t.mktLoadErrorTitle, _error!.isNotEmpty ? _error! : t.mktLoadErrorBody,
          action: FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
              onPressed: _load,
              child: Text(t.mktRetry)));
    }
    final plan = _data['plan'];
    if (plan is! Map) return _welcome(t);
    return _planView(t, Map<String, dynamic>.from(plan));
  }

  Widget _welcome(AppLocalizations t) {
    final started = mktMap(_data['answers']).isNotEmpty;
    final cs = Theme.of(context).colorScheme;
    Widget step(IconData i, String s) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(i, color: cs.primary),
            const SizedBox(width: 12),
            Expanded(child: Text(s)),
          ]),
        );
    return ListView(padding: withNavBarInset(context, const EdgeInsets.fromLTRB(20, 24, 20, 32)), children: [
      Icon(Icons.campaign_rounded, size: 56, color: cs.primary),
      const SizedBox(height: 12),
      Text(t.mktWelcomeTitle, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      Text(t.mktWelcomeBody, textAlign: TextAlign.center),
      const SizedBox(height: 20),
      FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        onPressed: _openQuestions,
        icon: const Icon(Icons.play_arrow_rounded),
        label: Text(started ? t.mktContinue : t.mktStart),
      ),
      const SizedBox(height: 24),
      Text(t.mktHowTitle, style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 4),
      step(Icons.quiz_outlined, t.mktHow1),
      step(Icons.fact_check_outlined, t.mktHow2),
      step(Icons.send_rounded, t.mktHow3),
      const SizedBox(height: 12),
      Text(t.mktHonestLine, style: Theme.of(context).textTheme.bodySmall),
    ]);
  }

  String _secLabel(AppLocalizations t, String s) => switch (s) {
        'strategy' => t.mktSecStrategy,
        'campaign' => t.mktSecCampaign,
        'conversion' => t.mktSecConversion,
        _ => t.mktSecContent,
      };

  Widget _planView(AppLocalizations t, Map<String, dynamic> plan) {
    final items = mktList(plan['items']);
    final facts = mktList(plan['facts']);
    final shown = items.where((i) => i['section'] == _section).toList();
    final approved = items.where((i) => i['status'] == 'approved').length;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: withNavBarInset(context, const EdgeInsets.only(bottom: 32)),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(t.mktApprovedCount(ld(context, approved), ld(context, items.length)),
                style: Theme.of(context).textTheme.titleSmall),
          ),
          Card(
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: ExpansionTile(
              leading: const Icon(Icons.insights_rounded),
              title: Text(t.mktFactsTitle),
              subtitle: Text(t.mktFactsSub),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              children: [
                for (final f in facts)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${f['label']}', style: Theme.of(context).textTheme.labelLarge),
                      Text('${f['value']}'),
                    ]),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: _busyId == null ? _regenerate : null,
                icon: const Icon(Icons.refresh_rounded),
                label: Text(t.mktRebuild),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: _openQuestions,
                icon: const Icon(Icons.edit_note_rounded),
                label: Text(t.mktEditAnswers),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              for (final s in _sections)
                ChoiceChip(
                  label: Text(_secLabel(t, s)),
                  selected: _section == s,
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                  onSelected: (_) => setState(() => _section = s),
                ),
            ]),
          ),
          for (final it in shown) _itemCard(t, it),
        ],
      ),
    );
  }

  Widget _itemCard(AppLocalizations t, Map<String, dynamic> it) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final status = '${it['status'] ?? 'draft'}';
    final busy = _busyId == '${it['id']}';
    final kind = '${it['kind']}';
    final uses = (it['uses_labels'] as List?)?.map((e) => '$e').toList() ?? const <String>[];
    final hasEstimate = it['estimate'] == true ||
        mktList(it['entries']).any((e) => e['estimated'] == true) ||
        (it['event'] is Map && (it['event'] as Map)['estimated'] == true);
    final follow = mktMap(_data['followups']);
    final pub = mktMap(_data['publish']);
    final ai = _data['ai_available'] == true;
    final statusText = switch (status) {
      'approved' => t.mktStatusApproved,
      'rejected' => t.mktStatusRejected,
      _ => t.mktStatusDraft,
    };
    final statusColor = switch (status) {
      'approved' => cs.primary,
      'rejected' => cs.error,
      _ => cs.onSurfaceVariant,
    };
    final actions = <Widget>[
      if (status != 'approved')
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: busy ? null : () => _setStatus(it, 'approved'),
          icon: const Icon(Icons.check_rounded),
          label: Text(t.mktApprove),
        )
      else
        OutlinedButton(
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: busy ? null : () => _setStatus(it, 'draft'),
          child: Text(t.mktUnapprove),
        ),
      if (status == 'draft')
        TextButton(
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: busy ? null : () => _setStatus(it, 'rejected'),
          child: Text(t.mktReject),
        ),
      if (kind != 'calendar')
        IconButton(
          tooltip: t.mktEdit,
          onPressed: busy ? null : () => _edit(it),
          icon: const Icon(Icons.edit_outlined),
        ),
      IconButton(tooltip: t.mktCopy, onPressed: () => _copy(it), icon: const Icon(Icons.copy_rounded)),
      IconButton(tooltip: t.mktShare, onPressed: () => _share(it), icon: const Icon(Icons.share_rounded)),
      if (ai && kind != 'calendar' && kind != 'followup')
        IconButton(
          tooltip: t.mktPolish,
          onPressed: busy ? null : () => _polish(it),
          icon: const Icon(Icons.auto_awesome_rounded),
        ),
    ];
    Widget? extra;
    if (kind == 'followup' && status == 'approved') {
      if (it['automation_on'] == true) {
        extra = _note(Icons.check_circle_rounded, t.mktFollowOn, cs.primary);
      } else if (follow['flag'] == true && follow['plan_ok'] == true) {
        extra = FilledButton.tonalIcon(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: busy ? null : () => _activate(it),
          icon: const Icon(Icons.send_rounded),
          label: Text(t.mktFollowActivate),
        );
      } else {
        extra = _note(Icons.info_outline_rounded,
            follow['flag'] != true ? t.mktFollowNeedsRetention : t.mktFollowNeedsPlan, cs.onSurfaceVariant);
      }
    } else if (kind == 'post' && status == 'approved') {
      if (it['published'] is Map) {
        extra = _note(Icons.check_circle_rounded, t.mktPublished, cs.primary);
      } else if (pub['facebook'] == true) {
        extra = FilledButton.tonalIcon(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: busy ? null : () => _publish(it),
          icon: const Icon(Icons.public_rounded),
          label: Text(t.mktPublishFb),
        );
      } else {
        extra = _note(Icons.info_outline_rounded,
            pub['reason'] == 'page_not_connected' ? t.mktPublishNoPage : t.mktPublishPending, cs.onSurfaceVariant);
      }
    }
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text('${it['title'] ?? ''}', style: tt.titleMedium),
              Text(statusText, style: tt.labelMedium?.copyWith(color: statusColor, fontWeight: FontWeight.w700)),
              if (hasEstimate)
                Text(t.mktEstimateBadge, style: tt.labelMedium?.copyWith(color: cs.tertiary, fontWeight: FontWeight.w700)),
            ]),
          ),
          if (it['needs'] != null) ...[
            const SizedBox(height: 6),
            Text('${it['needs']}', style: tt.bodySmall?.copyWith(fontStyle: FontStyle.italic)),
          ],
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: SelectableText('${it['body'] ?? ''}'),
          ),
          if (it['polished'] == true) ...[
            const SizedBox(height: 6),
            Text(t.mktPolishedNote, style: tt.bodySmall),
          ],
          if (uses.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(t.mktUses(uses.join(' · ')), style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          ],
          const SizedBox(height: 4),
          Wrap(spacing: 4, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: actions),
          if (extra != null) Padding(padding: const EdgeInsets.fromLTRB(0, 4, 8, 4), child: extra),
        ]),
      ),
    );
  }

  Widget _note(IconData icon, String text, Color color) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: Theme.of(context).textTheme.bodySmall)),
      ]);
}
