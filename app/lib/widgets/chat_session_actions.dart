import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';

/// Shared rename / delete dialogs + ordering for saved chat sessions (home +
/// Assisto AI). Used by the Assisto AI chats page ([AssistoChatsScreen]);
/// this replaced the old sidebar chat list (owner order after build 146: the
/// sidebar list kept growing, so chats now live on their own page).
class ChatSessionActions {
  ChatSessionActions._();

  /// Pinned first, then newest (`updated` / `updated_at`, ISO-8601). Rows with
  /// no parseable time keep their server order after the dated ones of the
  /// same pin group. Sorts [rows] in place and returns it.
  static List<Map<String, dynamic>> sort(List<Map<String, dynamic>> rows) {
    final order = {for (var i = 0; i < rows.length; i++) rows[i]: i};
    DateTime? at(Map<String, dynamic> r) =>
        DateTime.tryParse('${r['updated'] ?? r['updated_at'] ?? ''}');
    rows.sort((a, b) {
      final pa = a['pinned'] == true ? 1 : 0, pb = b['pinned'] == true ? 1 : 0;
      if (pa != pb) return pb - pa;
      final da = at(a), db = at(b);
      if (da != null && db != null && da != db) return db.compareTo(da);
      if (da != null && db == null) return -1;
      if (da == null && db != null) return 1;
      return order[a]!.compareTo(order[b]!);
    });
    return rows;
  }

  /// 'home' for a home-chat thread, else 'ai'.
  static String source(Map<String, dynamic> r) =>
      r['source'] == 'home' ? 'home' : 'ai';

  /// Case-insensitive match on the title + snippet.
  static bool matches(Map<String, dynamic> r, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return '${r['title'] ?? ''} ${r['snippet'] ?? ''}'
        .toLowerCase()
        .contains(q);
  }

  /// Asks for a new title. Returns the trimmed name, or null when cancelled
  /// or empty.
  static Future<String?> askRename(BuildContext context, String current) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(initial: current),
    );
    final v = name?.trim() ?? '';
    return v.isEmpty ? null : v;
  }

  /// Delete confirmation. True only when the user confirmed.
  static Future<bool> confirmDelete(BuildContext context) async {
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
    return ok == true;
  }
}

/// Owns its controller so it is disposed with the dialog (after the exit
/// animation), never while the closing dialog still renders it.
class _RenameDialog extends StatefulWidget {
  final String initial;
  const _RenameDialog({required this.initial});
  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(t.aichatRename),
      content: TextField(
        key: const ValueKey('chat_rename_field'),
        controller: _ctrl,
        autofocus: true,
        maxLength: 120,
        decoration: InputDecoration(hintText: t.aichatRenameHint),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(t.aichatCancel)),
        FilledButton(
            onPressed: () => Navigator.pop(context, _ctrl.text),
            child: Text(t.aichatSave)),
      ],
    );
  }
}
