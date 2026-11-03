// nearby (owner 3 Nov 18:50): which country is the phone in? Read from the
// SIM / mobile network (Android TelephonyManager — no permission, no
// network call) through the existing device_admin channel; crash-guarded:
// any failure (old phone, no SIM, iOS, tests) -> nulls, and the caller falls
// back to our own data (nearest listed place) — never paid geocoding.
import 'package:flutter/services.dart';

class PhoneCountry {
  final String? network; // where the phone is now
  final String? sim; // the SIM's home country
  const PhoneCountry({this.network, this.sim});

  static const _ch = MethodChannel('com.assisto/device_admin');

  static Future<PhoneCountry> read() async {
    try {
      final m = await _ch
          .invokeMethod<dynamic>('phoneCountry')
          .timeout(const Duration(seconds: 2));
      if (m is Map) {
        String? s(Object? v) {
          final x = '${v ?? ''}'.trim().toUpperCase();
          return x.length == 2 ? x : null;
        }

        return PhoneCountry(network: s(m['network']), sim: s(m['sim']));
      }
    } catch (_) {
      // no channel / no telephony: unknown
    }
    return const PhoneCountry();
  }
}
