import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../bizagent_api.dart';
import '../../../business_selling_api.dart';
import '../../../l10n/app_localizations.dart';
import '../../../state.dart';
import '../../../theme.dart';
import '../../../widgets/business_ui.dart';
import '../../../widgets/skeleton.dart';
import 'seller_agent_screen.dart' show asciiDigits, baErrorText, bd;

/// G1 — the advanced Business AI Agent ("Night Salesman") seller screens:
///
///  * [AgentBehaviourScreen] — who replies (24/7 · only outside shop hours ·
///    off), resume after a human reply, quiet hours, morning summary,
///    follow-ups, upsell, bundle discount, auto courier, photo / voice
///    understanding, comment-to-inbox and the website chat widget.
///  * [AgentAnswersScreen] — rule-first answers (share answered free, credits
///    saved), the seller's FAQ (learned suggestions need approval) and the
///    post → product links for comment replies.
///  * [AgentReportScreen] — chats, orders, revenue the agent brought, AI cost,
///    profit.
/// Every number comes from the server; a feature that needs an owner key says
/// so instead of pretending.

String _hhmm(BuildContext c, String v) => bd(c, v);

// =====================================================================
class AgentBehaviourScreen extends StatefulWidget {
  const AgentBehaviourScreen({super.key});
  @override
  State<AgentBehaviourScreen> createState() => _AgentBehaviourScreenState();
}

class _AgentBehaviourScreenState extends State<AgentBehaviourScreen> {
  bool _loading = true;
  Object? _error;
  bool _busy = false;
  Map<String, dynamic> _s = {};
  Map<String, dynamic> _g1 = const {};
  Map<String, dynamic> _widget = const {};
  final _resume = TextEditingController();
  final _bundleQty = TextEditingController();
  final _bundlePct = TextEditingController();
  final _origins = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _resume.dispose();
    _bundleQty.dispose();
    _bundlePct.dispose();
    _origins.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final api = context.read<AppState>().api;
    try {
      final setup = await api.bizAgentSetup();
      Map<String, dynamic> w = const {};
      try {
        w = await api.bizAgentWidget();
      } catch (_) {
        w = const {};
      }
      if (!mounted) return;
      final s = Map<String, dynamic>.from((setup['settings'] as Map?) ?? const {});
      final bundle = ((s['bundle_rules'] as List?) ?? const []).cast<Map>();
      setState(() {
        _s = s;
        _g1 = Map<String, dynamic>.from((setup['g1'] as Map?) ?? const {});
        _widget = w;
        _resume.text = bd(context, s['resume_minutes'] ?? 15);
        _bundleQty.text = bundle.isEmpty ? '' : bd(context, bundle.first['min_qty']);
        _bundlePct.text = bundle.isEmpty ? '' : bd(context, bundle.first['off_pct']);
        _origins.text = '${w['origins'] ?? ''}';
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(bd(context, m))));

  Future<void> _save(Map<String, dynamic> body) async {
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final r = await context.read<AppState>().api.bizAgentSaveSettings(body);
      if (!mounted) return;
      setState(() => _s = {..._s, ...Map<String, dynamic>.from((r['settings'] as Map?) ?? const {})});
      _snack(t.g1Saved);
    } catch (e) {
      _snack(baErrorText(t, e));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _saveWidget(Map<String, dynamic> body) async {
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final r = await context.read<AppState>().api.bizAgentSaveWidget(body);
      if (!mounted) return;
      setState(() => _widget = r);
      _snack(t.g1Saved);
    } catch (e) {
      _snack(baErrorText(t, e));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _pickTime(String key, String part) async {
    final cur = Map<String, dynamic>.from((_s[key] as Map?) ?? const {});
    final def = part == 'start' ? '23:00' : '08:00';
    final parts = '${cur[part] ?? def}'.split(':');
    final picked = await showTimePicker(
        context: context,
        initialTime: TimeOfDay(
            hour: int.tryParse(parts.first) ?? 23, minute: int.tryParse(parts.last) ?? 0));
    if (picked == null) return;
    final v = '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
    cur[part] = v;
    cur.putIfAbsent(part == 'start' ? 'end' : 'start', () => part == 'start' ? '08:00' : '23:00');
    await _save({key: cur});
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(appBar: AppBar(title: Text(t.g1BehaviourTitle)), body: _body(t));
  }

  Widget _switch(String key, String title, String sub, {bool enabled = true}) => SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _s[key] == true,
        title: Text(title),
        subtitle: Text(bd(context, sub)),
        onChanged: _busy || !enabled ? null : (v) => _save({key: v}),
      );

  Widget _body(AppLocalizations t) {
    if (_loading) return const SkeletonList();
    if (_error != null) {
      return StateMessage(
        icon: Icons.cloud_off_outlined,
        title: t.bizLoadFailed,
        message: baErrorText(t, _error!),
        action: FilledButton(onPressed: _load, child: Text(t.bizRetry)),
      );
    }
    final mode = '${_s['ai_mode'] ?? 'always'}';
    final hours = (_s['hours'] as Map?) ?? const {};
    final quiet = (_s['quiet_hours'] as Map?) ?? const {};
    final quietOn = quiet['start'] != null;
    final morningHour = (_s['morning_hour'] as num?)?.toInt() ?? 8;
    final visionReady = _g1['vision_ready'] == true;
    final voiceReady = _g1['voice_ready'] == true;
    final resumeMin = (_s['resume_minutes'] as num?)?.toInt() ?? 15;
    final snippet = '${_widget['snippet'] ?? ''}';
    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      BizCard(
        title: t.g1ModeTitle,
        icon: Icons.schedule_outlined,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final m in const ['always', 'outside_hours', 'off'])
            RadioListTile<String>(
              contentPadding: EdgeInsets.zero,
              value: m,
              groupValue: mode,
              title: Text(m == 'always'
                  ? t.g1ModeAlways
                  : m == 'outside_hours'
                      ? t.g1ModeOutside
                      : t.g1ModeOff),
              subtitle: Text(m == 'always'
                  ? t.g1ModeAlwaysSub
                  : m == 'outside_hours'
                      ? t.g1ModeOutsideSub
                      : t.g1ModeOffSub),
              onChanged: _busy ? null : (v) => _save({'ai_mode': v}),
            ),
          if (mode == 'outside_hours' && hours['start'] == null)
            BizNote(text: t.g1ModeNeedsHours, icon: Icons.info_outline, tint: Brand.warning),
        ]),
      ),
      const SizedBox(height: Gap.md),
      BizCard(
        title: t.g1ResumeTitle,
        icon: Icons.support_agent,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(bd(context, t.g1ResumeSub(resumeMin)), style: const TextStyle(height: 1.4)),
          const SizedBox(height: Gap.md),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _resume,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                    labelText: t.g1ResumeLabel, border: const OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: Gap.sm),
            FilledButton(
              onPressed: _busy
                  ? null
                  : () => _save({'resume_minutes': int.tryParse(asciiDigits(_resume.text)) ?? 15}),
              child: Text(t.g1Save),
            ),
          ]),
        ]),
      ),
      const SizedBox(height: Gap.md),
      BizCard(
        title: t.g1QuietTitle,
        icon: Icons.bedtime_outlined,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: quietOn,
            title: Text(t.g1QuietTitle),
            subtitle: Text(t.g1QuietSub),
            onChanged: _busy
                ? null
                : (v) => _save({'quiet_hours': v ? {'start': '23:00', 'end': '08:00'} : {}}),
          ),
          if (quietOn)
            Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _pickTime('quiet_hours', 'start'),
                icon: const Icon(Icons.nights_stay_outlined),
                label: Text('${t.g1From} ${_hhmm(context, '${quiet['start']}')}'),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _pickTime('quiet_hours', 'end'),
                icon: const Icon(Icons.wb_sunny_outlined),
                label: Text('${t.g1To} ${_hhmm(context, '${quiet['end']}')}'),
              ),
            ]),
          const Divider(height: Gap.xl),
          _switch('morning_summary', t.g1MorningTitle,
              t.g1MorningSub('${morningHour.toString().padLeft(2, '0')}:00')),
          if (_s['morning_summary'] == true)
            Wrap(spacing: Gap.sm, children: [
              for (final h in const [6, 7, 8, 9, 10])
                ChoiceChip(
                  label: Text(bd(context, '${h.toString().padLeft(2, '0')}:00')),
                  selected: morningHour == h,
                  onSelected: _busy ? null : (_) => _save({'morning_hour': h}),
                ),
            ]),
        ]),
      ),
      const SizedBox(height: Gap.md),
      BizCard(
        title: t.g1SalesTitle,
        icon: Icons.sell_outlined,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _switch('followups_enabled', t.g1FollowTitle, t.g1FollowSub),
          _switch('upsell_enabled', t.g1UpsellTitle, t.g1UpsellSub),
          _switch('auto_courier', t.g1AutoCourierTitle, t.g1AutoCourierSub),
          const SizedBox(height: Gap.sm),
          Text(t.g1BundleTitle, style: const TextStyle(fontWeight: FontWeight.w700)),
          Text(t.g1BundleSub, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: Gap.sm),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _bundleQty,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                    labelText: t.g1BundleQty, border: const OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: TextField(
                controller: _bundlePct,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                    labelText: t.g1BundlePct, border: const OutlineInputBorder()),
              ),
            ),
          ]),
          const SizedBox(height: Gap.sm),
          FilledButton.tonal(
            onPressed: _busy
                ? null
                : () {
                    final q = int.tryParse(asciiDigits(_bundleQty.text));
                    final p = double.tryParse(asciiDigits(_bundlePct.text));
                    _save({
                      'bundle_rules': (q == null || p == null)
                          ? []
                          : [
                              {'min_qty': q, 'off_pct': p}
                            ]
                    });
                  },
            child: Text(t.g1Save),
          ),
        ]),
      ),
      const SizedBox(height: Gap.md),
      BizCard(
        title: t.g1UnderstandTitle,
        icon: Icons.photo_camera_outlined,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _switch('vision_enabled', t.g1VisionTitle,
              t.g1VisionSub((_g1['vision_credits'] as num?)?.toInt() ?? 0)),
          if (!visionReady) BizNote(text: t.g1VisionNotReady, icon: Icons.key_off_outlined),
          _switch('voice_enabled', t.g1VoiceTitle,
              t.g1VoiceSub((_g1['voice_credits'] as num?)?.toInt() ?? 0)),
          if (!voiceReady) BizNote(text: t.g1VoiceNotReady, icon: Icons.key_off_outlined),
          _switch('comment_dm', t.g1CommentTitle, t.g1CommentSub),
          const SizedBox(height: Gap.sm),
          BizNote(text: t.g1PaymentNote, icon: Icons.verified_user_outlined),
        ]),
      ),
      const SizedBox(height: Gap.md),
      BizCard(
        title: t.g1WidgetTitle,
        icon: Icons.language_outlined,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.g1WidgetSub),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _widget['enabled'] == true,
            title: Text(t.g1WidgetOn),
            onChanged: _busy ? null : (v) => _saveWidget({'enabled': v}),
          ),
          TextField(
            controller: _origins,
            minLines: 1,
            maxLines: 3,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
                labelText: t.g1WidgetOrigins, border: const OutlineInputBorder()),
          ),
          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            FilledButton.tonal(
              onPressed: _busy ? null : () => _saveWidget({'origins': _origins.text}),
              child: Text(t.g1Save),
            ),
            if (snippet.isNotEmpty)
              OutlinedButton(
                onPressed: _busy ? null : () => _saveWidget({'regenerate': true}),
                child: Text(t.g1WidgetNewKey),
              ),
          ]),
          if (snippet.isNotEmpty) ...[
            const SizedBox(height: Gap.md),
            Text(t.g1WidgetSnippet),
            const SizedBox(height: Gap.xs),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(Gap.md),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: SelectableText(snippet,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.4)),
            ),
            TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: snippet));
                _snack(t.g1Copied);
              },
              icon: const Icon(Icons.copy_outlined),
              label: Text(t.g1Copy),
            ),
            Text(t.g1WidgetNewKeyNote, style: Theme.of(context).textTheme.bodySmall),
          ],
        ]),
      ),
    ]);
  }
}

// =====================================================================
class AgentAnswersScreen extends StatefulWidget {
  const AgentAnswersScreen({super.key});
  @override
  State<AgentAnswersScreen> createState() => _AgentAnswersScreenState();
}

class _AgentAnswersScreenState extends State<AgentAnswersScreen> {
  bool _loading = true;
  Object? _error;
  bool _busy = false;
  List<Map<String, dynamic>> _faqs = const [];
  List<Map<String, dynamic>> _links = const [];
  Map<String, dynamic> _rules = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<AppState>().api;
    try {
      final f = await api.bizAgentFaqs();
      final l = await api.bizAgentPostLinks();
      Map<String, dynamic> rep = const {};
      try {
        rep = await api.bizAgentReport();
      } catch (_) {
        rep = const {};
      }
      if (!mounted) return;
      setState(() {
        _faqs = ((f['faqs'] as List?) ?? const []).cast<Map<String, dynamic>>();
        _links = ((l['links'] as List?) ?? const []).cast<Map<String, dynamic>>();
        _rules = Map<String, dynamic>.from((rep['rules'] as Map?) ?? const {});
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

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(bd(context, m))));

  Future<void> _run(Future<void> Function() fn) async {
    final t = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      await fn();
    } catch (e) {
      _snack(baErrorText(t, e));
    }
    if (mounted) setState(() => _busy = false);
    await _load();
  }

  Future<void> _learn() => _run(() async {
        final t = AppLocalizations.of(context);
        final r = await context.read<AppState>().api.bizAgentLearnFaqs();
        final n = (r['suggested'] as num?)?.toInt() ?? 0;
        _snack(n > 0 ? t.g1FaqLearned(n) : t.g1FaqLearnedNone);
      });

  Future<void> _addFaq() async {
    final t = AppLocalizations.of(context);
    final q = TextEditingController();
    final a = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(t.g1FaqAdd),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: q,
              decoration: InputDecoration(labelText: t.g1FaqQuestion, helperText: t.g1FaqQuestionHint),
            ),
            const SizedBox(height: Gap.sm),
            TextField(
              controller: a,
              minLines: 2,
              maxLines: 5,
              decoration: InputDecoration(labelText: t.g1FaqAnswer),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t.g1Cancel)),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(t.g1Save)),
        ],
      ),
    );
    if (ok == true && q.text.trim().isNotEmpty && a.text.trim().isNotEmpty) {
      await _run(() async {
        await context.read<AppState>().api.bizAgentAddFaq(q.text.trim(), a.text.trim());
      });
    }
  }

  Future<void> _addLink() async {
    final t = AppLocalizations.of(context);
    List<Map<String, dynamic>> products = const [];
    try {
      products = await context.read<AppState>().api.productsList();
    } catch (e) {
      _snack(baErrorText(t, e));
      return;
    }
    if (!mounted) return;
    final post = TextEditingController();
    int? pid = products.isEmpty ? null : (products.first['id'] as num?)?.toInt();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: Text(t.g1PostLinksTitle),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: post, decoration: InputDecoration(labelText: t.g1PostId)),
              const SizedBox(height: Gap.sm),
              if (products.isEmpty)
                Text(t.g1NoProducts)
              else
                DropdownButtonFormField<int>(
                  isExpanded: true,
                  value: pid,
                  decoration: InputDecoration(labelText: t.g1Product),
                  items: [
                    for (final p in products)
                      DropdownMenuItem(
                        value: (p['id'] as num).toInt(),
                        child: Text(bd(context, '${p['name']}'),
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (v) => set(() => pid = v),
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t.g1Cancel)),
            FilledButton(onPressed: pid == null ? null : () => Navigator.pop(c, true),
                child: Text(t.g1Save)),
          ],
        ),
      ),
    );
    if (ok == true && pid != null && post.text.trim().isNotEmpty) {
      await _run(() async {
        await context.read<AppState>().api.bizAgentAddPostLink(asciiDigits(post.text.trim()), pid!);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.g1AnswersTitle)),
      floatingActionButton: _loading || _error != null
          ? null
          : FloatingActionButton.extended(
              onPressed: _busy ? null : _addFaq,
              icon: const Icon(Icons.add),
              label: Text(t.g1FaqAdd),
            ),
      body: _body(t),
    );
  }

  Widget _body(AppLocalizations t) {
    if (_loading) return const SkeletonList();
    if (_error != null) {
      return StateMessage(
        icon: Icons.cloud_off_outlined,
        title: t.bizLoadFailed,
        message: baErrorText(t, _error!),
        action: FilledButton(onPressed: _load, child: Text(t.bizRetry)),
      );
    }
    final pct = _rules['rule_pct'] ?? 0;
    final suggested = _faqs.where((f) => f['status'] == 'suggested').toList();
    final approved = _faqs.where((f) => f['status'] == 'approved').toList();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 96), children: [
        BizCard(
          title: t.g1RulesCardTitle,
          icon: Icons.bolt_outlined,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(bd(context, t.g1RuleShare('$pct')),
                style: Theme.of(context).textTheme.titleMedium?.copyWith(height: 1.4)),
            const SizedBox(height: Gap.xs),
            Text(bd(context, t.g1RuleCounts((_rules['rule'] as num?)?.toInt() ?? 0,
                (_rules['ai'] as num?)?.toInt() ?? 0))),
            Text(bd(context, t.g1Saved30((_rules['saved_seller_credits'] as num?)?.toInt() ?? 0)),
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: Gap.sm),
            BizNote(text: t.g1RulesNote, icon: Icons.info_outline),
          ]),
        ),
        const SizedBox(height: Gap.md),
        BizCard(
          title: t.g1FaqTitle,
          icon: Icons.quiz_outlined,
          trailing: TextButton.icon(
            onPressed: _busy ? null : _learn,
            icon: const Icon(Icons.auto_awesome_outlined, size: 18),
            label: Text(t.g1FaqLearn),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (_faqs.isEmpty) Text(t.g1FaqEmpty, style: const TextStyle(height: 1.4)),
            for (final f in suggested) _faqTile(t, f, suggested: true),
            for (final f in approved) _faqTile(t, f),
          ]),
        ),
        const SizedBox(height: Gap.md),
        BizCard(
          title: t.g1PostLinksTitle,
          icon: Icons.comment_outlined,
          trailing: IconButton(
            tooltip: t.g1PostLinksAdd,
            onPressed: _busy ? null : _addLink,
            icon: const Icon(Icons.add_link),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.g1PostLinksSub, style: const TextStyle(height: 1.4)),
            for (final l in _links)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.link),
                title: Text(bd(context, '${l['product']}')),
                subtitle: Text(bd(context, '${l['post_id']}')),
                trailing: IconButton(
                  tooltip: t.g1Delete,
                  icon: const Icon(Icons.delete_outline),
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                            await context
                                .read<AppState>()
                                .api
                                .bizAgentDeletePostLink((l['id'] as num).toInt());
                          }),
                ),
              ),
          ]),
        ),
      ]),
    );
  }

  Widget _faqTile(AppLocalizations t, Map f, {bool suggested = false}) {
    final id = (f['id'] as num).toInt();
    final api = context.read<AppState>().api;
    return Container(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: suggested
            ? Brand.warning.withValues(alpha: 0.12)
            : Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(bd(context, '${f['question']}'), style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.xs),
        Text(bd(context, '${f['answer']}'), style: const TextStyle(height: 1.4)),
        const SizedBox(height: Gap.xs),
        if (suggested) Text(t.g1FaqSuggested, style: Theme.of(context).textTheme.bodySmall),
        if (f['has_price'] == true)
          Text(t.g1FaqHasPrice,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Brand.dangerFill)),
        if (!suggested)
          Text(bd(context, t.g1FaqUsed((f['hits'] as num?)?.toInt() ?? 0)),
              style: Theme.of(context).textTheme.bodySmall),
        Wrap(spacing: Gap.sm, children: [
          if (suggested)
            FilledButton.tonal(
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                        await api.bizAgentEditFaq(id, {'status': 'approved'});
                      }),
              child: Text(t.g1Approve),
            ),
          TextButton(
            onPressed: _busy
                ? null
                : () => _run(() async {
                      if (suggested) {
                        await api.bizAgentEditFaq(id, {'status': 'rejected'});
                      } else {
                        await api.bizAgentDeleteFaq(id);
                      }
                    }),
            child: Text(suggested ? t.g1Reject : t.g1Delete),
          ),
        ]),
      ]),
    );
  }
}

// =====================================================================
class AgentReportScreen extends StatefulWidget {
  const AgentReportScreen({super.key});
  @override
  State<AgentReportScreen> createState() => _AgentReportScreenState();
}

class _AgentReportScreenState extends State<AgentReportScreen> {
  bool _loading = true;
  Object? _error;
  Map<String, dynamic> _d = const {};
  int _days = 30;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final d = await context.read<AppState>().api.bizAgentReport(days: _days);
      if (!mounted) return;
      setState(() {
        _d = d;
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

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(appBar: AppBar(title: Text(t.g1ReportTitle)), body: _body(t));
  }

  Widget _stat(String label, String value, {Color? color}) => ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 140),
        child: Padding(
          padding: const EdgeInsets.only(bottom: Gap.md),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(bd(context, value),
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700, color: color)),
            Text(label, style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
      );

  Widget _body(AppLocalizations t) {
    if (_loading) return const SkeletonList();
    if (_error != null) {
      return StateMessage(
        icon: Icons.cloud_off_outlined,
        title: t.bizLoadFailed,
        message: baErrorText(t, _error!),
        action: FilledButton(onPressed: _load, child: Text(t.bizRetry)),
      );
    }
    final r = (_d['report'] as Map?) ?? const {};
    final profit = r['profit'];
    String money(Object? v) => v == null ? '—' : '৳${(v as num).round()}';
    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      Wrap(spacing: Gap.sm, children: [
        for (final d in const [7, 30, 90])
          ChoiceChip(
            label: Text(bd(context, t.g1Days(d))),
            selected: _days == d,
            onSelected: (_) {
              setState(() => _days = d);
              _load();
            },
          ),
      ]),
      const SizedBox(height: Gap.md),
      BizCard(
        title: t.g1ReportByAgent,
        icon: Icons.insights_outlined,
        child: Wrap(spacing: Gap.lg, children: [
          _stat(t.g1RChats, '${r['chats'] ?? 0}'),
          _stat(t.g1ROrders, '${r['orders'] ?? 0}'),
          _stat(t.g1RRevenue, money(r['revenue'])),
          _stat(t.g1RAiCost, money(r['ai_cost'])),
          _stat(t.g1RGross, money(r['gross_profit'])),
          _stat(t.g1RProfit, money(profit),
              color: profit is num && profit < 0 ? Brand.dangerFill : null),
        ]),
      ),
      const SizedBox(height: Gap.md),
      BizCard(
        title: t.g1RulesCardTitle,
        icon: Icons.bolt_outlined,
        child: Wrap(spacing: Gap.lg, children: [
          _stat(t.g1RRuleReplies, '${r['rule_replies'] ?? 0}'),
          _stat(t.g1RAiReplies, '${r['ai_replies'] ?? 0}'),
          _stat(t.g1RImages, '${r['images'] ?? 0}'),
          _stat(t.g1RVoice, '${r['voice'] ?? 0}'),
        ]),
      ),
      if (r['cost_known'] != true) ...[
        const SizedBox(height: Gap.md),
        BizNote(text: t.g1ReportCostUnknown, icon: Icons.info_outline),
      ],
      const SizedBox(height: Gap.md),
      BizNote(text: t.g1ReportNote, icon: Icons.verified_user_outlined),
    ]);
  }
}
