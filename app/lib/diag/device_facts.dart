import 'dart:async';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

/// sc1 — the phone facts a crash report needs to find "which phones break":
/// brand, model, Android version/SDK and the maker's ROM. No identifiers (no
/// Android ID, serial, IMEI, account): only what is the same for every unit
/// of that model.
class DeviceFacts {
  const DeviceFacts({
    this.brand = '',
    this.manufacturer = '',
    this.model = '',
    this.android = '',
    this.sdk = 0,
    this.rom = '',
    this.display = '',
  });

  final String brand;
  final String manufacturer;
  final String model;
  final String android;
  final int sdk;
  final String rom;

  /// Build.DISPLAY (ROM build label, e.g. "RMX3491_14.0.0.700(EX01)").
  final String display;

  Map<String, dynamic> toJson() => {
        'brand': brand,
        'manufacturer': manufacturer,
        'model': model,
        'android': android,
        'sdk': sdk,
        'rom': rom,
        'display': display,
      };

  static DeviceFacts? _cached;

  /// Read once (lazily, after the first frame), time-boxed, never throws.
  static Future<DeviceFacts> read() async {
    final c = _cached;
    if (c != null) return c;
    try {
      if (defaultTargetPlatform != TargetPlatform.android || kIsWeb) {
        return _cached = DeviceFacts(brand: defaultTargetPlatform.name);
      }
      final a = await DeviceInfoPlugin()
          .androidInfo
          .timeout(const Duration(seconds: 3));
      return _cached = DeviceFacts(
        brand: _cap(a.brand, 40),
        manufacturer: _cap(a.manufacturer, 40),
        model: _cap(a.model, 60),
        android: _cap(a.version.release, 16),
        sdk: a.version.sdkInt,
        display: _cap(a.display, 64),
        rom: romFrom(
            brand: a.brand,
            manufacturer: a.manufacturer,
            display: a.display,
            fingerprint: a.fingerprint,
            incremental: a.version.incremental,
            sdk: a.version.sdkInt),
      );
    } catch (_) {
      return const DeviceFacts();
    }
  }

  static String _cap(String s, int n) =>
      s.length > n ? s.substring(0, n) : s;
}

/// Best-effort ROM name from public Build fields (no system-property reads,
/// no extra permission). Returns '' when unknown.
///   OPPO / realme / OnePlus(13+) → ColorOS (realme UI is ColorOS-based)
///   Xiaomi / Redmi / POCO → HyperOS ("OS1."/"OS2." build labels) else MIUI
///   Samsung → One UI · vivo / iQOO → Funtouch OS (OriginOS when labelled)
///   Infinix → XOS · Tecno → HiOS · itel → itel OS · Huawei/Honor → EMUI/MagicOS
///   Walton / Symphony / Google / Nokia / Motorola → near-stock "Android"
String romFrom({
  required String brand,
  String manufacturer = '',
  String display = '',
  String fingerprint = '',
  String incremental = '',
  int sdk = 0,
}) {
  final b = '${brand.toLowerCase()} ${manufacturer.toLowerCase()}';
  final d = '$display $fingerprint $incremental'.toLowerCase();
  if (d.contains('coloros')) return 'ColorOS';
  if (d.contains('hyperos')) return 'HyperOS';
  if (d.contains('miui')) return 'MIUI';
  if (d.contains('originos')) return 'OriginOS';
  if (d.contains('funtouch')) return 'Funtouch OS';
  if (d.contains('oneui') || d.contains('one ui')) return 'One UI';
  if (b.contains('oppo') || b.contains('realme')) return 'ColorOS';
  if (b.contains('oneplus')) return sdk >= 33 ? 'ColorOS' : 'OxygenOS';
  if (b.contains('xiaomi') || b.contains('redmi') || b.contains('poco')) {
    // HyperOS builds are labelled "OS1.x.y" / "OS2.x.y"; MIUI "V14.x" etc.
    return RegExp(r'\bos\d\.').hasMatch(d) ? 'HyperOS' : 'MIUI';
  }
  if (b.contains('samsung')) return 'One UI';
  if (b.contains('vivo') || b.contains('iqoo')) return 'Funtouch OS';
  if (b.contains('infinix')) return 'XOS';
  if (b.contains('tecno')) return 'HiOS';
  if (b.contains('itel')) return 'itel OS';
  if (b.contains('honor')) return 'MagicOS';
  if (b.contains('huawei')) return 'EMUI';
  for (final s in const ['walton', 'symphony', 'google', 'nokia', 'motorola']) {
    if (b.contains(s)) return 'Android';
  }
  return '';
}
