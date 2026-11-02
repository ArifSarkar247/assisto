import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../state.dart';
import '../../business_khata_api.dart';
import '../../widgets/skeleton.dart';
import '../../services/error_kind.dart' show FailKind, failKindOf, honestFailText;
import '../business_screen.dart';
import 'khata_screen.dart';
import 'dart:async' show unawaited;
import 'business_common.dart' show pickBusiness, rememberedBusinessId;
import '../../services/khata_offline.dart';

/// home_v2: the "Digital Ledger" shortcut (ChatNav route `khata`). Opens the
/// selected business's Digital Khata directly; with no business yet it opens
/// the Business hub, which walks the owner through setup first (the khata
/// needs a business). Offline / server trouble -> an honest error + retry.
class KhataEntryScreen extends StatefulWidget {
  const KhataEntryScreen({super.key});
  @override
  State<KhataEntryScreen> createState() => _KhataEntryScreenState();
}

class _KhataEntryScreenState extends State<KhataEntryScreen> {
  bool _error = false;
  Object? _cause;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  Future<void> _open() async {
    if (!mounted) return;
    setState(() => _error = false);
    try {
      Map<String, dynamic> r;
      try {
        r = await context
            .read<AppState>()
            .api
            .businessList()
            .timeout(KhataOffline.requestTimeout);
        unawaited(KhataOffline.cachePut(KhataOffline.businessesKey, r));
      } catch (e) {
        // bizbar: no internet -> open the khata from the saved list (the
        // khata itself works offline; this shortcut used to stop at an error)
        final saved = failKindOf(e) == FailKind.refused
            ? null
            : await KhataOffline.cacheGet(KhataOffline.businessesKey);
        if (saved == null) rethrow;
        r = saved.value;
      }
      final list = ((r['businesses'] ?? []) as List).cast<Map<String, dynamic>>();
      final sel = pickBusiness(list, r['selected_id'], await rememberedBusinessId());
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) => sel == null
              ? const BusinessScreen()
              : KhataScreen(business: sel),
          settings: const RouteSettings(name: 'khata')));
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = true;
          _cause = e;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
          title: Text(t.khataTitle,
              maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: _error
          ? StateMessage(
              icon: Icons.cloud_off_rounded,
              tint: scheme.error,
              title: t.loadFailed,
              message: honestFailText(t, _cause),
              action: FilledButton.tonalIcon(
                  onPressed: _open,
                  icon: const Icon(Icons.refresh_rounded),
                  label: Text(t.retry)),
            )
          : const SkeletonList(),
    );
  }
}
