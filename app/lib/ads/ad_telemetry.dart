/// AdMob tuning log (owner 25 Oct) — pure Dart seam. The SDK bridges report
/// impressions, clicks and Google's onPaidEvent value here; AdsService
/// installs [AdTelemetry.sink] which posts `POST /ads/event`
/// {placement, format, kind, ad_event_id, value_micros, currency,
/// precision}. Never throws, never blocks the ad.
///
/// COUNTING (owner ads check 28 Oct — "interstitial_photo_saved shows 2
/// impressions and 3 clicks"): every SDK ad object gets ONE
/// [AdInstanceTracker] ([AdTelemetry.track]). Per ad instance it reports at
/// most ONE impression (the first of onAdImpression /
/// onAdShowedFullScreenContent), at most ONE click and only AFTER that
/// impression (Google calls onAdClicked again on every repeat tap, e.g. after
/// the user comes back from the landing page — those are not new clicks for
/// our tuning log), and at most ONE paid value. Each event carries the
/// instance's random `ad_event_id`; the server dedupes on it too and never
/// lets a placement's clicks exceed its impressions.
library;

import 'dart:math' show Random;

class AdEventRecord {
  const AdEventRecord({
    required this.placement,
    required this.format,
    required this.kind,
    this.eventId = '',
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

  /// The ad instance's random id (one per loaded SDK ad object); '' only
  /// for legacy callers.
  final String eventId;
  final int valueMicros;
  final String currency;

  /// unknown | estimated | publisher_provided | precise
  final String precision;

  Map<String, dynamic> toJson() => {
        'placement': placement,
        'format': format,
        'kind': kind,
        if (eventId.isNotEmpty) 'ad_event_id': eventId,
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

  static final Random _rnd = _secure();
  static Random _secure() {
    try {
      return Random.secure();
    } catch (_) {
      return Random();
    }
  }

  /// A fresh per-ad-instance id: 16 lowercase hex chars.
  static String newEventId() {
    final b = StringBuffer();
    for (var i = 0; i < 16; i++) {
      b.write(_rnd.nextInt(16).toRadixString(16));
    }
    return b.toString();
  }

  /// The tracker for ONE SDK ad object. Bridges call this once per load and
  /// route that ad's impression / click / paid callbacks through it.
  static AdInstanceTracker track(String placement, String format) =>
      AdInstanceTracker(placement, format, newEventId());

  /// Legacy, UNDEDUPED single events (kept for old call sites; the SDK
  /// bridges use [track]).
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

/// One ad instance's counters (see the library doc). Pure; never throws.
class AdInstanceTracker {
  AdInstanceTracker(this.placement, this.format, this.eventId);

  final String placement;
  final String format;
  final String eventId;

  bool _impressed = false;
  bool _clicked = false;
  bool _paid = false;

  bool get impressed => _impressed;
  bool get clicked => _clicked;

  /// onAdImpression, or onAdShowedFullScreenContent for a full-screen ad:
  /// the FIRST call counts, every later one is ignored.
  void impression() {
    if (_impressed) return;
    _impressed = true;
    AdTelemetry._emit(AdEventRecord(
        placement: placement, format: format, kind: 'impression', eventId: eventId));
  }

  /// onAdClicked: counted once, and only after this instance's impression
  /// (clicks can never exceed impressions).
  void click() {
    if (!_impressed || _clicked) return;
    _clicked = true;
    AdTelemetry._emit(AdEventRecord(
        placement: placement, format: format, kind: 'click', eventId: eventId));
  }

  /// onPaidEvent: Google's value for this instance's impression, once.
  void paid(
      {required double valueMicros,
      required String currency,
      required String precision}) {
    if (_paid || valueMicros.isNaN || valueMicros < 0) return;
    _paid = true;
    AdTelemetry._emit(AdEventRecord(
        placement: placement,
        format: format,
        kind: 'paid',
        eventId: eventId,
        valueMicros: valueMicros.round(),
        currency: currency.trim().toUpperCase(),
        precision: precision));
  }
}
