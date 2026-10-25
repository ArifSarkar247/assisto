/// AdMob tuning log (owner 25 Oct) — pure Dart seam. The SDK bridges report
/// impressions, clicks and Google's onPaidEvent value here; AdsService
/// installs [AdTelemetry.sink] which posts `POST /ads/event`
/// {placement, format, kind, value_micros, currency, precision}. Never
/// throws, never blocks the ad.
library;

class AdEventRecord {
  const AdEventRecord({
    required this.placement,
    required this.format,
    required this.kind,
    this.valueMicros = 0,
    this.currency = '',
    this.precision = '',
  });

  /// e.g. 'home_native', 'banner_dictionary', 'interstitial_task_done',
  /// 'app_open', 'rewarded_credits'.
  final String placement;

  /// app_open | native | banner | interstitial | rewarded
  final String format;

  /// impression | click | paid
  final String kind;
  final int valueMicros;
  final String currency;

  /// unknown | estimated | publisher_provided | precise
  final String precision;

  Map<String, dynamic> toJson() => {
        'placement': placement,
        'format': format,
        'kind': kind,
        if (kind == 'paid') ...{
          'value_micros': valueMicros,
          'currency': currency,
          'precision': precision,
        },
      };
}

class AdTelemetry {
  AdTelemetry._();

  static void Function(AdEventRecord e)? sink;

  static void _emit(AdEventRecord e) {
    try {
      sink?.call(e);
    } catch (_) {
      // telemetry is best-effort; an ad problem never reaches the UI
    }
  }

  static void impression(String placement, String format) =>
      _emit(AdEventRecord(placement: placement, format: format, kind: 'impression'));

  static void click(String placement, String format) =>
      _emit(AdEventRecord(placement: placement, format: format, kind: 'click'));

  /// Google's onPaidEvent: [valueMicros] of [currency] for ONE impression.
  static void paid(String placement, String format,
      {required double valueMicros,
      required String currency,
      required String precision}) {
    if (valueMicros.isNaN || valueMicros < 0) return;
    _emit(AdEventRecord(
        placement: placement,
        format: format,
        kind: 'paid',
        valueMicros: valueMicros.round(),
        currency: currency.trim().toUpperCase(),
        precision: precision));
  }

  /// PrecisionType.name -> the server's spelling.
  static String precisionName(String enumName) => switch (enumName) {
        'publisherProvided' => 'publisher_provided',
        'estimated' => 'estimated',
        'precise' => 'precise',
        _ => 'unknown',
      };
}
