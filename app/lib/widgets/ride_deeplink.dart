import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Ride & food provider catalog + deep-link builders (SPEC v2.1 §21, ADVANCED).
///
/// HONEST BY DESIGN:
///  • We only ever OPEN the provider's own app (or its website as a graceful
///    fallback). Assisto does NOT book, confirm, or take payment.
///  • We NEVER invent a fare. Any fare note is the provider's own estimate,
///    shown only after their app opens — we mark ours as "approx / in their app".
///  • "Installed?" detection is BEST-EFFORT via [canLaunchUrl] on the provider's
///    custom URL scheme. On some Android versions this is blocked, so an
///    unknown result is treated as "not sure" — we still offer the open, which
///    falls back to the https universal link (their site in a browser).
enum RideFoodKind { ride, food }

class RideProvider {
  final String id;
  final String name;
  final IconData icon;
  final RideFoodKind kind;

  /// Custom scheme URI we probe for install detection (e.g. "uber://").
  /// Null when the provider has no usable scheme (detection = unknown).
  final String? probeScheme;

  const RideProvider({
    required this.id,
    required this.name,
    required this.icon,
    required this.kind,
    this.probeScheme,
  });
}

/// Best-effort install state. [unknown] when the platform won't tell us.
enum InstallState { installed, notInstalled, unknown }

class RideDeepLink {
  const RideDeepLink._();

  // ---- catalog -----------------------------------------------------------
  static const rideProviders = <RideProvider>[
    RideProvider(
      id: 'uber',
      name: 'Uber',
      icon: Icons.directions_car_filled_outlined,
      kind: RideFoodKind.ride,
      probeScheme: 'uber://',
    ),
    RideProvider(
      id: 'pathao',
      name: 'Pathao',
      icon: Icons.two_wheeler_outlined,
      kind: RideFoodKind.ride,
      probeScheme: 'pathao://',
    ),
  ];

  static const foodProviders = <RideProvider>[
    RideProvider(
      id: 'foodpanda',
      name: 'foodpanda',
      icon: Icons.delivery_dining_outlined,
      kind: RideFoodKind.food,
      probeScheme: 'foodpanda://',
    ),
    RideProvider(
      id: 'pathao_food',
      name: 'Pathao Food',
      icon: Icons.fastfood_outlined,
      kind: RideFoodKind.food,
      probeScheme: 'pathao://',
    ),
  ];

  // ---- install detection (best-effort, never throws) ---------------------
  static Future<InstallState> installState(RideProvider p) async {
    final scheme = p.probeScheme;
    if (scheme == null) return InstallState.unknown;
    try {
      final can = await canLaunchUrl(Uri.parse(scheme));
      return can ? InstallState.installed : InstallState.notInstalled;
    } catch (_) {
      return InstallState.unknown;
    }
  }

  // ---- URL builders ------------------------------------------------------
  // Each returns an https UNIVERSAL link: opens the app if installed, else the
  // provider's site in a browser. Drop/search is prefilled where supported.

  static String urlFor(RideProvider p, {String pickup = '', String drop = ''}) {
    switch (p.id) {
      case 'uber':
        return _uber(drop);
      case 'pathao':
        return _pathao();
      case 'foodpanda':
        return _foodpanda(drop);
      case 'pathao_food':
        return _pathaoFood(drop);
      default:
        return 'https://www.google.com/search?q=${Uri.encodeComponent(p.name)}';
    }
  }

  static String _uber(String drop) {
    // Uber universal link; pickup=my_location lets their app use GPS.
    const base = 'https://m.uber.com/ul/?action=setPickup&pickup=my_location';
    if (drop.trim().isEmpty) return base;
    return '$base&dropoff[nickname]=${Uri.encodeComponent(drop.trim())}';
  }

  static String _pathao() => 'https://pathao.com/';

  static String _foodpanda(String q) {
    if (q.trim().isEmpty) return 'https://www.foodpanda.com.bd/';
    return 'https://www.foodpanda.com.bd/restaurants?q='
        '${Uri.encodeComponent(q.trim())}';
  }

  static String _pathaoFood(String q) {
    if (q.trim().isEmpty) return 'https://pathao.com/bangladesh/food/';
    return 'https://pathao.com/bangladesh/food/?q=${Uri.encodeComponent(q.trim())}';
  }

  /// Launch a url externally. Returns true if a launch was handed off.
  static Future<bool> open(String url) async {
    final uri = Uri.parse(url);
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }
}
