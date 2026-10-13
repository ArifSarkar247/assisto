import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import '../widgets/life_provider_tile.dart';

/// Ride & food (module-5 "Life"). We DEEP-LINK each provider's own app with the
/// trip/order pre-filled where their URL scheme allows — we NEVER show fake
/// prices or availability, and in-app booking is key-gated/partner (shown as a
/// clearly-marked "coming" chip).
///
/// Ride: Uber (universal link with pickup/drop), Pathao (app/site).
/// Food: foodpanda (search/app link).
///
/// If a provider app isn't installed, the https universal link opens its site
/// in the browser (graceful fallback).
class RideFoodScreen extends StatefulWidget {
  const RideFoodScreen({super.key});
  @override
  State<RideFoodScreen> createState() => _RideFoodScreenState();
}

class _RideFoodScreenState extends State<RideFoodScreen> {
  final _drop = TextEditingController();

  @override
  void dispose() {
    _drop.dispose();
    super.dispose();
  }

  Future<void> _open(String url) async {
    final uri = Uri.parse(url);
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {}
  }

  // --- deep links (provider's own; drop-off prefilled when supported) ---
  String _uberUrl() {
    final drop = _drop.text.trim();
    // Uber universal link; action=setPickup, drop prefilled as a free-text nickname.
    final base = 'https://m.uber.com/ul/?action=setPickup&pickup=my_location';
    if (drop.isEmpty) return base;
    return '$base&dropoff[nickname]=${Uri.encodeComponent(drop)}';
  }

  String _pathaoUrl() => 'https://pathao.com/';

  String _foodpandaUrl() {
    final q = _drop.text.trim(); // reuse the field as a food search when on food
    if (q.isEmpty) return 'https://www.foodpanda.com.bd/';
    return 'https://www.foodpanda.com.bd/restaurants?q=${Uri.encodeComponent(q)}';
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.rideFoodTitle)),
      body: ListView(
        padding: const EdgeInsets.all(Gap.md),
        children: [
          Container(
            padding: const EdgeInsets.all(Gap.md),
            decoration: BoxDecoration(
              color: Brand.blue.withOpacity(0.07),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(children: [
              const Icon(Icons.open_in_new, size: 18, color: Brand.blue),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(t.rideFoodDeepLinkNote,
                    style: const TextStyle(fontSize: 12, color: Brand.blue)),
              ),
            ]),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _drop,
            decoration: InputDecoration(
              labelText: t.rideFoodDestLabel,
              helperText: t.rideFoodDestHelper,
              prefixIcon: const Icon(Icons.place_outlined),
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: Gap.lg),

          // ---- Ride ----
          _sectionHeader(context, Icons.local_taxi_outlined, t.rideFoodRideSection),
          LifeProviderTile(
            icon: Icons.directions_car_filled_outlined,
            name: 'Uber',
            subtitle: t.rideFoodOpenInApp,
            onOpen: () => _open(_uberUrl()),
          ),
          LifeProviderTile(
            icon: Icons.two_wheeler_outlined,
            name: 'Pathao',
            subtitle: t.rideFoodOpenInApp,
            onOpen: () => _open(_pathaoUrl()),
          ),
          const SizedBox(height: Gap.lg),

          // ---- Food ----
          _sectionHeader(context, Icons.fastfood_outlined, t.rideFoodFoodSection),
          LifeProviderTile(
            icon: Icons.delivery_dining_outlined,
            name: 'foodpanda',
            subtitle: t.rideFoodOpenInApp,
            onOpen: () => _open(_foodpandaUrl()),
          ),
          const SizedBox(height: Gap.lg),

          // ---- in-app booking (key-gated) ----
          Container(
            padding: const EdgeInsets.all(Gap.md),
            decoration: BoxDecoration(
              color: Colors.grey.withOpacity(0.10),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(children: [
              const Icon(Icons.hourglass_empty, size: 18, color: Colors.grey),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(t.rideFoodInAppComing,
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, IconData icon, String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: Row(children: [
        Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: Gap.sm),
        Text(label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
      ]),
    );
  }
}
