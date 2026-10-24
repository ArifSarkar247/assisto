import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../feature_gates.dart' show kMedicalFeaturesAllowed;

/// A high-contrast, printable "emergency card" the user can show on a lock
/// screen or hand to a responder. Mirrors core.logic.safety.emergency_card_text
/// field order. Wrapped in a RepaintBoundary so it can be captured to an image
/// and shared, and it also knows how to build the same content as plain text.
///
/// Pure presentation — all data + the localised plain-text come from the caller
/// so the one source of truth for ordering stays in one place.
class EmergencyCardView extends StatelessWidget {
  final String? name;
  final String bloodGroup;
  final String allergies;
  final String conditions;
  final String medicines;
  final String doctor;
  final String insurance;
  final String nid;
  final bool organDonor;
  final List<Map<String, dynamic>> contacts;

  /// Key on the outer boundary so the parent can capture it to a PNG.
  final GlobalKey? boundaryKey;

  const EmergencyCardView({
    super.key,
    this.name,
    this.bloodGroup = '',
    this.allergies = '',
    this.conditions = '',
    this.medicines = '',
    this.doctor = '',
    this.insurance = '',
    this.nid = '',
    this.organDonor = false,
    this.contacts = const [],
    this.boundaryKey,
  });

  /// play-nomed: in the Play flavour the card carries NO medical record
  /// (blood group, allergies, conditions, medicines, doctor, insurance, organ
  /// donor) — only name, NID and emergency contacts.
  static bool get showMedical => kMedicalFeaturesAllowed;

  bool get _empty => showMedical ? _emptyAll : _emptyBasic;

  bool get _emptyBasic =>
      nid.trim().isEmpty &&
      contacts.where((c) => '${c['phone'] ?? ''}'.trim().isNotEmpty).isEmpty;

  bool get _emptyAll =>
      bloodGroup.trim().isEmpty &&
      allergies.trim().isEmpty &&
      conditions.trim().isEmpty &&
      medicines.trim().isEmpty &&
      doctor.trim().isEmpty &&
      insurance.trim().isEmpty &&
      nid.trim().isEmpty &&
      !organDonor &&
      contacts.where((c) => '${c['phone'] ?? ''}'.trim().isNotEmpty).isEmpty;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final med = showMedical;
    // High-contrast on purpose: a red banner + near-black text on white so it
    // is legible on a bright lock screen and when captured to an image.
    final card = Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: Brand.danger, width: 2),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          padding: const EdgeInsets.symmetric(
              horizontal: Gap.lg, vertical: Gap.md),
          decoration: const BoxDecoration(
            color: Brand.danger,
            borderRadius:
                BorderRadius.vertical(top: Radius.circular(Radii.sm)),
          ),
          child: Row(children: [
            Icon(med ? Icons.medical_services : Icons.emergency,
                color: Colors.white),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(t.emergencyCardBanner,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 18)),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: _empty
              ? Text(med ? t.emergencyCardEmptyHint : t.emergencyCardEmptyHintBasic,
                  style: const TextStyle(color: Colors.black54))
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if ((name ?? '').trim().isNotEmpty)
                      _row(t.name, name!),
                    if (med && bloodGroup.trim().isNotEmpty)
                      _row(t.emergencyBloodGroup, bloodGroup, big: true),
                    if (med && allergies.trim().isNotEmpty)
                      _row(t.emergencyAllergies, allergies),
                    if (med && conditions.trim().isNotEmpty)
                      _row(t.emergencyConditions, conditions),
                    if (med && medicines.trim().isNotEmpty)
                      _row(t.emergencyMedicines, medicines),
                    if (med && doctor.trim().isNotEmpty)
                      _row(t.emergencyDoctor, doctor),
                    if (med && insurance.trim().isNotEmpty)
                      _row(t.emergencyInsurance, insurance),
                    if (nid.trim().isNotEmpty) _row(t.emergencyNid, nid),
                    if (med && organDonor)
                      _row(t.emergencyOrganDonor, t.emergencyYes),
                    ..._contactRows(t),
                  ],
                ),
        ),
      ]),
    );
    if (boundaryKey == null) return card;
    return RepaintBoundary(
      key: boundaryKey,
      // White backdrop so transparency never captures as black.
      child: Container(color: Colors.white, child: card),
    );
  }

  List<Widget> _contactRows(AppLocalizations t) {
    final callable = contacts
        .where((c) => '${c['phone'] ?? ''}'.trim().isNotEmpty)
        .toList();
    if (callable.isEmpty) return const [];
    return [
      const SizedBox(height: Gap.sm),
      const Divider(color: Colors.black26, height: Gap.lg),
      Text(t.emergencyContactTitle,
          style: const TextStyle(
              color: Colors.black, fontWeight: FontWeight.w700)),
      const SizedBox(height: Gap.xs),
      for (final c in callable)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            _contactLine(c),
            style: const TextStyle(color: Colors.black87, fontSize: 15),
          ),
        ),
    ];
  }

  String _contactLine(Map<String, dynamic> c) {
    final nm = '${c['name'] ?? ''}'.trim();
    final rel = '${c['relation'] ?? ''}'.trim();
    final ph = '${c['phone'] ?? ''}'.trim();
    final who = nm + (rel.isNotEmpty && rel != nm ? ' ($rel)' : '');
    return who.isEmpty ? '• $ph' : '• $who — $ph';
  }

  Widget _row(String label, String value, {bool big = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: const TextStyle(
                color: Colors.black54,
                fontSize: 12,
                fontWeight: FontWeight.w600)),
        Text(value,
            style: TextStyle(
                color: Colors.black,
                fontSize: big ? 22 : 16,
                fontWeight: big ? FontWeight.w800 : FontWeight.w500)),
      ]),
    );
  }

  /// Capture a GlobalKey'd RepaintBoundary to a PNG file in the temp dir.
  /// Returns null if the boundary isn't painted yet. Caller shares the file.
  static Future<File?> captureToFile(GlobalKey key,
      {String fileName = 'emergency_card.png'}) async {
    final ctx = key.currentContext;
    if (ctx == null) return null;
    final obj = ctx.findRenderObject();
    if (obj is! RenderRepaintBoundary) return null;
    final ui.Image image = await obj.toImage(pixelRatio: 3.0);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) return null;
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/$fileName');
    await f.writeAsBytes(bytes.buffer.asUint8List());
    return f;
  }

  /// Share the captured card as an image (with a text caption fallback).
  static Future<bool> shareAsImage(GlobalKey key, String caption) async {
    final f = await captureToFile(key);
    if (f == null) return false;
    await Share.shareXFiles([XFile(f.path)], text: caption);
    return true;
  }

  static Future<void> shareAsText(String text) => Share.share(text);
}
