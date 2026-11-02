import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// lifebar: one honest "Delete this?" step before an item disappears.
/// [what] is the item's own name (shown as the dialog body when not empty).
Future<bool> confirmDelete(BuildContext context, {String what = ''}) async {
  final t = AppLocalizations.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(t.lifebarDeleteConfirm),
      content: what.trim().isEmpty ? null : Text(what.trim()),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t.cancel)),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(t.delete)),
      ],
    ),
  );
  return ok == true;
}
