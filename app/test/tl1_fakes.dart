// tl1: fakes for the OEM background guide (tests + gallery).
import 'package:assisto/services/oem_guide.dart';

class FakeOemNative implements OemGuideNative {
  FakeOemNative(this.infoValue, {Map<String, OemOpen>? avail, this.openResult})
      : avail = avail ?? const {};
  OemInfo? infoValue;
  final Map<String, OemOpen> avail;
  final OemOpen? openResult;
  final List<String> opened = [];
  int infoCalls = 0;

  @override
  Future<OemInfo?> info() async {
    infoCalls++;
    return infoValue;
  }

  @override
  Future<OemOpen> available(String step) async => avail[step] ?? OemOpen.none;

  @override
  Future<OemOpen> open(String step) async {
    opened.add(step);
    return openResult ?? avail[step] ?? OemOpen.none;
  }
}

/// Realistic phones from the owner's list (Bangladesh market).
OemInfo tl1Phone(String which, {bool? ignored = false, bool? restricted = false}) =>
    switch (which) {
      'oppo' => OemInfo(manufacturer: 'OPPO', brand: 'OPPO', model: 'CPH2637',
          sdkInt: 34, release: '14', rom: 'ColorOS V14.0',
          batteryOptIgnored: ignored, bgRestricted: restricted),
      'realme' => OemInfo(manufacturer: 'realme', brand: 'realme', model: 'RMX3491',
          sdkInt: 33, release: '13', rom: 'realme UI V4.0',
          batteryOptIgnored: ignored, bgRestricted: restricted),
      'xiaomi' => OemInfo(manufacturer: 'Xiaomi', brand: 'Redmi', model: '23053RN02I',
          sdkInt: 34, release: '14', rom: 'HyperOS OS1.0.5',
          batteryOptIgnored: ignored, bgRestricted: restricted),
      'samsung' => OemInfo(manufacturer: 'samsung', brand: 'samsung', model: 'SM-A155F',
          sdkInt: 34, release: '14', rom: 'One UI 6.1',
          batteryOptIgnored: ignored, bgRestricted: restricted),
      'vivo' => OemInfo(manufacturer: 'vivo', brand: 'vivo', model: 'V2318',
          sdkInt: 34, release: '14', rom: 'Funtouch/OriginOS 14.0',
          batteryOptIgnored: ignored, bgRestricted: restricted),
      'walton' => OemInfo(manufacturer: 'WALTON', brand: 'Walton', model: 'Primo H10',
          sdkInt: 30, release: '11', batteryOptIgnored: ignored, bgRestricted: restricted),
      _ => OemInfo(manufacturer: 'INFINIX', brand: 'Infinix', model: 'X6833B',
          sdkInt: 33, release: '13', rom: 'XOS/HiOS 13.0',
          batteryOptIgnored: ignored, bgRestricted: restricted),
    };

/// Typical resolve results: vendor screen for autostart on OPPO/Xiaomi/vivo,
/// App-info fallback for the battery page, the standard list everywhere.
Map<String, OemOpen> tl1Avail(String which) => switch (which) {
      'samsung' => const {
          'battery_opt': OemOpen.oem,
          'app_details': OemOpen.details,
          'oem_battery': OemOpen.oem,
          'autostart': OemOpen.details,
        },
      'walton' => const {'battery_opt': OemOpen.oem, 'app_details': OemOpen.details},
      _ => const {
          'battery_opt': OemOpen.oem,
          'app_details': OemOpen.details,
          'autostart': OemOpen.oem,
          'oem_battery': OemOpen.details,
        },
    };
