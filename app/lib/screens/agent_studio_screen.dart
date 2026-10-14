import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import '../widgets/studio_engine.dart';
import '../widgets/studio_cards.dart';
import '../widgets/studio_builder_sheet.dart';
import 'social_compose_screen.dart';

/// Agent Studio (SPEC v2.1 §21, ADVANCED) — the user builds their own little
/// AI automations: readable WHEN … IF … THEN mini-agents with trigger(s) →
/// condition(s) → action(s), a templates gallery, test / run-now, enable/
/// disable and run history.
///
/// The rule engine is deterministic and on-device (`studio_engine.dart`,
/// mirroring `backend/core/logic/agent_studio.py`). Automations are stored
/// locally (SharedPreferences). The only AI-flavoured action — "summarize" —
/// is MOCK + key-gated: we show a clearly-labelled mocked preview and say it
/// needs an AI key (Integrations) to run for real. See up_studio_integration.md
/// for the endpoints/models that would persist and fire these server-side.
class AgentStudioScreen extends StatefulWidget {
  const AgentStudioScreen({super.key});
  @override
  State<AgentStudioScreen> createState() => _AgentStudioScreenState();
}

class _AgentStudioScreenState extends State<AgentStudioScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  List<Automation> _items = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await StudioStore.load();
      if (!mounted) return;
      setState(() {
        _items = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _persist() async {
    await StudioStore.save(_items);
  }

  Future<void> _create(Automation seed) async {
    final edited = await StudioBuilderSheet.show(context, seed);
    if (edited == null) return;
    setState(() => _items = [..._items, edited]);
    await _persist();
    _tabs.animateTo(0);
  }

  Future<void> _edit(Automation a) async {
    final edited = await StudioBuilderSheet.show(context, a);
    if (edited == null) return;
    final i = _items.indexWhere((x) => x.id == a.id);
    if (i < 0) return;
    setState(() => _items[i] = edited);
    await _persist();
  }

  Future<void> _delete(Automation a) async {
    setState(() => _items.removeWhere((x) => x.id == a.id));
    await _persist();
  }

  void _toggle(Automation a, bool on) {
    setState(() => a.enabled = on);
    _persist();
  }

  /// Test / Run now — evaluates and records a run deterministically. The due
  /// check here forces the automation (manual run) but still honestly reports
  /// whether it *would* fire on schedule, and records AI actions as mocked.
  Future<void> _runNow(Automation a) async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final now = DateTime.now();
    final entry = RunEntry(
      at: now.toIso8601String(),
      manual: true,
      actionTypes: a.actions.map((x) => x.type).toList(),
      usedAiMock: a.needsAi,
    );
    setState(() {
      a.history = [entry, ...a.history].take(50).toList();
      a.lastFired = now.toIso8601String();
    });
    await _persist();
    messenger.showSnackBar(SnackBar(
      content: Text(a.needsAi ? t.studioRanWithAiMock : t.studioRanOk),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(t.agentStudio),
        actions: [
          // Single bounded entry point to the SOCIAL-MEDIA POST & CAPTION
          // composer (#135, §21) — a separate "mini-tool" opened from Studio.
          IconButton(
            icon: const Icon(Icons.campaign_outlined),
            tooltip: t.socialTitle,
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const SocialComposeScreen())),
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            Tab(child: Text(t.studioTabMine, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
            Tab(child: Text(t.studioTabTemplates, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
          ],
        ),
      ),
      floatingActionButton: AnimatedBuilder(
        animation: _tabs,
        builder: (_, __) => _tabs.index == 0
            ? FloatingActionButton.extended(
                onPressed: () => _create(Automation(
                    id: DateTime.now().microsecondsSinceEpoch.toString())),
                icon: const Icon(Icons.add),
                label: Text(t.studioNew),
              )
            : const SizedBox.shrink(),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _mineTab(t),
          _templatesTab(t),
        ],
      ),
    );
  }

  Widget _mineTab(AppLocalizations t) {
    if (_loading) return const SkeletonList(count: 4);
    if (_error != null) {
      return StateMessage(
        icon: Icons.cloud_off,
        tint: Brand.danger,
        title: t.studioLoadError,
        message: t.checkInternetRetry,
        action: FilledButton.tonal(onPressed: _load, child: Text(t.retry)),
      );
    }
    if (_items.isEmpty) {
      return StateMessage(
        icon: Icons.bolt_rounded,
        title: t.studioEmptyTitle,
        message: t.studioEmptyBody,
        action: FilledButton.tonalIcon(
          onPressed: () => _tabs.animateTo(1),
          icon: const Icon(Icons.auto_awesome, size: 18),
          label: Text(t.studioBrowseTemplates),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 96),
        itemCount: _items.length,
        separatorBuilder: (_, __) => const SizedBox(height: Gap.md),
        itemBuilder: (_, i) {
          final a = _items[i];
          return AutomationTile(
            a: a,
            onToggle: (v) => _toggle(a, v),
            onTap: () => _openDetail(a),
          );
        },
      ),
    );
  }

  Widget _templatesTab(AppLocalizations t) {
    final tpls = StudioTemplates.build();
    final icons = {
      't_bill': Icons.receipt_long_outlined,
      't_summary': Icons.summarize_outlined,
      't_followup': Icons.reply_outlined,
      't_birthday': Icons.cake_outlined,
    };
    return ListView(
      padding: const EdgeInsets.all(Gap.lg),
      children: [
        Text(t.studioTemplatesIntro,
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                height: 1.4)),
        const SizedBox(height: Gap.lg),
        for (final tpl in tpls) ...[
          TemplateCard(
            tpl: tpl,
            icon: icons[tpl.id] ?? Icons.bolt_rounded,
            onUse: () => _create(_fromTemplate(t, tpl)),
          ),
          const SizedBox(height: Gap.md),
        ],
      ],
    );
  }

  /// Materialise a template into a concrete, localised automation the user can
  /// then tweak in the builder (resolve the l10n-key seeds to real text).
  Automation _fromTemplate(AppLocalizations t, Automation tpl) {
    final a = tpl.copy();
    a.id = DateTime.now().microsecondsSinceEpoch.toString();
    a.name = resolveSeed(t, a.name);
    for (final ac in a.actions) {
      if (ac.text.startsWith('studioTpl')) ac.text = resolveSeed(t, ac.text);
    }
    return a;
  }

  void _openDetail(Automation a) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _DetailSheet(
        a: a,
        onEdit: () {
          Navigator.of(context).pop();
          _edit(a);
        },
        onRun: () => _runNow(a),
        onToggle: (v) => _toggle(a, v),
        onDelete: () {
          Navigator.of(context).pop();
          _delete(a);
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(AppLocalizations.of(context).commonDeleted)));
        },
      ),
    );
  }
}

/// Automation detail — readable WHEN/IF/THEN, test/run-now, enable, run history.
class _DetailSheet extends StatefulWidget {
  final Automation a;
  final VoidCallback onEdit;
  final Future<void> Function() onRun;
  final ValueChanged<bool> onToggle;
  final VoidCallback onDelete;
  const _DetailSheet({
    required this.a,
    required this.onEdit,
    required this.onRun,
    required this.onToggle,
    required this.onDelete,
  });
  @override
  State<_DetailSheet> createState() => _DetailSheetState();
}

class _DetailSheetState extends State<_DetailSheet> {
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final a = widget.a;
    final scheme = Theme.of(context).colorScheme;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (_, controller) => Column(children: [
        const SizedBox(height: Gap.sm),
        Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
                color: scheme.outlineVariant,
                borderRadius: BorderRadius.circular(2))),
        Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Row(children: [
            Expanded(
              child: Text(a.name,
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.w800)),
            ),
            Switch(
                value: a.enabled,
                onChanged: (v) {
                  setState(() => a.enabled = v);
                  widget.onToggle(v);
                }),
          ]),
        ),
        Expanded(
          child: ListView(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xl),
            children: [
              WhenIfThenCard(a: a),
              const SizedBox(height: Gap.lg),
              Row(children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () async {
                      await widget.onRun();
                      if (mounted) setState(() {});
                    },
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: Text(t.studioRunNow),
                  ),
                ),
                const SizedBox(width: Gap.sm),
                OutlinedButton.icon(
                  onPressed: widget.onEdit,
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: Text(t.edit),
                ),
              ]),
              if (a.needsAi) ...[
                const SizedBox(height: Gap.md),
                const AiMockBanner(),
              ],
              const SizedBox(height: Gap.xl),
              Text(t.studioHistoryTitle,
                  style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: Gap.sm),
              if (a.history.isEmpty)
                Text(t.studioHistoryEmpty,
                    style: TextStyle(
                        color: scheme.onSurfaceVariant, height: 1.4))
              else
                for (final e in a.history) RunHistoryTile(e: e),
              const SizedBox(height: Gap.xl),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: widget.onDelete,
                  icon: Icon(Icons.delete_outline,
                      size: 18, color: Brand.danger),
                  label: Text(t.delete,
                      style: const TextStyle(color: Brand.danger)),
                ),
              ),
            ],
          ),
        ),
      ]),
    );
  }
}
