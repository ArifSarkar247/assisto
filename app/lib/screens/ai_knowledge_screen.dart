import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/mem_privacy.dart';
import '../widgets/mem_widgets.dart';
import '../widgets/skeleton.dart';

/// AiKnowledgeScreen — the dedicated "What AI knows about me" TRANSPARENCY page
/// (feature #5, SPEC v2.1 §21, ADVANCED).
///
/// This is a standalone page (NOT the editor): it lays out, plainly, exactly
/// what the assistant has stored about the user, where each item came from
/// (you-added vs AI-learned), and whether it reaches the AI. The user can VIEW
/// each item in detail, DELETE any single item, and CLEAR ALL behind a confirm
/// gate. Honest empty state when nothing is remembered.
///
/// It REUSES the existing memory backend — `AppState.memory` (offline-first DB
/// + sync) for the facts and `MemPrivacy` for the local privacy/consent layer.
/// It never duplicates storage: deletes go through `AppState.removeMemory`, the
/// same path the editor uses, so the two screens stay consistent.
///
/// Why a dedicated page: the memory editor (`MemoryScreen`) previously exposed
/// transparency only as a transient bottom sheet. §21 wants a durable, linkable
/// transparency surface with per-item controls — this page is that surface.
///
/// Zero Bangla literals: every user-facing string is an AppLocalizations getter.
class AiKnowledgeScreen extends StatefulWidget {
  const AiKnowledgeScreen({super.key});
  @override
  State<AiKnowledgeScreen> createState() => _AiKnowledgeScreenState();
}

class _AiKnowledgeScreenState extends State<AiKnowledgeScreen> {
  Map<String, MemFlags> _flags = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadLocal();
  }

  Future<void> _loadLocal() async {
    await MemPrivacy.dropDemoSeed(); // truth: no demo suggestion
    final f = await MemPrivacy.loadFlags();
    if (!mounted) return;
    setState(() {
      _flags = f;
      _loading = false;
    });
  }

  MemFlags _flagsFor(MemoryItem m) =>
      _flags[MemPrivacy.keyOf(m)] ?? const MemFlags();

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final app = context.watch<AppState>();
    final all = app.memory;

    final aiCount = all.where((m) => m.isAi).length;
    final sharedWithAi =
        all.where((m) => !_flagsFor(m).excludeFromAi).length;
    final excluded = all.where((m) => _flagsFor(m).excludeFromAi).length;

    final byCat = <MemCat, List<MemoryItem>>{};
    for (final m in all) {
      byCat.putIfAbsent(MemCategories.bucket(m.category), () => []).add(m);
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(t.aiKnowTitle),
        actions: [
          if (all.isNotEmpty)
            IconButton(
              tooltip: t.memClearAll,
              icon: const Icon(Icons.delete_sweep_rounded,
                  color: Brand.danger),
              onPressed: () => _clearAll(context, app, all),
            ),
        ],
      ),
      body: _loading
          ? const Padding(
              padding: EdgeInsets.all(Gap.md), child: SkeletonList(count: 4))
          : all.isEmpty
              ? _empty(context, t)
              : ListView(
                  padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xxl),
                  children: [
                    _intro(context, t),
                    const SizedBox(height: Gap.lg),
                    _statRow(context, Icons.inventory_2_rounded, Brand.blue,
                        t.memStatTotal, '${all.length}'),
                    _statRow(context, Icons.auto_awesome_rounded, Brand.cyan,
                        t.memStatAi, '$aiCount'),
                    _statRow(context, Icons.cloud_done_rounded, Brand.purple,
                        t.memStatSharedAi, '$sharedWithAi'),
                    _statRow(context, Icons.visibility_off_rounded,
                        Brand.danger, t.memStatExcluded, '$excluded'),
                    const Divider(height: Gap.xl),
                    for (final c in MemCategories.order)
                      if ((byCat[c] ?? const []).isNotEmpty) ...[
                        _catHeader(context, t, c, byCat[c]!.length),
                        for (final m in byCat[c]!)
                          _itemTile(context, t, app, m),
                        const SizedBox(height: Gap.sm),
                      ],
                    const SizedBox(height: Gap.md),
                    _promise(context, t),
                  ],
                ),
    );
  }

  // ---- honest empty state --------------------------------------------------
  Widget _empty(BuildContext context, AppLocalizations t) => StateMessage(
        icon: Icons.visibility_rounded,
        title: t.aiKnowEmptyTitle,
        message: t.aiKnowEmptyBody,
      );

  Widget _intro(BuildContext context, AppLocalizations t) => Text(
        t.aiKnowIntro,
        style: TextStyle(
            height: 1.45,
            color: Theme.of(context).colorScheme.onSurfaceVariant),
      );

  Widget _catHeader(
          BuildContext context, AppLocalizations t, MemCat c, int n) =>
      Padding(
        padding: const EdgeInsets.only(top: Gap.sm, bottom: Gap.xs),
        child: Row(children: [
          Icon(MemCategories.icon(c), size: 18, color: MemCategories.color(c)),
          const SizedBox(width: Gap.sm),
          Text(memCatLabel(t, c),
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(width: Gap.xs),
          Text('($n)',
              style: AType.bodySmall.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ]),
      );

  // ---- per-item: view (expand) + delete ------------------------------------
  Widget _itemTile(BuildContext context, AppLocalizations t, AppState app,
      MemoryItem m) {
    final f = _flagsFor(m);
    final scheme = Theme.of(context).colorScheme;
    final badges = <Widget>[
      _badge(m.isAi ? t.memoryTagAi : t.memoryTagManual,
          m.isAi ? Brand.cyan : Brand.blue),
      if (f.excludeFromAi) _badge(t.memPrivacyExcludeShort, Brand.danger),
      if (f.sensitive) _badge(t.memPrivacySensitive, Brand.warning),
      if (f.private) _badge(t.memPrivacyPrivate, Colors.blueGrey),
    ];
    return Card(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      child: ExpansionTile(
        tilePadding:
            const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xxs),
        childrenPadding:
            const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.md),
        leading: Icon(
            m.isAi ? Icons.auto_awesome_rounded : Icons.edit_note_rounded,
            color: m.isAi ? Brand.cyan : scheme.onSurfaceVariant),
        title: Text(m.title,
            maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Wrap(spacing: 6, runSpacing: 4, children: badges),
        children: [
          if (m.detail.trim().isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(m.detail, style: const TextStyle(height: 1.4)),
            ),
          const SizedBox(height: Gap.sm),
          // provenance line — honest "where this came from"
          Row(children: [
            Icon(m.isAi ? Icons.auto_awesome_rounded : Icons.person_outline_rounded,
                size: 14, color: scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                m.isAi ? t.aiKnowSourceAi : t.aiKnowSourceManual,
                style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ]),
          const SizedBox(height: Gap.sm),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => _deleteItem(context, t, app, m),
              icon: const Icon(Icons.delete_outline_rounded,
                  size: 18, color: Brand.danger),
              label: Text(t.delete,
                  style: const TextStyle(color: Brand.danger)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _badge(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xxs),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
        child: Text(text,
            style: AType.labelSmall.copyWith(fontWeight: FontWeight.w600, color: color)),
      );

  Future<void> _deleteItem(BuildContext context, AppLocalizations t,
      AppState app, MemoryItem m) async {
    await app.removeMemory(m);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(t.commonDeleted),
      action: SnackBarAction(label: t.undo, onPressed: () => app.undoLast()),
    ));
  }

  // ---- clear all (confirm gate) --------------------------------------------
  Future<void> _clearAll(
      BuildContext context, AppState app, List<MemoryItem> all) async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.delete_sweep_rounded, color: Brand.danger),
        title: Text(t.memClearAll),
        content: Text(t.memClearAllBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.cancel)),
          FilledButton(
            style: Brand.dangerButton(),
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
    setState(() => _flags = {});
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(t.memClearAllDone)));
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
              style:
                  AType.titleMedium.copyWith(fontWeight: FontWeight.w700)),
        ]),
      );

  Widget _promise(BuildContext context, AppLocalizations t) => Container(
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          color: Brand.cyan.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        child: Row(children: [
          const Icon(Icons.verified_user_rounded,
              size: 18, color: Brand.cyan),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(t.memTransparencyPromise,
                style: AType.bodyMedium.copyWith(height: 1.4)),
          ),
        ]),
      );
}
