import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../widgets/app_sheet.dart';
import 'retention_source.dart';
import 'retention_widgets.dart';

/// crmauto — two owner screens on top of retention automation:
///  * RetentionScoresScreen: every customer / quote lead with a 0-100 score
///    and EVERY point explained (rule + real value) — not a black box. The
///    rule book (the exact table the server applies) is one tap away.
///  * RetentionAuditScreen: who turned which rule on / off / edited it, each
///    automatic run (sent / not sent / daily limit), feedback ratings.

String _signed(String lang, int p) => p >= 0 ? '+${rtDigits(lang, p)}' : '−${rtDigits(lang, -p)}';

class RetentionScoresScreen extends StatefulWidget {
  final RetentionSource source;
  const RetentionScoresScreen({super.key, required this.source});

  @override
  State<RetentionScoresScreen> createState() => _RetentionScoresScreenState();
}

class _RetentionScoresScreenState extends State<RetentionScoresScreen> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic> _d = const {};
  final _q = TextEditingController();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _d = await widget.source.scores(q: _q.text.trim());
    } catch (e) {
      _error = rtError(e) ?? '';
    }
    if (mounted) setState(() => _loading = false);
  }

  void _search(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _load);
  }

  Future<void> _openRules() async {
    final t = AppLocalizations.of(context);
    final lang = rtLang(context);
    final book = rtMap(_d['rule_book']);
    final bands = rtMap(book['bands']);
    await showAppSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          Text(t.crmAutoRulesTitle, style: Theme.of(ctx).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(t.crmAutoRulesBody(rtDigits(lang, rtInt(bands['hot'], 70)), rtDigits(lang, rtInt(bands['warm'], 40)))),
          const SizedBox(height: 8),
          for (final r in rtList(book['rules']))
            ListTile(
              contentPadding: EdgeInsets.zero,
              minVerticalPadding: 10,
              leading: SizedBox(
                width: 56,
                child: Text(_signed(lang, rtInt(r['points'])),
                    style: Theme.of(ctx).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              ),
              title: Text((r['text'] ?? '').toString()),
            ),
          const SizedBox(height: 8),
          Text(t.crmAutoRulesNoAi, style: Theme.of(ctx).textTheme.bodySmall),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(t.crmAutoScoresTitle),
        actions: [
          if (!_loading && _error == null)
            IconButton(
              tooltip: t.crmAutoRulesTitle,
              icon: const Icon(Icons.rule_rounded),
              onPressed: _openRules,
            ),
        ],
      ),
      body: _body(t),
    );
  }

  Widget _body(AppLocalizations t) {
    if (_loading && _d.isEmpty) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return RtMessage(
        icon: Icons.cloud_off_rounded,
        title: t.rtLoadErrorTitle,
        body: _error!.isNotEmpty ? _error! : t.rtLoadErrorBody,
        action: FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
            onPressed: _load,
            child: Text(t.rtRetry)),
      );
    }
    final lang = rtLang(context);
    final people = rtList(_d['people']);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: withNavBarInset(context, const EdgeInsets.fromLTRB(16, 8, 16, 32)), children: [
        Text(t.crmAutoScoresIntro, style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 8),
        TextField(
          controller: _q,
          onChanged: _search,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search_rounded),
            labelText: t.crmAutoScoresSearch,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        if (people.isEmpty) ...[
          const SizedBox(height: 24),
          Icon(Icons.leaderboard_outlined, size: 56, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 12),
          Text(_q.text.trim().isEmpty ? t.crmAutoScoresEmptyTitle : t.crmAutoScoresNoMatch,
              textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(t.crmAutoScoresEmptyHow, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          Center(
            child: FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(160, 52)),
              icon: const Icon(Icons.rule_rounded),
              label: Text(t.crmAutoRulesSee),
              onPressed: _openRules,
            ),
          ),
        ] else
          for (final p in people) _ScoreTile(person: p, lang: lang),
      ]),
    );
  }
}

class _ScoreTile extends StatelessWidget {
  final Map<String, dynamic> person;
  final String lang;
  const _ScoreTile({required this.person, required this.lang});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final score = rtInt(person['score']);
    final band = (person['band'] ?? 'cold').toString();
    final (bg, fg, label) = switch (band) {
      'hot' => (scheme.primaryContainer, scheme.onPrimaryContainer, t.crmAutoBandHot),
      'warm' => (scheme.tertiaryContainer, scheme.onTertiaryContainer, t.crmAutoBandWarm),
      _ => (scheme.surfaceContainerHighest, scheme.onSurface, t.crmAutoBandCold),
    };
    final name = (person['name'] ?? '').toString();
    final parts = rtList(person['parts']);
    final sub = [
      (person['key_masked'] ?? '').toString(),
      if (person['lead'] == true) t.crmAutoLeadTag,
      if (person['do_not_message'] == true) t.crmAutoDoNotMessage,
    ].where((s) => s.isNotEmpty).join(' · ');
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        leading: Semantics(
          label: t.crmAutoScoreA11y(rtDigits(lang, score), label),
          excludeSemantics: true,
          child: Container(
            constraints: const BoxConstraints(minWidth: 56, minHeight: 48),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(rtDigits(lang, score),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(color: fg, fontWeight: FontWeight.w800)),
              Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg)),
            ]),
          ),
        ),
        title: Text(name.isNotEmpty ? name : t.crmAutoNoName),
        subtitle: sub.isEmpty ? null : Text(sub),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(t.crmAutoWhyScore, style: Theme.of(context).textTheme.titleSmall),
          ),
          const SizedBox(height: 4),
          for (final x in parts)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(
                  width: 52,
                  child: Text(_signed(lang, rtInt(x['points'])),
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
                Expanded(
                  child: Text((x['value'] ?? '').toString().isEmpty
                      ? (x['rule'] ?? '').toString()
                      : t.crmAutoRuleWithValue((x['rule'] ?? '').toString(), (x['value'] ?? '').toString())),
                ),
              ]),
            ),
          if (person['do_not_message'] == true)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(children: [
                const Icon(Icons.block_rounded, size: 18),
                const SizedBox(width: 6),
                Expanded(child: Text(t.crmAutoDoNotMessageBody)),
              ]),
            ),
        ],
      ),
    );
  }
}

class RetentionAuditScreen extends StatefulWidget {
  final RetentionSource source;
  const RetentionAuditScreen({super.key, required this.source});

  @override
  State<RetentionAuditScreen> createState() => _RetentionAuditScreenState();
}

class _RetentionAuditScreenState extends State<RetentionAuditScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _rows = const [];

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
      _rows = rtList((await widget.source.audit())['rows']);
    } catch (e) {
      _error = rtError(e) ?? '';
    }
    if (mounted) setState(() => _loading = false);
  }

  IconData _icon(String a) => switch (a) {
        'auto_on' => Icons.toggle_on_outlined,
        'auto_off' => Icons.toggle_off_outlined,
        'auto_create' => Icons.add_circle_outline_rounded,
        'auto_edit' => Icons.edit_outlined,
        'auto_delete' => Icons.delete_outline_rounded,
        'caps_edit' => Icons.tune_rounded,
        'auto_run' => Icons.schedule_send_outlined,
        'feedback' => Icons.star_rate_outlined,
        'opt_out_owner' => Icons.block_rounded,
        _ => Icons.history_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(appBar: AppBar(title: Text(t.crmAutoAuditTitle)), body: _body(t));
  }

  Widget _body(AppLocalizations t) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return RtMessage(
        icon: Icons.cloud_off_rounded,
        title: t.rtLoadErrorTitle,
        body: _error!.isNotEmpty ? _error! : t.rtLoadErrorBody,
        action: FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
            onPressed: _load,
            child: Text(t.rtRetry)),
      );
    }
    if (_rows.isEmpty) {
      return RtMessage(
        icon: Icons.history_rounded,
        title: t.crmAutoAuditEmptyTitle,
        body: t.crmAutoAuditEmptyHow,
        action: FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(160, 52)),
            onPressed: () => Navigator.of(context).maybePop(),
            child: Text(t.crmAutoAuditBack)),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(8, 8, 8, 32)),
        itemCount: _rows.length,
        separatorBuilder: (context, i) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final r = _rows[i];
          final by = (r['by'] ?? '').toString();
          final when = rtWhen(context, r['at']);
          return ListTile(
            minVerticalPadding: 10,
            leading: Icon(_icon((r['action'] ?? '').toString())),
            title: Text((r['text'] ?? '').toString()),
            subtitle: Text(by.isEmpty ? when : '$by · $when'),
          );
        },
      ),
    );
  }
}
