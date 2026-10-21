import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../shop_api.dart';
import '../../state.dart';

/// VOID a sale (a2-cctv). Owner any time; staff only for today's sale (the
/// server enforces it). A reason is required. Stock is restored where the
/// variant was recorded; the server says honestly when it could not be.
/// Voided sales stay in history as VOID and drop out of every report.
Future<bool> showSaleVoidDialog(BuildContext context, int saleId) async {
  final t = AppLocalizations.of(context);
  final reason = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(t.shopVoidTitle),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(t.shopVoidBody, style: const TextStyle(height: 1.4)),
        const SizedBox(height: 12),
        TextField(
          controller: reason,
          autofocus: true,
          maxLength: 200,
          decoration: InputDecoration(
              labelText: t.shopVoidReason, border: const OutlineInputBorder()),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(t.shopVoidConfirm),
        ),
      ],
    ),
  );
  final text = reason.text.trim();
  reason.dispose();
  if (ok != true || !context.mounted) return false;
  final messenger = ScaffoldMessenger.of(context);
  if (text.length < 2) {
    messenger.showSnackBar(SnackBar(content: Text(t.shopVoidReasonNeeded)));
    return false;
  }
  try {
    final r = await context.read<AppState>().api.shopVoidSale(saleId, text);
    final note = (r['note'] ?? '').toString();
    messenger.showSnackBar(SnackBar(
        content: Text(note.isEmpty ? t.shopVoidDone : '${t.shopVoidDone} $note')));
    return true;
  } on ApiException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
  } catch (_) {
    messenger.showSnackBar(SnackBar(content: Text(t.shopVoidFailed)));
  }
  return false;
}
