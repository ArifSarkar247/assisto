import '../api.dart';
import '../config.dart';

/// pay1 — the app only ever talks to OUR backend (never to a gateway or to
/// Google's servers). Contract (backend/core/views_pay1.py):
///   GET  /payments/config?flavour=play|apk -> {channels, products, play_account_id, state}
///   GET  /payments/state                   -> entitlement summary
///   POST /payments/checkout {sku, idem, flavour} -> {ok, order{id, status, redirect_url}}
///   GET  /payments/orders/<id>             -> {ok, order, state}
///   POST /payments/play/precheck {sku}     -> {ok, play_account_id} | {ok:false, reason}
///   POST /payments/play/verify {kind, product_id, purchase_token}
/// Prices are the SERVER's; the client never sends an amount.

/// One way to pay, as the owner switched it on the server.
class PayChannel {
  final String id; // 'play' | 'gateway'
  final bool enabled; // owner switch
  final bool ready; // keys added on the server
  final String label;
  const PayChannel(
      {required this.id,
      required this.enabled,
      required this.ready,
      this.label = ''});
  bool get usable => enabled && ready;

  factory PayChannel.fromJson(Map<String, dynamic> j) => PayChannel(
        id: '${j['id'] ?? ''}',
        enabled: j['enabled'] == true,
        ready: j['ready'] == true,
        label: '${j['label'] ?? ''}',
      );
}

class PayProduct {
  final String sku, kind, plan, period, title, playProductId, playBasePlan;
  final int priceBdt, credits, months;
  const PayProduct({
    required this.sku,
    required this.kind,
    this.plan = '',
    this.period = '',
    this.title = '',
    this.playProductId = '',
    this.playBasePlan = '',
    required this.priceBdt,
    this.credits = 0,
    this.months = 0,
  });
  bool get isSub => kind == 'sub';

  static int _i(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

  factory PayProduct.fromJson(Map<String, dynamic> j) => PayProduct(
        sku: '${j['sku'] ?? ''}',
        kind: '${j['kind'] ?? ''}',
        plan: '${j['plan'] ?? ''}',
        period: '${j['period'] ?? ''}',
        title: '${j['title'] ?? ''}',
        playProductId: '${j['play_product_id'] ?? ''}',
        playBasePlan: '${j['play_base_plan'] ?? ''}',
        priceBdt: _i(j['price_bdt']),
        credits: _i(j['credits']),
        months: _i(j['months']),
      );
}

class PayConfig {
  final List<PayChannel> channels;
  final Map<String, List<PayProduct>> products; // channel id -> products
  final String playAccountId;
  const PayConfig(
      {required this.channels,
      required this.products,
      this.playAccountId = ''});

  PayChannel? channel(String id) {
    for (final c in channels) {
      if (c.id == id) return c;
    }
    return null;
  }

  PayProduct? product(String channelId, String sku) {
    for (final p in products[channelId] ?? const <PayProduct>[]) {
      if (p.sku == sku) return p;
    }
    return null;
  }

  /// The channels a user of this build can really pay through: owner switch
  /// on AND keys added (Play only ever on the Play build).
  Iterable<PayChannel> live(String flavour) =>
      channels.where((c) => c.usable && (c.id != 'play' || flavour == 'play'));

  /// NO SHOWPIECES: a buy entry point exists only when this is true.
  bool anyUsable(String flavour) => live(flavour).isNotEmpty;

  /// True when at least one live channel sells [sku].
  bool canBuy(String sku, String flavour) =>
      live(flavour).any((c) => product(c.id, sku) != null);

  factory PayConfig.fromJson(Map<String, dynamic> j) {
    final prods = <String, List<PayProduct>>{};
    final raw = j['products'];
    if (raw is Map) {
      raw.forEach((k, v) {
        prods['$k'] = (v is List ? v : const [])
            .whereType<Map>()
            .map((e) => PayProduct.fromJson(e.cast<String, dynamic>()))
            .toList();
      });
    }
    return PayConfig(
      channels: ((j['channels'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => PayChannel.fromJson(e.cast<String, dynamic>()))
          .toList(),
      products: prods,
      playAccountId: '${j['play_account_id'] ?? ''}',
    );
  }
}

/// A server answer: ok + reason + the server's own localized message.
class PayResult {
  final bool ok;
  final String reason;
  final String message;
  final Map<String, dynamic> data;
  const PayResult(
      {required this.ok,
      this.reason = '',
      this.message = '',
      this.data = const {}});

  factory PayResult.fromRaw(Map<String, dynamic> raw) {
    final st = (raw['_status'] as int?) ?? 200;
    final ok = st >= 200 && st < 300 && raw['ok'] != false;
    return PayResult(
        ok: ok,
        reason: ok ? '' : '${raw['reason'] ?? 'error'}',
        message: '${raw['message'] ?? ''}',
        data: raw);
  }

  static const network = PayResult(ok: false, reason: 'network');

  Map<String, dynamic> get order =>
      (data['order'] as Map?)?.cast<String, dynamic>() ?? const {};
}

/// What the checkout UI depends on (so widget tests inject a fake).
abstract class PaymentsBackend {
  Future<PayConfig> config(String flavour);
  Future<PayResult> checkout(String sku, String idem, String flavour);
  Future<PayResult> order(int id);
  Future<PayResult> playPrecheck(String sku);
  Future<PayResult> playVerify(
      {required String kind,
      required String productId,
      required String purchaseToken});
}

/// 'play' only in the Google Play build; the website APK is 'apk'.
String payFlavour() => AppConfig.playStore ? 'play' : 'apk';

class ApiPaymentsBackend implements PaymentsBackend {
  final ApiClient api;
  ApiPaymentsBackend(this.api);

  Future<PayResult> _post(String path, Map<String, dynamic> body) async {
    try {
      return PayResult.fromRaw(await api.postJsonRaw(path, body));
    } catch (_) {
      return PayResult.network;
    }
  }

  @override
  Future<PayConfig> config(String flavour) async =>
      PayConfig.fromJson(await api.getJson('/payments/config?flavour=$flavour'));

  @override
  Future<PayResult> checkout(String sku, String idem, String flavour) =>
      _post('/payments/checkout', {'sku': sku, 'idem': idem, 'flavour': flavour});

  @override
  Future<PayResult> order(int id) async {
    try {
      return PayResult.fromRaw(await api.getJson('/payments/orders/$id'));
    } catch (_) {
      return PayResult.network;
    }
  }

  @override
  Future<PayResult> playPrecheck(String sku) =>
      _post('/payments/play/precheck', {'sku': sku});

  @override
  Future<PayResult> playVerify(
          {required String kind,
          required String productId,
          required String purchaseToken}) =>
      _post('/payments/play/verify', {
        'kind': kind,
        'product_id': productId,
        'purchase_token': purchaseToken
      });
}
