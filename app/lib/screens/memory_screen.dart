import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/skeleton.dart';
import '../widgets/mem_privacy.dart';
import '../widgets/mem_widgets.dart';

/// Memory — "What Assisto knows about me" (SPEC v2.1 §21, ADVANCED).
///
/// Advanced vs the GOOD build: items are bucketed into six canonical
/// categories (family / health / preferences / work / important dates /
/// other) with filter chips + counts; every item carries honest provenance
/// (you-added vs AI-learned-with-consent); the user has per-item **privacy
/// controls** (mark private, mark sensitive, exclude from AI) stored locally;
/// AI-proposed facts go through a **confirm-before-learn** consent queue so the
/// AI never silently remembers anything; and a **data-rights** menu exports or
/// clears everything. A transparency sheet lays out, in plain language, exactly
/// what is remembered and what reaches the AI — so the user can trust it.
///
/// The natural-language retrieval box + deterministic ranking
/// (`searchMemory`, mirror of backend `reminders_engine.search_memory`) is
/// preserved. Zero Bangla literals live in this file.
class MemoryScreen extends StatefulWidget {
  const MemoryScreen({super.key});
  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen> {
  final _q = TextEditingController();
  String _query = '';
  MemCat? _category; // active category filter (null = all)
  bool _showPrivate = false; // reveal items marked private

  Map<String, MemFlags> _flags = {};
  List<MemPending> _pending = [];
  bool _loadingLocal = true; // loading the local privacy/consent layer

  @override
  void initState() {
    super.initState();
    _loadLocal();
  }

  Future<void> _loadLocal() async {
    await MemPrivacy.seedIfFirstRun();
    final f = await MemPrivacy.loadFlags();
    final p = await MemPrivacy.loadPending();
    if (!mounted) return;
    setState(() {
      _flags = f;
      _pending = p;
      _loadingLocal = false;
    });
  }

  MemFlags _flagsFor(MemoryItem m) =>
      _flags[MemPrivacy.keyOf(m)] ?? const MemFlags();

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final app = context.watch<AppState>();
    final all = app.memory;

    // counts per canonical category (respecting the private toggle)
    final visible = all
        .where((m) => _showPrivate || !_flagsFor(m).private)
        .toList();
    final counts = <MemCat, int>{};
    for (final m in visible) {
      final c = MemCategories.bucket(m.category);
      counts[c] = (counts[c] ?? 0) + 1;
    }

    // filter by category
    List<MemoryItem> shown = visible;
    if (_category != null) {
      shown = shown
          .where((m) => MemCategories.bucket(m.category) == _category)
          .toList();
    }

    // rank
    List<_Ranked> ranked;
    if (_query.trim().isNotEmpty) {
      ranked = searchMemory(_query, shown);
    } else {
      ranked = [for (final m in shown) _Ranked(m, 0, const [])];
    }

    final hiddenPrivate =
        all.where((m) => _flagsFor(m).private).length;
    final excludedCount =
        all.where((m) => _flagsFor(m).excludeFromAi).length;

    return Scaffold(
      appBar: AppBar(
        title: Text(t.memoryScreenTitle),
        actions: [
          IconButton(
            tooltip: t.memTransparencyTitle,
            onPressed: () => _openTransparency(context, all, excludedCount),
            icon: const Icon(Icons.visibility_outlined),
          ),
          IconButton(
            tooltip: app.syncing ? t.memoryTagSyncing : t.memSync,
            onPressed: app.syncing ? null : () => app.sync(),
            icon: app.syncing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync),
          ),
          PopupMenuButton<String>(
            tooltip: t.memDataRights,
            onSelected: (v) {
              if (v == 'export') _exportAll(context, all);
              if (v == 'clear') _clearAll(context, app, all);
              if (v == 'private') {
                setState(() => _showPrivate = !_showPrivate);
              }
            },
            itemBuilder: (_) => [
              CheckedPopupMenuItem(
                value: 'private',
                checked: _showPrivate,
                child: Text(t.memShowPrivate),
              ),
              PopupMenuItem(
                value: 'export',
                child: Row(children: [
                  const Icon(Icons.download_outlined, size: 18),
                  const SizedBox(width: Gap.sm),
                  Text(t.memExport),
                ]),
              ),
              PopupMenuItem(
                value: 'clear',
                child: Row(children: [
                  const Icon(Icons.delete_sweep_outlined,
                      size: 18, color: Brand.danger),
                  const SizedBox(width: Gap.sm),
                  Text(t.memClearAll,
                      style: const TextStyle(color: Brand.danger)),
                ]),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context),
        icon: const Icon(Icons.add),
        label: Text(t.add),
      ),
      body: Column(
        children: [
          // offline banner — honest connectivity state
          if (!app.online)
            Container(
              width: double.infinity,
              color: Brand.warning.withValues(alpha: 0.15),
              padding: const EdgeInsets.symmetric(
                  horizontal: Gap.md, vertical: Gap.sm),
              child: Row(children: [
                const Icon(Icons.cloud_off_outlined,
                    size: 16, color: Brand.warning),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Text(t.memOfflineBanner,
                      style: const TextStyle(
                          fontSize: 12, color: Brand.warning)),
                ),
              ]),
            ),
          // retrieval box
          Padding(
            padding:
                const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.sm),
            child: TextField(
              controller: _q,
              onChanged: (v) => setState(() => _query = v),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: t.memorySearchHint,
                prefixIcon: const Icon(Icons.psychology_alt_outlined),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: t.close,
                        icon: const Icon(Icons.clear),
                        onPressed: () => setState(() {
                          _q.clear();
                          _query = '';
                        }),
                      ),
              ),
            ),
          ),
          if (counts.isNotEmpty)
            MemCategoryBar(
              selected: _category,
              counts: counts,
              onSelect: (c) => setState(() => _category = c),
            ),
          Expanded(child: _body(context, t, app, all, ranked, hiddenPrivate)),
        ],
      ),
    );
  }

  Widget _body(
    BuildContext context,
    AppLocalizations t,
    AppState app,
    List<MemoryItem> all,
    List<_Ranked> ranked,
    int hiddenPrivate,
  ) {
    // loading state — pulling the local privacy layer or a first sync
    if (_loadingLocal) {
      return const Padding(
        padding: EdgeInsets.all(Gap.md),
        child: SkeletonList(count: 4),
      );
    }

    // error state — last sync failed and we have nothing cached
    if (app.lastError != null && all.isEmpty && !app.online) {
      return StateMessage(
        icon: Icons.error_outline,
        tint: Brand.danger,
        title: t.memErrorTitle,
        message: t.memErrorBody,
        action: FilledButton.icon(
          onPressed: () => app.sync(),
          icon: const Icon(Icons.refresh),
          label: Text(t.retry),
        ),
      );
    }

    final hasConsent = _pending.isNotEmpty;

    // empty state
    if (all.isEmpty && !hasConsent) {
      return StateMessage(
        icon: Icons.psychology_outlined,
        title: t.memoryEmptyTitle,
        message: t.memoryEmptyHint,
        action: FilledButton.icon(
          onPressed: () => _edit(context),
          icon: const Icon(Icons.add),
          label: Text(t.memAddFirst),
        ),
      );
    }

    // no search results
    if (ranked.isEmpty && !hasConsent) {
      return StateMessage(
        icon: Icons.search_off,
        title: t.memoryNoResultsTitle,
        message: hiddenPrivate > 0
            ? t.memNoResultsPrivate
            : t.memoryNoResultsHint,
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, 96),
      children: [
        // consent queue — confirm before the AI learns
        if (hasConsent && _query.trim().isEmpty && _category == null) ...[
          for (final p in _pending)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.sm),
              child: MemConsentCard(
                pending: p,
                localizedTitle: _pendingTitle(t, p),
                onConfirm: () => _confirmPending(context, p),
                onDismiss: () => _dismissPending(p),
              ),
            ),
          const SizedBox(height: Gap.xs),
        ],
        for (final r in ranked)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.sm),
            child: MemItemCard(
              item: r.item,
              flags: _flagsFor(r.item),
              category: MemCategories.bucket(r.item.category),
              onTap: () => _edit(context, item: r.item),
              onEdit: () => _edit(context, item: r.item),
              onDelete: () => _delete(context, app, r.item),
              onPrivacy: () => _privacy(context, r.item),
            ),
          ),
      ],
    );
  }

  // ---- AI-learned facts (confirm before learn) -----------------------------
  String _pendingTitle(AppLocalizations t, MemPending p) {
    // seeded demo suggestion → localized sample; real captures carry their text
    if (p.id == 'seed-1') return t.memConsentSample;
    final isBn = Localizations.localeOf(context).languageCode == 'bn';
    final chosen = isBn ? p.titleBn : p.title;
    return chosen.isNotEmpty ? chosen : (p.title.isNotEmpty ? p.title : p.titleBn);
  }

  Future<void> _confirmPending(BuildContext context, MemPending p) async {
    final t = AppLocalizations.of(context);
    final app = context.read<AppState>();
    final title = _pendingTitle(t, p);
    final cat = p.category.isNotEmpty ? p.category : MemCategories.id[MemCat.preferences]!;
    await app.addMemory(title: title, category: cat, detail: p.detail);
    // the item is created manually; keep an honest "AI suggested, you approved"
    // provenance note in the detail-free world via category id only.
    final next = [..._pending]..removeWhere((e) => e.id == p.id);
    await MemPrivacy.savePending(next);
    if (!mounted) return;
    setState(() => _pending = next);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(t.memConsentSaved)),
    );
  }

  Future<void> _dismissPending(MemPending p) async {
    final next = [..._pending]..removeWhere((e) => e.id == p.id);
    await MemPrivacy.savePending(next);
    if (!mounted) return;
    setState(() => _pending = next);
  }

  // ---- add / edit ----------------------------------------------------------
  Future<void> _edit(BuildContext context, {MemoryItem? item}) async {
    final t = AppLocalizations.of(context);
    final app = context.read<AppState>();
    final title = TextEditingController(text: item?.title ?? '');
    final detail = TextEditingController(text: item?.detail ?? '');
    MemCat cat =
        item != null ? MemCategories.bucket(item.category) : MemCat.other;
    var flags = item != null ? _flagsFor(item) : const MemFlags();

    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: Gap.lg,
          right: Gap.lg,
          top: Gap.sm,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + Gap.lg,
        ),
        child: StatefulBuilder(
          builder: (ctx, setSheet) => SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    item == null ? t.memoryNewItemTitle : t.memoryEditItemTitle,
                    style: Theme.of(ctx).textTheme.titleLarge),
                const SizedBox(height: Gap.lg),
                TextField(
                  controller: title,
                  autofocus: item == null,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    labelText: t.memoryTitleLabel,
                    prefixIcon: const Icon(Icons.lightbulb_outline),
                  ),
                ),
                const SizedBox(height: Gap.md),
                TextField(
                  controller: detail,
                  maxLines: 3,
                  minLines: 2,
                  decoration: InputDecoration(
                    labelText: t.memoryDetailLabel,
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: Gap.lg),
                Text(t.memoryCategoryLabel,
                    style: Theme.of(ctx).textTheme.labelLarge),
                const SizedBox(height: Gap.sm),
                Wrap(
                  spacing: Gap.sm,
                  runSpacing: Gap.sm,
                  children: [
                    for (final c in MemCategories.order)
                      ChoiceChip(
                        avatar: Icon(MemCategories.icon(c),
                            size: 16,
                            color: cat == c
                                ? Colors.white
                                : MemCategories.color(c)),
                        label: Text(memCatLabel(t, c)),
                        selected: cat == c,
                        selectedColor: MemCategories.color(c),
                        labelStyle: TextStyle(
                            color: cat == c ? Colors.white : null,
                            fontWeight: FontWeight.w600),
                        onSelected: (_) => setSheet(() => cat = c),
                      ),
                  ],
                ),
                const SizedBox(height: Gap.lg),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.lock_outline),
                  title: Text(t.memPrivacyControls),
                  subtitle: Text(t.memPrivacyExplain,
                      style: const TextStyle(fontSize: 12)),
                  children: [
                    MemSwitchRow(
                      icon: Icons.visibility_off_outlined,
                      color: Brand.danger,
                      title: t.memPrivacyExclude,
                      subtitle: t.memPrivacyExcludeHint,
                      value: flags.excludeFromAi,
                      onChanged: (v) => setSheet(() =>
                          flags = flags.copyWith(excludeFromAi: v)),
                    ),
                    MemSwitchRow(
                      icon: Icons.shield_outlined,
                      color: Brand.warning,
                      title: t.memPrivacySensitive,
                      subtitle: t.memPrivacySensitiveHint,
                      value: flags.sensitive,
                      onChanged: (v) =>
                          setSheet(() => flags = flags.copyWith(sensitive: v)),
                    ),
                    MemSwitchRow(
                      icon: Icons.lock_outline,
                      color: Colors.blueGrey,
                      title: t.memPrivacyPrivate,
                      subtitle: t.memPrivacyPrivateHint,
                      value: flags.private,
                      onChanged: (v) =>
                          setSheet(() => flags = flags.copyWith(private: v)),
                    ),
                  ],
                ),
                const SizedBox(height: Gap.md),
                Row(children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: Text(t.cancel),
                    ),
                  ),
                  const SizedBox(width: Gap.md),
                  Expanded(
                    child: FilledButton(
                      onPressed: title.text.trim().isEmpty
                          ? null
                          : () => Navigator.pop(ctx, true),
                      child: Text(t.save),
                    ),
                  ),
                ]),
              ],
            ),
          ),
        ),
      ),
    );

    if (ok != true || title.text.trim().isEmpty) return;
    final catId = MemCategories.id[cat]!;
    if (item == null) {
      await app.addMemory(
          title: title.text.trim(),
          category: catId,
          detail: detail.text.trim());
      // the newest item is first (ordering = -updated_at); attach its flags
      final created = app.memory.isNotEmpty ? app.memory.first : null;
      if (created != null && !flags.isDefault) {
        await _setFlags(created, flags);
      }
    } else {
      await app.editMemory(item,
          title: title.text.trim(),
          category: catId,
          detail: detail.text.trim());
      await _setFlags(item, flags);
    }
    if (mounted) setState(() {});
  }

  // ---- privacy sheet (standalone, from the item menu) ----------------------
  Future<void> _privacy(BuildContext context, MemoryItem m) async {
    final t = AppLocalizations.of(context);
    var flags = _flagsFor(m);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.memPrivacyControls,
                  style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: Gap.xs),
              Text(m.title,
                  style: TextStyle(
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
              const SizedBox(height: Gap.md),
              MemSwitchRow(
                icon: Icons.visibility_off_outlined,
                color: Brand.danger,
                title: t.memPrivacyExclude,
                subtitle: t.memPrivacyExcludeHint,
                value: flags.excludeFromAi,
                onChanged: (v) {
                  setSheet(() => flags = flags.copyWith(excludeFromAi: v));
                  _setFlags(m, flags);
                },
              ),
              MemSwitchRow(
                icon: Icons.shield_outlined,
                color: Brand.warning,
                title: t.memPrivacySensitive,
                subtitle: t.memPrivacySensitiveHint,
                value: flags.sensitive,
                onChanged: (v) {
                  setSheet(() => flags = flags.copyWith(sensitive: v));
                  _setFlags(m, flags);
                },
              ),
              MemSwitchRow(
                icon: Icons.lock_outline,
                color: Colors.blueGrey,
                title: t.memPrivacyPrivate,
                subtitle: t.memPrivacyPrivateHint,
                value: flags.private,
                onChanged: (v) {
                  setSheet(() => flags = flags.copyWith(private: v));
                  _setFlags(m, flags);
                },
              ),
            ],
          ),
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _setFlags(MemoryItem m, MemFlags f) async {
    final key = MemPrivacy.keyOf(m);
    final next = {..._flags};
    if (f.isDefault) {
      next.remove(key);
    } else {
      next[key] = f;
    }
    await MemPrivacy.saveFlags(next);
    if (mounted) setState(() => _flags = next);
  }

  // ---- delete (with undo) --------------------------------------------------
  Future<void> _delete(
      BuildContext context, AppState app, MemoryItem m) async {
    final t = AppLocalizations.of(context);
    await app.removeMemory(m);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(t.commonDeleted),
      action: SnackBarAction(label: t.undo, onPressed: () => app.undoLast()),
    ));
  }

  // ---- data rights: export -------------------------------------------------
  Future<void> _exportAll(BuildContext context, List<MemoryItem> all) async {
    final t = AppLocalizations.of(context);
    final buf = StringBuffer();
    buf.writeln(t.memExportHeader);
    buf.writeln('');
    for (final m in all) {
      final cat = memCatLabel(t, MemCategories.bucket(m.category));
      final f = _flagsFor(m);
      final tags = [
        m.isAi ? t.memoryTagAi : t.memoryTagManual,
        if (f.excludeFromAi) t.memPrivacyExcludeShort,
        if (f.sensitive) t.memPrivacySensitive,
        if (f.private) t.memPrivacyPrivate,
      ].join(', ');
      buf.writeln('• [$cat] ${m.title}');
      if (m.detail.isNotEmpty) buf.writeln('  ${m.detail}');
      buf.writeln('  ($tags)');
      buf.writeln('');
    }
    final text = buf.toString();
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.memExport),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(t.memExportCopied,
                  style: TextStyle(
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
              const SizedBox(height: Gap.md),
              Container(
                padding: const EdgeInsets.all(Gap.sm),
                decoration: BoxDecoration(
                  color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(Radii.sm),
                ),
                child: SelectableText(text,
                    style: const TextStyle(fontSize: 12, height: 1.4)),
              ),
            ]),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(t.close)),
        ],
      ),
    );
  }

  // ---- data rights: clear all ----------------------------------------------
  Future<void> _clearAll(
      BuildContext context, AppState app, List<MemoryItem> all) async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.delete_sweep_outlined, color: Brand.danger),
        title: Text(t.memClearAll),
        content: Text(t.memClearAllBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.cancel)),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Brand.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.memClearAllConfirm),
          ),
        ],
      ),
    );
    if (ok != true) return;
    for (final m in [...all]) {
      await app.removeMemory(m);
    }
    await MemPrivacy.saveFlags({});
    await MemPrivacy.savePending([]);
    if (!mounted) return;
    setState(() {
      _flags = {};
      _pending = [];
    });
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(t.memClearAllDone)));
  }

  // ---- transparency: "what Assisto knows about me" -------------------------
  void _openTransparency(
      BuildContext context, List<MemoryItem> all, int excluded) {
    final t = AppLocalizations.of(context);
    final byCat = <MemCat, int>{};
    for (final m in all) {
      final c = MemCategories.bucket(m.category);
      byCat[c] = (byCat[c] ?? 0) + 1;
    }
    final aiCount = all.where((m) => m.isAi).length;
    final sharedWithAi =
        all.where((m) => !_flagsFor(m).excludeFromAi).length;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        builder: (ctx, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xl),
          children: [
            Row(children: [
              const Icon(Icons.visibility_outlined, color: Brand.blue),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(t.memTransparencyTitle,
                    style: Theme.of(ctx).textTheme.titleLarge),
              ),
            ]),
            const SizedBox(height: Gap.sm),
            Text(t.memTransparencyIntro,
                style: TextStyle(
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    height: 1.4)),
            const SizedBox(height: Gap.lg),
            _statRow(ctx, Icons.inventory_2_outlined, Brand.blue,
                t.memStatTotal, '${all.length}'),
            _statRow(ctx, Icons.auto_awesome, Brand.cyan, t.memStatAi,
                '$aiCount'),
            _statRow(ctx, Icons.cloud_done_outlined, Brand.purple,
                t.memStatSharedAi, '$sharedWithAi'),
            _statRow(ctx, Icons.visibility_off_outlined, Brand.danger,
                t.memStatExcluded, '$excluded'),
            const Divider(height: Gap.xl),
            Text(t.memTransparencyByCat,
                style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: Gap.sm),
            if (all.isEmpty)
              Text(t.memoryEmptyTitle,
                  style: TextStyle(
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant))
            else
              for (final c in MemCategories.order)
                if ((byCat[c] ?? 0) > 0)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(MemCategories.icon(c),
                        color: MemCategories.color(c)),
                    title: Text(memCatLabel(t, c)),
                    trailing: Text('${byCat[c]}',
                        style:
                            const TextStyle(fontWeight: FontWeight.w700)),
                  ),
            const SizedBox(height: Gap.md),
            Container(
              padding: const EdgeInsets.all(Gap.md),
              decoration: BoxDecoration(
                color: Brand.cyan.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(Radii.md),
              ),
              child: Row(children: [
                const Icon(Icons.verified_user_outlined,
                    size: 18, color: Brand.cyan),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Text(t.memTransparencyPromise,
                      style: const TextStyle(fontSize: 13, height: 1.4)),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statRow(BuildContext ctx, IconData icon, Color color, String label,
          String value) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: color.withValues(alpha: 0.14),
            child: Icon(icon, size: 18, color: color),
          ),
          const SizedBox(width: Gap.md),
          Expanded(child: Text(label)),
          Text(value,
              style: const TextStyle(
                  fontWeight: FontWeight.w700, fontSize: 16)),
        ]),
      );
}

// ---------------------------------------------------------------- search
class _Ranked {
  final MemoryItem item;
  final double score;
  final List<String> matched;
  _Ranked(this.item, this.score, this.matched);
}

// Question-framing stopwords (mirror of backend reminders_engine._MEMORY_STOP).
// Bangla keywords are \u-escaped so no Bangla literal appears in this .dart file.
const _memoryStop = {
  'what', 'did', 'i', 'tell', 'you', 'about', 'me', 'my', 'the', 'a', 'an',
  'do', 'know', 'remember', 'said', 'was', 'is', 'of',
  '\u0986\u09ae\u09bf',
  '\u09a4\u09cb\u09ae\u09be\u0995\u09c7',
  '\u0986\u09aa\u09a8\u09be\u0995\u09c7',
  '\u0995\u09c0',
  '\u0995\u09bf',
  '\u09ac\u09b2\u09c7\u099b\u09bf\u09b2\u09be\u09ae',
  '\u09ac\u09b2\u09c7\u099b\u09bf',
  '\u09b8\u09ae\u09cd\u09aa\u09b0\u09cd\u0995\u09c7',
  '\u09a8\u09bf\u09af\u09bc\u09c7',
  '\u09a4\u09c1\u09ae\u09bf',
  '\u0986\u09aa\u09a8\u09bf',
  '\u099c\u09be\u09a8\u09cb',
  '\u099c\u09be\u09a8\u09c7\u09a8',
  '\u0986\u09ae\u09be\u09b0',
  '\u09ae\u09a8\u09c7',
  '\u0986\u099b\u09c7',
  '\u0995\u09c7',
  '\u099f\u09be',
  '\u09ac\u09bf\u09b7\u09af\u09bc\u09c7',
  '\u09ac\u09cd\u09af\u09be\u09aa\u09be\u09b0\u09c7',
  '\u0995\u09cb\u09a5\u09be\u09af\u09bc',
  '\u0995\u0996\u09a8',
  '\u0995\u09a4',
};

List<String> _tokens(String s) {
  const bn = '\u09e6\u09e7\u09e8\u09e9\u09ea\u09eb\u09ec\u09ed\u09ee\u09ef';
  final buf = StringBuffer();
  for (final ch in s.runes) {
    final i = bn.runes.toList().indexOf(ch);
    buf.writeCharCode(i >= 0 ? 0x30 + i : ch);
  }
  return buf
      .toString()
      .toLowerCase()
      .split(RegExp(r'''[\s,.!?;:\-/()"']+'''))
      .where((x) => x.isNotEmpty)
      .toList();
}

bool _fuzzy(String hay, String needle) {
  if (hay.contains(needle)) return true;
  if (needle.length >= 4 && (hay.startsWith(needle) || needle.startsWith(hay))) {
    return true;
  }
  return false;
}

/// Deterministic ranking mirror of backend reminders_engine.search_memory.
List<_Ranked> searchMemory(String query, List<MemoryItem> items) {
  final terms = _tokens(query)
      .where((x) => !_memoryStop.contains(x) && x.length > 1)
      .toList();
  final effective = terms.isEmpty ? _tokens(query) : terms;
  final scored = <_Ranked>[];
  for (final m in items) {
    final titleToks = _tokens(m.title);
    final detailToks = _tokens(m.detail);
    final catToks = _tokens(m.category);
    double score = 0;
    final matched = <String>[];
    for (final term in effective) {
      bool hit = false;
      if (titleToks.contains(term)) {
        score += 3;
        hit = true;
      } else if (titleToks.any((x) => _fuzzy(x, term))) {
        score += 2;
        hit = true;
      }
      if (catToks.contains(term)) {
        score += 2;
        hit = true;
      } else if (catToks.any((x) => _fuzzy(x, term))) {
        score += 1;
        hit = true;
      }
      if (detailToks.contains(term)) {
        score += 1;
        hit = true;
      } else if (detailToks.any((x) => _fuzzy(x, term))) {
        score += 0.5;
        hit = true;
      }
      if (hit) matched.add(term);
    }
    if (score > 0) scored.add(_Ranked(m, score, matched));
  }
  scored.sort((a, b) => b.score.compareTo(a.score));
  return scored;
}
