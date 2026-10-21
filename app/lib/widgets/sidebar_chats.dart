import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';

/// ChatGPT-style chat history in the sidebar: the user's saved conversations
/// (home chat + Assisto AI), pinned first, then most recent. Tap reopens the
/// thread where it belongs; ⋮ renames / pins / deletes. The drawer's search
/// query also filters these titles. Loads lazily when the drawer opens and
/// never blocks the rest of the sidebar (failure = quietly hidden + retry).
class SidebarChats extends StatefulWidget {
  final String query;

  /// Open a saved thread: `source` is 'home' or 'ai', `row` the session JSON.
  final void Function(String source, Map<String, dynamic> row) onOpen;

  /// Owner order: the sidebar has ONE "New chat" entry (the drawer's top
  /// button) — this list only shows history; Assisto AI stays reachable via
  /// the `ai_chat` home shortcut and ChatNav, and AI rows still reopen there.
  const SidebarChats({super.key, required this.query, required this.onOpen});

  @override
  State<SidebarChats> createState() => _SidebarChatsState();
}

class _SidebarChatsState extends State<SidebarChats> {
  static const _collapsedCount = 8;
  List<Map<String, dynamic>>? _rows;
  bool _failed = false;
  bool _all = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    try {
      final rows = await context.read<AppState>().api.chatSessions();
      rows.sort((a, b) =>
          (b['pinned'] == true ? 1 : 0).compareTo(a['pinned'] == true ? 1 : 0));
      if (mounted) setState(() => _rows = rows);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _rename(Map<String, dynamic> row) async {
    final t = AppLocalizations.of(context);
    final ctrl = TextEditingController(text: (row['title'] ?? '').toString());
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.aichatRename),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 120,
          decoration: InputDecoration(hintText: t.aichatRenameHint),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(t.aichatCancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: Text(t.aichatSave)),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.trim().isEmpty || !mounted) return;
    try {
      await context
          .read<AppState>()
          .api
          .chatUpdateSession('${row['id']}', title: name.trim());
      setState(() => row['title'] = name.trim());
    } catch (_) {}
  }

  Future<void> _pin(Map<String, dynamic> row) async {
    final pinned = row['pinned'] != true;
    try {
      await context
          .read<AppState>()
          .api
          .chatUpdateSession('${row['id']}', pinned: pinned);
      row['pinned'] = pinned;
      _rows!.sort((a, b) =>
          (b['pinned'] == true ? 1 : 0).compareTo(a['pinned'] == true ? 1 : 0));
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _delete(Map<String, dynamic> row) async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(t.aichatDeleteConfirm),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.aichatCancel)),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Brand.danger),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.aichatDelete)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await context.read<AppState>().api.chatDeleteSession('${row['id']}');
      setState(() => _rows!.remove(row));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final q = widget.query.trim().toLowerCase();
    final searching = q.isNotEmpty;

    var rows = _rows ?? const <Map<String, dynamic>>[];
    if (searching) {
      rows = rows
          .where((r) => '${r['title'] ?? ''} ${r['snippet'] ?? ''}'
              .toLowerCase()
              .contains(q))
          .toList();
      if (rows.isEmpty) return const SizedBox.shrink();
    }
    final visible =
        (_all || searching) ? rows : rows.take(_collapsedCount).toList();

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.sm, Gap.xs),
        child: Row(children: [
          Expanded(
            child: Text(t.sidebarChats,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                    color: scheme.onSurfaceVariant)),
          ),
        ]),
      ),
      if (_rows == null && !_failed)
        const Padding(
          padding: EdgeInsets.all(Gap.md),
          child: Center(
              child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))),
        )
      else if (_failed)
        ListTile(
          dense: true,
          leading: Icon(Icons.refresh, color: scheme.onSurfaceVariant),
          title: Text(t.aichatLoadFailed,
              maxLines: 2, overflow: TextOverflow.ellipsis),
          onTap: _load,
        )
      else if (rows.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
          child: Text(t.aichatNoChats,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
        )
      else ...[
        for (final r in visible) _row(context, r),
        if (!searching && rows.length > _collapsedCount)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              onPressed: () => setState(() => _all = !_all),
              child: Text(_all ? t.sidebarShowLess : t.sidebarSeeAll),
            ),
          ),
      ],
    ]);
  }

  Widget _row(BuildContext context, Map<String, dynamic> r) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final source = r['source'] == 'home' ? 'home' : 'ai';
    final title = (r['title'] ?? '').toString().trim();
    final pinned = r['pinned'] == true;
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsetsDirectional.only(start: Gap.lg, end: 0),
      leading: Icon(
          source == 'home'
              ? Icons.chat_bubble_outline
              : Icons.auto_awesome_outlined,
          size: 20,
          color: scheme.onSurfaceVariant),
      title: Text(title.isEmpty ? t.aichatUntitled : title,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: () => widget.onOpen(source, r),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (pinned) Icon(Icons.push_pin, size: 14, color: scheme.primary),
        PopupMenuButton<String>(
          tooltip: t.aichatHistory,
          icon: Icon(Icons.more_vert, size: 18, color: scheme.onSurfaceVariant),
          onSelected: (v) {
            if (v == 'rename') _rename(r);
            if (v == 'pin') _pin(r);
            if (v == 'delete') _delete(r);
          },
          itemBuilder: (_) => [
            PopupMenuItem(value: 'rename', child: Text(t.aichatRename)),
            PopupMenuItem(
                value: 'pin',
                child: Text(pinned ? t.aichatUnpin : t.aichatPin)),
            PopupMenuItem(value: 'delete', child: Text(t.aichatDelete)),
          ],
        ),
      ]),
    );
  }
}
