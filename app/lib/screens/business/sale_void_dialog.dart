import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../l10n/app_localizations.dart';
import '../../shop_api.dart';
import '../../state.dart';
import '../../theme.dart';

/// VOID a sale (a2-cctv). Owner any time; staff only for today's sale (the
/// server enforces it). A reason is required. Stock is restored where the
/// variant was recorded; the server says honestly when it could not be.
/// Voided sales stay in history as VOID and drop out of every report.
Future<bool> showSaleVoidDialog(BuildContext context, int saleId) async {
  final t = AppLocalizations.of(context);
  final text = await showDialog<String>(
    context: context,
    builder: (_) => const SaleVoidDialog(),
  );
  if (text == null || !context.mounted) return false;
  final messenger = ScaffoldMessenger.of(context);
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

/// The reason dialog. Pops the trimmed reason, or nothing on cancel. The
/// confirm button stays disabled until a reason is written (no empty voids,
/// and no "reason needed" error after the fact).
class SaleVoidDialog extends StatefulWidget {
  const SaleVoidDialog({super.key});
  @override
  State<SaleVoidDialog> createState() => _SaleVoidDialogState();
}

class _SaleVoidDialogState extends State<SaleVoidDialog> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final ok = _reason.text.trim().length >= 2;
    return AlertDialog(
      icon: Icon(Icons.block_rounded, color: scheme.error),
      title: Text(t.shopVoidTitle),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(t.shopVoidBody, style: const TextStyle(height: 1.4)),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _reason,
            autofocus: true,
            maxLength: 200,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
                labelText: t.shopVoidReason,
                helperText: t.shopVoidReasonNeeded,
                helperMaxLines: 2,
                border: const OutlineInputBorder()),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(t.cancel)),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: scheme.error, foregroundColor: scheme.onError),
          onPressed: ok ? () => Navigator.pop(context, _reason.text.trim()) : null,
          child: Text(t.shopVoidConfirm),
        ),
      ],
    );
  }
}
