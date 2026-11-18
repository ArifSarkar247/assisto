// gap-nearby (18 Nov): metro fare between two stations — the same rule as
// the server (backend/core/citytransit/fares.py metro()): an official chart
// amount for the pair wins; otherwise the official DTCA rate (Tk per km
// along the line, rounded to 10, between the minimum and the maximum).
// Works online (GET /city/metro `fare`) and offline (the city package's
// `rates.metro`). Never a guess: no chart hit and no km = no fare.
import 'city_models.dart' show CityStation;
import 'city_offline.dart' show metroChartTk;

class MetroPairFare {
  final int tk; // single-journey ticket
  final int card; // MRT / Rapid Pass price
  final bool fromChart; // true = the official station-pair chart
  final double? km;
  const MetroPairFare(this.tk, this.card, {required this.fromChart, this.km});
}

MetroPairFare? metroPairFare(CityStation a, CityStation b, Map<String, dynamic> fare) {
  if (a.id == b.id || (a.code.isNotEmpty && a.code == b.code)) return null;
  num n(String k, num def) => (fare[k] as num?) ?? def;
  final disc = n('card_discount_pct', 0);
  int cardOf(int tk) => disc > 0 ? (tk - tk * disc / 100).floor() : tk;
  final km = a.km != null && b.km != null ? (a.km! - b.km!).abs() : null;
  final hit = metroChartTk(fare['chart'], a.code, b.code);
  if (hit != null) return MetroPairFare(hit, cardOf(hit), fromChart: true, km: km);
  if (km == null) return null;
  final step = n('round_to', 10).clamp(1, 100);
  final raw = ((km * n('per_km', 5)) / step).round() * step;
  final tk = raw.clamp(n('min', 20), n('max', 100)).round();
  return MetroPairFare(tk, cardOf(tk), fromChart: false, km: km);
}
