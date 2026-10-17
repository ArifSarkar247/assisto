import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../state.dart';
import '../widgets/vault_doc_types.dart';

/// Best-effort IMEI prefill from the Documents vault.
///
/// IMEI lives in a vault Document of `doc_type == 'device'`, in its structured
/// `details` map under `imei1` (falling back to `imei2`). Android 10+ forbids
/// apps from reading the IMEI, so there is NO native read — we only reuse what
/// the user already typed into their saved device record. Returns null on any
/// error or when no device record exists; callers then fall back to manual
/// entry. Never throws.
class RegistryImei {
  RegistryImei._();

  static Future<String?> fromVault(BuildContext context) async {
    try {
      final api = context.read<AppState>().api;
      final docs = await api.listDocuments();
      for (final d in docs) {
        if ('${d['doc_type']}' != 'device') continue;
        final parsed = readDocDetails(d);
        final imei1 = parsed.details['imei1']?.trim() ?? '';
        if (imei1.isNotEmpty) return imei1;
        final imei2 = parsed.details['imei2']?.trim() ?? '';
        if (imei2.isNotEmpty) return imei2;
      }
    } catch (_) {
      // best-effort only — fall back to manual entry
    }
    return null;
  }
}
