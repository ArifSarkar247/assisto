import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';

/// chipbuy / chipbuy2 (owner 2-3 Nov): "Buy — our own shop asalifymart".
/// A plain OUTBOUND link shown where a user is about to set up a device
/// (CCTV camera, vehicle tracker, kids watch, tracker chip).
///
/// * The links come ONLY from the owner's list (Owner Admin -> Buy links,
///   GET /app/buy-links). Nothing about a product or a price is in the app;
///   no list / no network = no link (never a dead button).
/// * Defence in depth: only https links on the owner's shop host are opened.
/// * The app never calls, embeds or fetches the shop; tapping opens the
///   phone's browser.
/// * Placement: set-up screens only — never SOS, alerts, live location,
///   permission, payment or login screens (it is our shop, but the no-ads
///   rule still applies there).
const Set<String> kOwnShopHosts = {'asalifymart.com', 'www.asalifymart.com'};

/// The products this link is shown for.
enum BuyProduct { cctv, vehicle, kidsWatch, chip }

String buyCategory(BuyProduct p) => switch (p) {
      BuyProduct.cctv => 'cctv',
      BuyProduct.vehicle => 'vehicle',
      BuyProduct.kidsWatch => 'kids_watch',
      BuyProduct.chip => 'chip',
    };

/// Test seam: how the link is opened (always an external browser app).
typedef BuyLauncher = Future<bool> Function(Uri uri, LaunchMode mode);

Future<bool> _defaultLaunch(Uri uri, LaunchMode mode) => launchUrl(uri, mode: mode);

bool isOwnShopUrl(String raw) {
  final u = Uri.tryParse(raw);
  return u != null &&
      u.scheme == 'https' &&
      kOwnShopHosts.contains(u.host.toLowerCase()) &&
      u.userInfo.isEmpty;
}

/// The owner's buy-link list, fetched once per app session (a failed fetch is
/// retried by the next screen that needs it).
class BuyLinks {
  static Future<List<Map<String, dynamic>>>? _all;

  static void reset() => _all = null;

  static Future<List<Map<String, dynamic>>> load(ApiClient api) => _all ??= _fetch(api);

  static Future<List<Map<String, dynamic>>> _fetch(ApiClient api) async {
    try {
      final r = await api.getJson('/app/buy-links');
      final items = (r['items'] is List ? r['items'] as List : const [])
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .where((m) => isOwnShopUrl('${m['url'] ?? ''}'))
          .toList();
      return items;
    } catch (_) {
      _all = null;
      return const [];
    }
  }

  static List<Map<String, dynamic>> forProduct(
          List<Map<String, dynamic>> all, BuyProduct p) =>
      all.where((m) => m['category'] == buyCategory(p)).take(3).toList();
}

class WhereToBuyLink extends StatefulWidget {
  const WhereToBuyLink({super.key, required this.product, this.dense = false});

  final BuyProduct product;

  /// true inside a form / sheet (no card, less padding).
  final bool dense;

  /// Overridden in tests only.
  static BuyLauncher launcher = _defaultLaunch;

  @override
  State<WhereToBuyLink> createState() => _WhereToBuyLinkState();
}

class _WhereToBuyLinkState extends State<WhereToBuyLink> {
  List<Map<String, dynamic>> _items = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    ApiClient? api;
    try {
      api = context.read<AppState>().api;
    } catch (_) {
      api = null;
    }
    if (api == null) return;
    final all = await BuyLinks.load(api);
    if (!mounted) return;
    setState(() => _items = BuyLinks.forProduct(all, widget.product));
  }

  String _fallbackTitle(AppLocalizations t) => switch (widget.product) {
        BuyProduct.cctv => t.buyCctvTitle,
        BuyProduct.vehicle => t.buyVehicleTitle,
        BuyProduct.kidsWatch => t.buyKidsWatchTitle,
        BuyProduct.chip => t.buyChipTitle,
      };

  Future<void> _open(String url) async {
    final t = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    var ok = false;
    try {
      ok = isOwnShopUrl(url) &&
          await WhereToBuyLink.launcher(Uri.parse(url), LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
    if (!ok) {
      messenger
        ?..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(t.buyOpenFailed)));
    }
  }

  Widget _tile(BuildContext context, Map<String, dynamic> item, int i) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final bn = Localizations.localeOf(context).languageCode == 'bn';
    final own = '${(bn ? item['title_bn'] : item['title_en']) ?? ''}'.trim();
    final title = own.isNotEmpty ? own : _fallbackTitle(t);
    final url = '${item['url']}';
    final name = widget.product.name;
    return Semantics(
      link: true,
      button: true,
      label: '${t.buyNow}: $title. ${t.buyOwnShopSub}',
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey(i == 0 ? 'where-to-buy-$name' : 'where-to-buy-$name-$i'),
        borderRadius: BorderRadius.circular(12),
        onTap: () => _open(url),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: EdgeInsets.symmetric(
                horizontal: widget.dense ? Gap.xs : Gap.md, vertical: Gap.sm),
            child: Row(children: [
              Icon(Icons.storefront_rounded, color: scheme.primary),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title,
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(color: scheme.primary, fontWeight: FontWeight.w600)),
                  Text(t.buyOwnShopSub,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant)),
                ]),
              ),
              const SizedBox(width: Gap.xs),
              Flexible(
                flex: 0,
                child: Text(t.buyNow,
                    style: Theme.of(context)
                        .textTheme
                        .labelLarge
                        ?.copyWith(color: scheme.primary, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: Gap.xxs),
              Icon(Icons.open_in_new_rounded, size: 20, color: scheme.onSurfaceVariant),
            ]),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final tiles = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [for (var i = 0; i < _items.length; i++) _tile(context, _items[i], i)],
    );
    if (widget.dense) return tiles;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: Gap.sm),
      color: scheme.surfaceContainerLow,
      child: tiles,
    );
  }
}
