import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../bizagent_api.dart';
import '../../../l10n/app_localizations.dart';
import '../../../state.dart';
import '../../../theme.dart';
import '../../../widgets/business_ui.dart';
import '../../../widgets/skeleton.dart';
import 'seller_agent_screen.dart' show asciiDigits, baChannelLabel, baErrorText, bd;
import 'seller_inbox_screen.dart' show SellerChatScreen;

/// WP-BIZBUILDER — the shop owner's business agent builder.
///
/// Four tabs: the CARD (plain-language instructions, tone, FAQs, hours,
/// delivery, hand-over rules, minimum prices → what the agent understood and
/// what it refused), PREVIEW (how the agent would reply to sample messages),
/// TEST CHAT (a private conversation with the agent — nothing is ever sent to
/// a customer) and the TAKEOVER inbox (chats that need the owner, take over /
/// hand back). Every value comes from the server; the hard rules come from
/// the server too, so the screen can never promise what the agent won't do.
class AgentBuilderScreen extends StatefulWidget {
  const AgentBuilderScreen({super.key});
  @override
  State<AgentBuilderScreen> createState() => _AgentBuilderScreenState();
}

class _Faq {
  final TextEditingController q;
  final TextEditingController a;
  _Faq(String qq, String aa)
      : q = TextEditingController(text: qq),
        a = TextEditingController(text: aa);
  void dispose() {
    q.dispose();
    a.dispose();
  }
}

class _AgentBuilderScreenState extends State<AgentBuilderScreen> {
  bool _loading = true;
  Object? _error;
  bool _busy = false;
  Map<String, dynamic> _st = const {};
  Map<String, dynamic>? _parsed; // last parse / draft result shown under the form
  bool _dirty = false;

  final _instructions = TextEditingController();
  final _hours = TextEditingController();
  final _delivery = TextEditingController();
  final _words = TextEditingController();
  final _bigOrder = TextEditingController();
  final _idle = TextEditingController();
  final List<_Faq> _faqs = [];
  final Map<String, TextEditingController> _mins = {};
  String _tone = 'friendly';
  bool _outsideOnly = false;
  bool _pause = false;

  @override
  void initState() {
    super.initState();
    for (final c in [_instructions, _hours, _delivery, _words, _bigOrder, _idle]) {
      c.addListener(_touch);
    }
    _load();
  }

  void _touch() {
    if (!_dirty && mounted) setState(() => _dirty = true);
  }

  @override
  void dispose() {
    for (final c in [_instructions, _hours, _delivery, _words, _bigOrder, _idle]) {
      c.dispose();
    }
    for (final f in _faqs) {
      f.dispose();
    }
    for (final c in _mins.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final st = await context.read<AppState>().api.bizBuilderState();
      if (!mounted) return;
      _st = st;
      _fill();
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  /// The form starts from the draft, else the live card's own source text.
  void _fill() {
    final row = (_st['draft'] as Map?) ?? (_st['live'] as Map?);
    final src = ((row?['source'] as Map?) ?? const {}).cast<String, dynamic>();
    _instructions.text = '${src['instructions'] ?? ''}';
    _hours.text = '${src['hours_text'] ?? ''}';
    _delivery.text = '${src['delivery_text'] ?? ''}';
    final kw = src['takeover_keywords'];
    _words.text = kw is List ? kw.join(', ') : '${kw ?? ''}';
    _bigOrder.text = bd(context, src['big_order_over'] ?? '');
    _idle.text = bd(context, src['idle_minutes'] ?? '');
    _tone = '${src['tone'] ?? (_st['agent'] as Map?)?['tone'] ?? 'friendly'}';
    if (!['friendly', 'formal', 'short'].contains(_tone)) _tone = 'friendly';
    _outsideOnly = src['reply_mode'] == 'outside_hours';
    _pause = src['pause_on_handoff'] == true;
    for (final f in _faqs) {
      f.dispose();
    }
    _faqs
      ..clear()
      ..addAll(((src['faqs'] as List?) ?? const [])
          .whereType<Map>()
          .map((m) => _Faq('${m['q'] ?? ''}', '${m['a'] ?? ''}')));
    for (final c in _mins.values) {
      c.dispose();
    }
    _mins.clear();
    final setMins = ((src['min_prices'] as Map?) ?? const {});
    for (final p in ((_st['catalog'] as List?) ?? const []).whereType<Map>()) {
      final id = '${p['id']}';
      final v = setMins[id] ?? (p['has_min'] == true ? p['min_price'] : '');
      _mins[id] = TextEditingController(text: bd(context, _money(v)))..addListener(_touch);
    }
    _parsed = row == null ? null : Map<String, dynamic>.from(row);
    _dirty = false;
  }

  String _money(Object? v) {
    final s = '${v ?? ''}';
    return s.endsWith('.00') ? s.substring(0, s.length - 3) : s;
  }

  Map<String, dynamic> _form() {
    final mins = <String, String>{};
    final cat = ((_st['catalog'] as List?) ?? const []).whereType<Map>();
    for (final p in cat) {
      final id = '${p['id']}';
      final v = asciiDigits(_mins[id]?.text.trim() ?? '');
      final was = p['has_min'] == true ? _money(p['min_price']) : '';
      if (v.isNotEmpty && v != was) mins[id] = v;
    }
    return {
      'instructions': _instructions.text,
      'tone': _tone,
      'hours_text': _hours.text,
      'delivery_text': _delivery.text,
      'takeover_keywords': _words.text,
      'big_order_over': asciiDigits(_bigOrder.text.trim()),
      'idle_minutes': asciiDigits(_idle.text.trim()),
      'pause_on_handoff': _pause,
      'reply_mode': _outsideOnly ? 'outside_hours' : 'always',
      'faqs': [
        for (final f in _faqs)
          if (f.q.text.trim().isNotEmpty || f.a.text.trim().isNotEmpty)
            {'q': f.q.text.trim(), 'a': f.a.text.trim()}
      ],
      'min_prices': mins,
    };
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(bd(context, m))));

  Future<void> _run(Future<void> Function() job) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await job();
    } catch (e) {
      if (mounted) _snack(baErrorText(AppLocalizations.of(context), e));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _check() => _run(() async {
        final r = await context.read<AppState>().api.bizBuilderParse(_form());
        if (mounted) setState(() => _parsed = r);
      });

  Future<void> _save() => _run(() async {
        final t = AppLocalizations.of(context);
        final r = await context.read<AppState>().api.bizBuilderSaveDraft(_form());
        if (!mounted) return;
        _snack(t.bbSavedDraft);
        _st = Map<String, dynamic>.from(_st)..['draft'] = r['draft'];
        setState(() {
          _parsed = (r['draft'] as Map?)?.cast<String, dynamic>();
          _dirty = false;
        });
      });

  Future<void> _publish() => _run(() async {
        final t = AppLocalizations.of(context);
        final api = context.read<AppState>().api;
        if (_dirty) await api.bizBuilderSaveDraft(_form());
        await api.bizBuilderPublish();
        if (!mounted) return;
        _snack(t.bbPublished);
        await _load();
      });

  Future<void> _discard() => _run(() async {
        final t = AppLocalizations.of(context);
        await context.read<AppState>().api.bizBuilderDiscard();
        if (!mounted) return;
        _snack(t.bbDiscarded);
        await _load();
      });

  Future<void> _restore(int v) async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(t.bbRestoreTitle),
        content: Text(bd(context, t.bbRestoreBody(v))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t.bbCancel)),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(t.bbRestore)),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() async {
      await context.read<AppState>().api.bizBuilderRollback(v);
      if (!mounted) return;
      _snack(t.bbPublished);
      await _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Text(t.bbTitle),
          bottom: TabBar(isScrollable: true, tabs: [
            Tab(text: t.bbTabCard),
            Tab(text: t.bbTabPreview),
            Tab(text: t.bbTabTest),
            Tab(text: t.bbTabInbox),
          ]),
        ),
        body: _loading
            ? const SkeletonList()
            : _error != null
                ? StateMessage(
                    icon: Icons.cloud_off_rounded,
                    title: t.bizLoadFailed,
                    message: baErrorText(t, _error!),
                    action: FilledButton(onPressed: _load, child: Text(t.bizRetry)),
                  )
                : TabBarView(children: [
                    _cardTab(t),
                    _PreviewTab(form: _form),
                    _TestChatTab(ai: ((_st['ai'] as Map?) ?? const {}).cast<String, dynamic>(),
                        hasDraft: _st['draft'] != null, hasLive: _st['live'] != null),
                    const _TakeoverTab(),
                  ]),
      ),
    );
  }

  // ------------------------------------------------------------------ card tab
  Widget _cardTab(AppLocalizations t) {
    final live = _st['live'] as Map?;
    final draft = _st['draft'] as Map?;
    final cat = ((_st['catalog'] as List?) ?? const []).whereType<Map>().toList();
    final rules = ((_st['hard_rules'] as List?) ?? const []).map((e) => '$e').toList();
    final versions = ((_st['versions'] as List?) ?? const []).whereType<Map>().toList();
    final scheme = Theme.of(context).colorScheme;
    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      BizNote(
        icon: live != null ? Icons.check_circle_rounded : Icons.edit_note_rounded,
        tint: live != null ? AssistoTokens.of(context).success : null,
        text: bd(
            context,
            live != null
                ? (draft != null ? t.bbLiveWithDraft(live['version'] as int) : t.bbLive(live['version'] as int))
                : t.bbNoLive),
      ),
      const SizedBox(height: Gap.md),
      BizCard(
        title: t.bbNeverTitle,
        icon: Icons.shield_rounded,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final r in rules)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.xs),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.lock_rounded, size: 16, color: scheme.primary),
                const SizedBox(width: Gap.sm),
                Expanded(child: Text(r)),
              ]),
            ),
        ]),
      ),
      const SizedBox(height: Gap.md),
      BizCard(
        title: t.bbInstructionsTitle,
        icon: Icons.record_voice_over_rounded,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.bbInstructionsHelp, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: Gap.sm),
          TextField(
            controller: _instructions,
            minLines: 4,
            maxLines: 12,
            maxLength: 6000,
            decoration: InputDecoration(
                labelText: t.bbInstructionsLabel, hintText: t.bbInstructionsHint,
                border: const OutlineInputBorder(), alignLabelWithHint: true),
          ),
          const SizedBox(height: Gap.sm),
          Text(t.bbToneLabel, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            for (final o in const ['friendly', 'formal', 'short'])
              ChoiceChip(
                label: Text(o == 'friendly' ? t.bbToneFriendly : o == 'formal' ? t.bbToneFormal : t.bbToneShort),
                selected: _tone == o,
                onSelected: (_) => setState(() {
                  _tone = o;
                  _dirty = true;
                }),
              ),
          ]),
        ]),
      ),
      const SizedBox(height: Gap.md),
      BizCard(
        title: t.bbShopTitle,
        icon: Icons.storefront_rounded,
        child: Column(children: [
          TextField(
            controller: _delivery,
            decoration: InputDecoration(
                labelText: t.bbDeliveryLabel, hintText: t.bbDeliveryHint, border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _hours,
            decoration: InputDecoration(
                labelText: t.bbHoursLabel, hintText: t.bbHoursHint, border: const OutlineInputBorder()),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _outsideOnly,
            title: Text(t.bbOutsideOnly),
            subtitle: Text(t.bbOutsideOnlySub),
            onChanged: (v) => setState(() {
              _outsideOnly = v;
              _dirty = true;
            }),
          ),
        ]),
      ),
      const SizedBox(height: Gap.md),
      BizCard(
        title: t.bbFaqTitle,
        icon: Icons.quiz_rounded,
        trailing: IconButton(
          tooltip: t.bbFaqAdd,
          icon: const Icon(Icons.add_rounded),
          onPressed: _faqs.length >= 50
              ? null
              : () => setState(() {
                    _faqs.add(_Faq('', ''));
                    _dirty = true;
                  }),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (_faqs.isEmpty) Text(t.bbFaqEmpty, style: Theme.of(context).textTheme.bodySmall),
          for (var i = 0; i < _faqs.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.md),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Column(children: [
                    TextField(
                      controller: _faqs[i].q,
                      onChanged: (_) => _touch(),
                      decoration: InputDecoration(
                          labelText: t.bbFaqQ, hintText: t.bbFaqQHint, border: const OutlineInputBorder()),
                    ),
                    const SizedBox(height: Gap.xs),
                    TextField(
                      controller: _faqs[i].a,
                      onChanged: (_) => _touch(),
                      minLines: 1,
                      maxLines: 4,
                      decoration: InputDecoration(labelText: t.bbFaqA, border: const OutlineInputBorder()),
                    ),
                  ]),
                ),
                IconButton(
                  tooltip: t.bbFaqRemove,
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: () => setState(() {
                    _faqs.removeAt(i).dispose();
                    _dirty = true;
                  }),
                ),
              ]),
            ),
        ]),
      ),
      const SizedBox(height: Gap.md),
      BizCard(
        title: t.bbTakeoverTitle,
        icon: Icons.support_agent_rounded,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.bbTakeoverHelp, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: Gap.sm),
          TextField(
            controller: _words,
            decoration: InputDecoration(
                labelText: t.bbWordsLabel, hintText: t.bbWordsHint, border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _bigOrder,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: t.bbBigOrderLabel, border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _idle,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
                labelText: t.bbIdleLabel, helperText: t.bbIdleHelp, border: const OutlineInputBorder()),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _pause,
            title: Text(t.bbPauseLabel),
            subtitle: Text(t.bbPauseSub),
            onChanged: (v) => setState(() {
              _pause = v;
              _dirty = true;
            }),
          ),
        ]),
      ),
      const SizedBox(height: Gap.md),
      BizCard(
        title: t.bbCatalogTitle,
        icon: Icons.inventory_2_rounded,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          BizNote(text: t.bbMinPrivate, icon: Icons.visibility_off_rounded),
          const SizedBox(height: Gap.sm),
          if (cat.isEmpty) Text(t.bbCatalogEmpty),
          for (final p in cat)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.sm),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${p['name']}', maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text(bd(context, t.bbPriceStock(_money(p['price']), '${p['stock']}')),
                        style: Theme.of(context).textTheme.bodySmall),
                  ]),
                ),
                const SizedBox(width: Gap.sm),
                SizedBox(
                  width: 120,
                  child: TextField(
                    controller: _mins['${p['id']}'],
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: t.bbMinLabel, border: const OutlineInputBorder()),
                  ),
                ),
              ]),
            ),
        ]),
      ),
      const SizedBox(height: Gap.md),
      Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _busy ? null : _check,
          icon: const Icon(Icons.fact_check_rounded),
          label: Text(t.bbCheck),
        ),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _busy ? null : _save,
          icon: const Icon(Icons.save_rounded),
          label: Text(t.bbSave),
        ),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _busy || (draft == null && !_dirty) ? null : _publish,
          icon: const Icon(Icons.rocket_launch_rounded),
          label: Text(t.bbPublish),
        ),
        if (draft != null)
          TextButton(
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: _busy ? null : _discard,
            child: Text(t.bbDiscard),
          ),
      ]),
      if (_busy) const Padding(padding: EdgeInsets.only(top: Gap.sm), child: LinearProgressIndicator()),
      if (_parsed != null) ...[
        const SizedBox(height: Gap.md),
        _ParsedView(data: _parsed!),
      ],
      if (versions.isNotEmpty) ...[
        const SizedBox(height: Gap.md),
        BizCard(
          title: t.bbVersionsTitle,
          icon: Icons.history_rounded,
          child: Column(children: [
            for (final v in versions)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(bd(context, t.bbVersion(v['version'] as int))),
                subtitle: Text(_statusLabel(t, '${v['status']}')),
                trailing: v['status'] == 'archived'
                    ? TextButton(
                        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                        onPressed: _busy ? null : () => _restore(v['version'] as int),
                        child: Text(t.bbRestore))
                    : null,
              ),
          ]),
        ),
      ],
      const SizedBox(height: Gap.xxl),
    ]);
  }

  String _statusLabel(AppLocalizations t, String s) {
    switch (s) {
      case 'published':
        return t.bbStatusLive;
      case 'draft':
        return t.bbStatusDraft;
      default:
        return t.bbStatusOld;
    }
  }
}

/// What the agent understood (✓), refused (hard rule, with the reason) and
/// the honest warnings — all bn/en text from the server.
class _ParsedView extends StatelessWidget {
  final Map<String, dynamic> data;
  const _ParsedView({required this.data});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final bn = Localizations.localeOf(context).languageCode == 'bn';
    final card = (data['card'] as Map?) ?? const {};
    List<Map> rows(String k) =>
        ((data[k] as List?) ?? (card[k] as List?) ?? const []).whereType<Map>().toList();
    final understood = rows('understood');
    final rejected = rows('rejected');
    final warnings = rows('warnings');
    final scheme = Theme.of(context).colorScheme;
    final ok = AssistoTokens.of(context).success;
    Widget line(IconData i, Color c, String title, String? sub) => Padding(
          padding: const EdgeInsets.only(bottom: Gap.sm),
          child: Semantics(
            container: true,
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(i, size: 18, color: c),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(bd(context, title)),
                  if (sub != null && sub.isNotEmpty)
                    Text(sub, style: Theme.of(context).textTheme.bodySmall),
                ]),
              ),
            ]),
          ),
        );
    return BizCard(
      title: t.bbUnderstoodTitle,
      icon: Icons.psychology_rounded,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (understood.isEmpty && rejected.isEmpty) Text(t.bbNothingYet),
        for (final u in understood)
          line(Icons.check_circle_rounded, ok, '${bn ? u['bn'] : u['en']}', '${u['line'] ?? ''}'),
        for (final r in rejected)
          line(Icons.block_rounded, scheme.error, '${bn ? r['bn'] : r['en']}', '${r['line'] ?? ''}'),
        for (final w in warnings)
          line(Icons.warning_amber_rounded, AssistoTokens.of(context).warning, '${bn ? w['bn'] : w['en']}', null),
      ]),
    );
  }
}

/// A reply tag: rule (free) / AI needed (+ credits in a real chat) / handed to you.
Widget _outcomeChip(BuildContext context, Map r) {
  final t = AppLocalizations.of(context);
  final tok = AssistoTokens.of(context);
  final outcome = '${r['outcome']}';
  String label;
  Color color;
  if (outcome == 'handoff') {
    label = '${t.bbHandedToYou}: ${r['reason_text'] ?? ''}';
    color = tok.warning;
  } else if (outcome == 'opted_out' || outcome == 'opted_out_silent') {
    label = t.bbOptedOut;
    color = Theme.of(context).colorScheme.outline;
  } else if (outcome == 'human' || outcome == 'quiet') {
    label = '${r['reason_text'] ?? t.bbQuiet}';
    color = Theme.of(context).colorScheme.outline;
  } else if (r['ai_used'] == true) {
    label = t.bbAiUsed;
    color = Theme.of(context).colorScheme.primary;
  } else if (r['ai_needed'] == true) {
    label = t.bbAiNeeded((r['live_credits'] as num?)?.toInt() ?? 0);
    color = tok.warning;
  } else {
    label = t.bbRuleFree;
    color = tok.success;
  }
  return BizStatusChip(label: bd(context, label), color: color);
}

// ==================================================================== preview
class _PreviewTab extends StatefulWidget {
  final Map<String, dynamic> Function() form;
  const _PreviewTab({required this.form});
  @override
  State<_PreviewTab> createState() => _PreviewTabState();
}

class _PreviewTabState extends State<_PreviewTab> with AutomaticKeepAliveClientMixin {
  bool _busy = false;
  Object? _error;
  List<Map> _rows = const [];
  bool _ran = false;

  @override
  bool get wantKeepAlive => true;

  Future<void> _go() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await context.read<AppState>().api.bizBuilderPreview(widget.form());
      if (!mounted) return;
      setState(() {
        _rows = ((r['results'] as List?) ?? const []).whereType<Map>().toList();
        _ran = true;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final t = AppLocalizations.of(context);
    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      BizNote(text: t.bbPreviewNote, icon: Icons.science_rounded),
      const SizedBox(height: Gap.md),
      FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: _busy ? null : _go,
        icon: const Icon(Icons.play_arrow_rounded),
        label: Text(_ran ? t.bbPreviewAgain : t.bbPreviewRun),
      ),
      if (_busy) const Padding(padding: EdgeInsets.only(top: Gap.sm), child: LinearProgressIndicator()),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: Gap.md),
          child: BizNote(
              text: baErrorText(t, _error!), icon: Icons.error_outline_rounded,
              tint: Theme.of(context).colorScheme.error),
        ),
      for (final r in _rows) ...[
        const SizedBox(height: Gap.md),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Semantics(
                label: t.bbCustomerSays,
                child: Text('“${r['customer']}”', style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
              const SizedBox(height: Gap.sm),
              Semantics(
                label: t.bbAgentReplies,
                child: Text(bd(context, '${r['reply'] ?? ''}').isEmpty ? t.bbNoReply : '${r['reply']}'),
              ),
              if ('${r['proposal'] ?? ''}'.isNotEmpty) ...[
                const SizedBox(height: Gap.sm),
                Text(t.bbYouWouldSee, style: Theme.of(context).textTheme.labelMedium),
                Text('${r['proposal']}', style: Theme.of(context).textTheme.bodySmall),
              ],
              const SizedBox(height: Gap.sm),
              _outcomeChip(context, r),
            ]),
          ),
        ),
      ],
    ]);
  }
}

// ==================================================================== test chat
class _TestChatTab extends StatefulWidget {
  final Map<String, dynamic> ai;
  final bool hasDraft;
  final bool hasLive;
  const _TestChatTab({required this.ai, required this.hasDraft, required this.hasLive});
  @override
  State<_TestChatTab> createState() => _TestChatTabState();
}

class _TestChatTabState extends State<_TestChatTab> with AutomaticKeepAliveClientMixin {
  final _c = TextEditingController();
  final _scroll = ScrollController();
  late String _session;
  final List<Map<String, dynamic>> _log = [];
  bool _busy = false;
  bool _allowAi = false;
  bool _useLive = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _session = _newSession();
    _useLive = !widget.hasDraft && widget.hasLive;
    _c.addListener(() {
      if (mounted) setState(() {});
    });
  }

  String _newSession() {
    final r = Random();
    return 'bb${DateTime.now().millisecondsSinceEpoch}${r.nextInt(99999)}';
  }

  @override
  void dispose() {
    _c.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _c.text.trim();
    if (text.isEmpty || _busy) return;
    final t = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _log.add({'who': 'customer', 'text': text});
      _c.clear();
    });
    try {
      final r = await context.read<AppState>().api.bizBuilderTest(_session, text,
          allowAi: _allowAi, use: _useLive ? 'live' : 'draft');
      final res = ((r['result'] as Map?) ?? const {}).cast<String, dynamic>();
      final ai = ((r['ai'] as Map?) ?? const {}).cast<String, dynamic>();
      if (!mounted) return;
      setState(() => _log.add({'who': 'agent', ...res, 'charged': ai['charged'] ?? 0}));
    } catch (e) {
      if (mounted) setState(() => _log.add({'who': 'error', 'text': baErrorText(t, e)}));
    }
    if (mounted) setState(() => _busy = false);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
  }

  void _restart() => setState(() {
        _session = _newSession();
        _log.clear();
      });

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final keyOk = widget.ai['key_present'] == true;
    final per = (widget.ai['credits_per_reply'] as num?)?.toInt() ?? 0;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, 0),
        child: BizNote(text: t.bbTestNote, icon: Icons.lock_rounded),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
        child: Wrap(spacing: Gap.sm, runSpacing: 0, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (widget.hasDraft && widget.hasLive)
            FilterChip(
              label: Text(_useLive ? t.bbUseLive : t.bbUseDraft),
              selected: _useLive,
              onSelected: (v) => setState(() {
                _useLive = v;
                _restart();
              }),
            ),
          if (keyOk)
            FilterChip(
              label: Text(bd(context, t.bbUseAi(per))),
              selected: _allowAi,
              onSelected: (v) => setState(() => _allowAi = v),
            ),
          TextButton.icon(
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: _log.isEmpty ? null : _restart,
            icon: const Icon(Icons.restart_alt_rounded),
            label: Text(t.bbRestart),
          ),
        ]),
      ),
      if (!keyOk)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
          child: Text(t.bbNoAiKey, style: Theme.of(context).textTheme.bodySmall),
        ),
      Expanded(
        child: _log.isEmpty
            ? StateMessage(icon: Icons.chat_bubble_outline_rounded, title: t.bbTestEmptyTitle, message: t.bbTestEmptyBody)
            : ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.all(Gap.lg),
                itemCount: _log.length,
                itemBuilder: (_, i) {
                  final m = _log[i];
                  final mine = m['who'] == 'customer';
                  final err = m['who'] == 'error';
                  final text = mine || err ? '${m['text']}' : '${m['reply'] ?? ''}';
                  return Align(
                    alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                    child: Semantics(
                      label: mine ? t.bbCustomerSays : t.bbAgentReplies,
                      child: Container(
                        margin: const EdgeInsets.only(bottom: Gap.sm),
                        padding: const EdgeInsets.all(Gap.md),
                        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.82),
                        decoration: BoxDecoration(
                          color: err
                              ? scheme.errorContainer
                              : mine
                                  ? scheme.primaryContainer
                                  : scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(Radii.md),
                        ),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(text.isEmpty ? t.bbNoReply : text,
                              style: TextStyle(
                                  color: err
                                      ? scheme.onErrorContainer
                                      : mine
                                          ? scheme.onPrimaryContainer
                                          : scheme.onSurface)),
                          if (!mine && !err) ...[
                            const SizedBox(height: Gap.xs),
                            _outcomeChip(context, m),
                            if ('${m['proposal'] ?? ''}'.isNotEmpty) ...[
                              const SizedBox(height: Gap.xs),
                              Text(t.bbYouWouldSee, style: Theme.of(context).textTheme.labelSmall),
                              Text('${m['proposal']}', style: Theme.of(context).textTheme.bodySmall),
                            ],
                            if (((m['charged'] as num?) ?? 0) > 0)
                              Text(bd(context, t.bbCharged((m['charged'] as num).toInt())),
                                  style: Theme.of(context).textTheme.labelSmall),
                          ],
                        ]),
                      ),
                    ),
                  );
                },
              ),
      ),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.xs, Gap.sm, Gap.sm),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _c,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                decoration: InputDecoration(hintText: t.bbTestHint, border: const OutlineInputBorder()),
              ),
            ),
            IconButton(
              tooltip: t.bbSend,
              icon: _busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send_rounded),
              onPressed: _busy || _c.text.trim().isEmpty ? null : _send,
            ),
          ]),
        ),
      ),
    ]);
  }
}

// ==================================================================== takeover inbox
class _TakeoverTab extends StatefulWidget {
  const _TakeoverTab();
  @override
  State<_TakeoverTab> createState() => _TakeoverTabState();
}

class _TakeoverTabState extends State<_TakeoverTab> with AutomaticKeepAliveClientMixin {
  bool _loading = true;
  Object? _error;
  List<Map> _items = const [];
  int? _busyId;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await context.read<AppState>().api.bizBuilderInbox();
      if (!mounted) return;
      setState(() {
        _items = ((r['items'] as List?) ?? const []).whereType<Map>().toList();
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _toggle(Map it) async {
    final t = AppLocalizations.of(context);
    final id = it['thread_id'] as int;
    final on = it['owner_takeover'] != true;
    setState(() => _busyId = id);
    try {
      await context.read<AppState>().api.bizAgentHandover(id, on);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(on ? t.baHandoverOnDone : t.baHandoverOffDone)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(baErrorText(t, e))));
      }
    }
    if (mounted) setState(() => _busyId = null);
    await _load();
  }

  Future<void> _open(int id) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SellerChatScreen(threadId: id)));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final t = AppLocalizations.of(context);
    if (_loading) return const SkeletonList();
    if (_error != null) {
      return StateMessage(
        icon: Icons.cloud_off_rounded,
        title: t.bizLoadFailed,
        message: baErrorText(t, _error!),
        action: FilledButton(onPressed: _load, child: Text(t.bizRetry)),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: _items.isEmpty
          ? ListView(children: [
              const SizedBox(height: Gap.xxl),
              StateMessage(icon: Icons.task_alt_rounded, title: t.bbInboxEmptyTitle, message: t.bbInboxEmptyBody),
            ])
          : ListView(padding: const EdgeInsets.all(Gap.lg), children: [
              BizNote(text: t.bbInboxNote, icon: Icons.notifications_active_rounded),
              for (final it in _items) ...[
                const SizedBox(height: Gap.md),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(Gap.md),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(
                          child: Text(
                              '${(it['customer'] ?? '').toString().isEmpty ? t.bbCustomer : it['customer']} · ${baChannelLabel(t, '${it['channel']}')}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w700)),
                        ),
                        if (((it['unread'] as num?) ?? 0) > 0)
                          Badge(label: Text(bd(context, it['unread']))),
                      ]),
                      const SizedBox(height: Gap.xs),
                      BizStatusChip(
                        label: '${it['reason_text'] ?? ''}',
                        color: it['owner_takeover'] == true
                            ? Theme.of(context).colorScheme.primary
                            : AssistoTokens.of(context).warning,
                      ),
                      if ('${it['last_message'] ?? ''}'.isNotEmpty) ...[
                        const SizedBox(height: Gap.xs),
                        Text('“${it['last_message']}”', maxLines: 3, overflow: TextOverflow.ellipsis),
                      ],
                      const SizedBox(height: Gap.sm),
                      Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
                        FilledButton.tonal(
                          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                          onPressed: _busyId != null ? null : () => _toggle(it),
                          child: Text(it['owner_takeover'] == true ? t.bbHandBack : t.bbTakeOver),
                        ),
                        OutlinedButton(
                          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                          onPressed: () => _open(it['thread_id'] as int),
                          child: Text(t.bbOpenChat),
                        ),
                      ]),
                    ]),
                  ),
                ),
              ],
            ]),
    );
  }
}
