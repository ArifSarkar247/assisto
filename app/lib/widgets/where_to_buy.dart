import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';

/// chipbuy (owner 2 Nov): "Where to buy" — a plain OUTBOUND link to
/// asalifymart.com, shown where a user is about to set up a device (CCTV
/// camera, vehicle tracker, kids watch, tracker chip).
///
/// EXTERNAL LINK ONLY: the app never calls, embeds, fetches or talks to any
/// Asalify system. Tapping opens the phone's browser with one plain
/// `utm_source=assisto` and nothing else (no user id, no device, no product).
const String kWhereToBuyUrl = 'https://asalifymart.com/?utm_source=assisto';

/// The products this link is shown for.
enum BuyProduct { cctv, vehicle, kidsWatch, chip }

/// Test seam: how the link is opened (always an external browser app).
typedef BuyLauncher = Future<bool> Function(Uri uri, LaunchMode mode);

Future<bool> _defaultLaunch(Uri uri, LaunchMode mode) => launchUrl(uri, mode: mode);

class WhereToBuyLink extends StatelessWidget {
  const WhereToBuyLink({super.key, required this.product, this.dense = false});

  final BuyProduct product;

  /// true inside a form / sheet (no card, less padding).
  final bool dense;

  /// Overridden in tests only.
  static BuyLauncher launcher = _defaultLaunch;

  static Uri get uri => Uri.parse(kWhereToBuyUrl);

  String _title(AppLocalizations t) => switch (product) {
        BuyProduct.cctv => t.buyCctvTitle,
        BuyProduct.vehicle => t.buyVehicleTitle,
        BuyProduct.kidsWatch => t.buyKidsWatchTitle,
        BuyProduct.chip => t.buyChipTitle,
      };

  Future<void> _open(BuildContext context) async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    var ok = false;
    try {
      ok = await launcher(uri, LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
    if (!ok) {
      messenger
        ?..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(t.buyOpenFailed)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final tile = Semantics(
      link: true,
      button: true,
      label: '${_title(t)}. ${t.buySub}',
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('where-to-buy-${product.name}'),
        borderRadius: BorderRadius.circular(12),
        onTap: () => _open(context),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: EdgeInsets.symmetric(
                horizontal: dense ? Gap.xs : Gap.md, vertical: Gap.sm),
            child: Row(children: [
              Icon(Icons.storefront_rounded, color: scheme.primary),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_title(t),
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(color: scheme.primary, fontWeight: FontWeight.w600)),
                  Text(t.buySub,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant)),
                ]),
              ),
              const SizedBox(width: Gap.xs),
              Icon(Icons.open_in_new_rounded, size: 20, color: scheme.onSurfaceVariant),
            ]),
          ),
        ),
      ),
    );
    if (dense) return tile;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: Gap.sm),
      color: scheme.surfaceContainerLow,
      child: tile,
    );
  }
}
