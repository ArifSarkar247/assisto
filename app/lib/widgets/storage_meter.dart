import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../state.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../services/error_kind.dart' show honestFailText; // qa2
import 'ladder_common.dart' show fmtInt;

/// STORAGE METER (Business Model Build 3, item 3).
///
/// A compact, always-visible "used of quota" meter, reused as a Settings row
/// and on the Credits screen. Reads `GET /storage/meter`
/// ({used, quota_bytes, pct, full}); callers that already have the storage
/// map from `me/usage-summary` can pass it via [initial] to skip the fetch.
///
/// HONESTY: the widget only SHOWS state — it never blocks anything (the backend
/// enforces the quota). When full it surfaces a "delete items or buy storage"
/// line with a buy-storage CTA; that CTA is honest — it routes to the Credits
/// screen's top-up (which itself says "payment setup pending" when no provider
/// is wired). All copy via [AppLocalizations]; sizes use Bangla digits.
class StorageMeter extends StatefulWidget {
  /// Pre-fetched {used, quota_bytes, pct, full} (e.g. from me/usage-summary).
  /// When null the widget fetches `storage/meter` itself.
  final Map<String, dynamic>? initial;

  /// Called when the user taps "buy storage" (full state). When null the CTA is
  /// hidden — use this from the Credits screen (where buying lives) and leave it
  /// as a navigator push from Settings.
  final VoidCallback? onBuyStorage;

  const StorageMeter({super.key, this.initial, this.onBuyStorage});

  @override
  State<StorageMeter> createState() => _StorageMeterState();
}

class _StorageMeterState extends State<StorageMeter> {
  Map<String, dynamic>? _m;
  bool _loading = false;
  bool _error = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

  @override
  void initState() {
    super.initState();
    _m = widget.initial;
    if (_m == null) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final m = await context.read<AppState>().api.storageMeter();
      if (!mounted) return;
      setState(() {
        _m = m;
        _loading = false;
      });
    } on ApiException {
      if (!mounted) return;
      setState(() {
        _error = true;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = true;
        _failCause = e;
        _loading = false;
      });
    }
  }

  int _int(dynamic v) => v is num ? v.toInt() : 0;

  /// Human size, locale-aware (Bangla digits). Shows one decimal for GB/MB.
  String _size(BuildContext context, int bytes) {
    final bn = Localizations.localeOf(context).languageCode == 'bn';
    const kb = 1024, mb = 1024 * 1024, gb = 1024 * 1024 * 1024;
    final t = AppLocalizations.of(context);
    if (bytes >= gb) {
      return t.storageUnitGb(_oneDecimal(context, bytes / gb, bn));
    }
    if (bytes >= mb) {
      return t.storageUnitMb(_oneDecimal(context, bytes / mb, bn));
    }
    if (bytes >= kb) {
      return t.storageUnitKb(fmtInt(context, (bytes / kb).round()));
    }
    return t.storageUnitBytes(fmtInt(context, bytes));
  }

  String _oneDecimal(BuildContext context, double v, bool bn) {
    // Whole number -> no decimal; else one place. Bangla digits via fmtInt for
    // both halves so there's no Latin leakage in bn.
    final rounded = (v * 10).round();
    final whole = rounded ~/ 10;
    final frac = rounded % 10;
    if (frac == 0) return fmtInt(context, whole);
    return '${fmtInt(context, whole)}.${fmtInt(context, frac)}';
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;

    if (_loading && _m == null) {
      return _shell(
        scheme,
        child: Row(children: [
          const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: Gap.md),
          Expanded( // billapp: wraps at 200% font
            child: Text(t.storageLoading,
                style: TextStyle(color: scheme.onSurfaceVariant)),
          ),
        ]),
      );
    }
    if (_error && _m == null) {
      return _shell(
        scheme,
        child: Row(children: [
          Icon(Icons.cloud_off_rounded, size: 20, color: scheme.onSurfaceVariant),
          const SizedBox(width: Gap.md),
          Expanded(
              child: Text(honestFailText(t, _failCause, otherwise: t.storageLoadError),
                  style: TextStyle(color: scheme.onSurfaceVariant))),
          TextButton(onPressed: _load, child: Text(t.retry)),
        ]),
      );
    }

    final m = _m ?? const {};
    final used = _int(m['used']);
    final quota = _int(m['quota_bytes']);
    final full = m['full'] == true || (quota > 0 && used >= quota);
    // Prefer server pct; else compute. Clamp 0..1 for the bar.
    double pct;
    final rawPct = m['pct'];
    if (rawPct is num) {
      pct = rawPct.toDouble();
      if (pct > 1) pct = pct / 100.0; // tolerate 0-100 OR 0-1 server shapes
    } else {
      pct = quota > 0 ? used / quota : 0;
    }
    pct = pct.clamp(0.0, 1.0);
    final nearFull = pct >= 0.85;
    final barColor =
        full ? Brand.danger : (nearFull ? Brand.warning : scheme.primary);

    final pctLabel = fmtInt(context, (pct * 100).round());

    return _shell(
      scheme,
      border: full ? Brand.danger.withValues(alpha: 0.5) : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(full ? Icons.sd_card_alert_rounded : Icons.cloud_rounded,
              size: 20, color: barColor),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(t.storageTitle,
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
          Text('$pctLabel%',
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: full ? Brand.danger : scheme.onSurfaceVariant)),
        ]),
        const SizedBox(height: Gap.sm),
        ClipRRect(
          borderRadius: BorderRadius.circular(Radii.pill),
          child: LinearProgressIndicator(
            value: pct,
            minHeight: 8,
            backgroundColor: scheme.surfaceContainerHighest,
            valueColor: AlwaysStoppedAnimation(barColor),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          t.storageUsedOf(_size(context, quota), _size(context, used)) /* (quota, used) */,
          style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 4),
        Text(
          full
              ? t.storageFullBody
              : (nearFull ? t.storageNearFullBody : t.storageCanStillBody),
          style: TextStyle(
              fontSize: 12,
              color: full ? Brand.danger : scheme.onSurfaceVariant,
              height: 1.35),
        ),
        if (full) ...[
          const SizedBox(height: Gap.sm),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () {
                  // Deleting items lives in the Documents/Vault — we point there
                  // without navigating (keeps this widget dependency-free); the
                  // honest message already tells the user to delete items.
                },
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                label: Text(t.storageDeleteItems),
                style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(42)),
              ),
            ),
            if (widget.onBuyStorage != null) ...[
              const SizedBox(width: Gap.sm),
              Expanded(
                child: FilledButton.icon(
                  onPressed: widget.onBuyStorage,
                  icon: const Icon(Icons.add_shopping_cart_rounded, size: 18),
                  label: Text(t.storageBuyMore),
                  style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(42)),
                ),
              ),
            ],
          ]),
        ],
      ]),
    );
  }

  Widget _shell(ColorScheme scheme, {required Widget child, Color? border}) =>
      Container(
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: border ?? scheme.outlineVariant),
        ),
        child: child,
      );
}
