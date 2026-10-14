import 'package:flutter/material.dart';
import 'business/business_hub_screen.dart';

/// Assisto Business v2 entry point.
///
/// The old name/price/stock catalog screen has been REPLACED by the Business
/// HUB (see business/business_hub_screen.dart). This wrapper keeps the existing
/// `BusinessScreen` route (chatnav / sidebar / drawer reference it by name) and
/// simply mounts the hub, which handles setup → khata → selling → cashbox →
/// reports → AI assistant for one (or several) businesses.
class BusinessScreen extends StatelessWidget {
  const BusinessScreen({super.key});
  @override
  Widget build(BuildContext context) => const BusinessHubScreen();
}
