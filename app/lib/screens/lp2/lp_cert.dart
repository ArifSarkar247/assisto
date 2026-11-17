/// gap-lp — the Assisto Practice Certificate button (part H). Kept in its own
/// file: no ad API here (lp2_ads_test checks every lp2 file that names the
/// certificate). The server offers it only for a FULL mock whose four bands
/// it gave itself; the PDF says "practice score, not an official result".
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../services/error_kind.dart' show honestFailText;
import '../../state.dart';
import '../../theme.dart';
import 'lp_ui.dart';

/// The button for a /finish answer, or null when no certificate is offered.
Widget? lpCertFor(Map<String, dynamic> finish) =>
    finish['result_id'] is num && '${finish['certificate_url'] ?? ''}'.isNotEmpty
        ? LpCertButton(resultId: (finish['result_id'] as num).toInt())
        : null;

class LpCertButton extends StatefulWidget {
  final int resultId;
  const LpCertButton({super.key, required this.resultId});
  @override
  State<LpCertButton> createState() => _LpCertButtonState();
}

class _LpCertButtonState extends State<LpCertButton> {
  bool _busy = false;

  Future<void> _open() async {
    final tr = AppLocalizations.of(context);
    final api = context.read<AppState>().api;
    setState(() => _busy = true);
    try {
      final bytes = await api.getBytes('/lp/certificate/${widget.resultId}');
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/assisto-practice-certificate-${widget.resultId}.pdf');
      await f.writeAsBytes(bytes);
      await OpenFilex.open(f.path);
    } catch (e) {
      if (mounted) lpToast(context, honestFailText(tr, e, otherwise: tr.lp2gCertFail));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    return OutlinedButton.icon(
      key: const Key('lp2-cert'),
      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(kMinTap)),
      onPressed: _busy ? null : _open,
      icon: _busy
          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.workspace_premium_rounded),
      label: Text(tr.lp2gCert),
    );
  }
}

