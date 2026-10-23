import 'dart:convert';
import 'package:http/http.dart' as http;
import 'api.dart';
import 'config.dart';

/// Business v2 — SELLING module API surface (§3 of BUSINESS_V2_PLAN.md).
///
/// Implemented as an EXTENSION on [ApiClient] built only on its public helpers
/// (getJson / postJson / listItems / createItem / deleteItem / getBytes / the
/// public `token`) so this module ships without editing the shared api.dart.
/// The integrator SHOULD later fold these into ApiClient proper — the paths and
/// signatures below are authoritative (see biz_selling_integration.md §b).
///
/// MONEY: everything the server returns is integer POISHA (1 taka = 100 poisha).
/// The UI formats via [MoneyX]. Minimum-price enforcement lives in the pure
/// backend layer — the client NEVER bypasses it: below-min add / price-set
/// return HTTP 422 with `ref == 'below_min'`, surfaced here as
/// [BelowMinException] so screens can show the bilingual `biz_below_min` string.
///
/// STAFF REDACTION: list/detail/report responses for a staff role arrive with
/// cost_price / min_price / profit / margin / net already stripped by the
/// server. The client treats any missing cost/min field as "redacted" and hides
/// the corresponding UI (never guesses a value).
extension BusinessSellingApi on ApiClient {
  // ---------------------------------------------------------------- products

  /// GET products/ — list for the current business. Server applies
  /// `redact_product(p, role)`; staff rows arrive without cost/min/profit.
  /// Optional [businessId] scopes to one business (plan §1, multiple books).
  Future<List<Map<String, dynamic>>> productsList({
    int? businessId,
    String? category,
    String? query,
  }) async {
    final qs = <String, String>{
      if (businessId != null) 'business': '$businessId',
      if (category != null && category.isNotEmpty) 'category': category,
      if (query != null && query.isNotEmpty) 'q': query,
    };
    final r = await getJson(_q('business/products', qs));
    return ((r['products'] ?? r['results'] ?? []) as List)
        .cast<Map<String, dynamic>>();
  }

  /// GET products/{id}/ — one product with its variants (staff redacted).
  Future<Map<String, dynamic>> productGet(int id) =>
      getJson('/business/products/$id');

  /// POST products/ — create (owner only; writes cost/min). Fields match
  /// `make_product` + `validate_product`. Money fields are sent as TAKA strings
  /// (the view parses via `taka_to_poisha`); the caller passes raw taka.
  Future<Map<String, dynamic>> productCreate(Map<String, dynamic> body) =>
      postJson('/business/products', body);

  /// PATCH-style update via POST products/{id} (owner only).
  Future<Map<String, dynamic>> productUpdate(int id, Map<String, dynamic> body) =>
      postJson('/business/products/$id', body);

  // (m2-reality: unused productDelete() removed — it sent 'products/<id>/'
  // which 404s; DELETE business/products/<id> exists for a future caller.)

  /// POST products/{id}/variants/ — add a size/colour variant (owner only).
  Future<Map<String, dynamic>> variantCreate(
          int productId, Map<String, dynamic> body) =>
      postJson('/business/products/$productId/variants', body);

  // -------------------------------------------------------- Excel import

  /// POST products/import/ — preview + confirm Excel/CSV import (owner only).
  ///
  /// Two-phase: send [confirm]=false first to get the parsed preview
  /// (`parse_import_rows` + `check_import_uniqueness` → {products, bad_rows,
  /// conflicts}); re-send the SAME file with [confirm]=true to persist.
  /// Multipart because the shared api.dart has no file helper for this path.
  Future<Map<String, dynamic>> productsImport({
    required String filePath,
    int? businessId,
    bool confirm = false,
  }) async {
    final req =
        http.MultipartRequest('POST', AppConfig.api('/business/products/import'));
    if (token != null) req.headers['Authorization'] = 'Token $token';
    req.headers['Accept-Language'] = lang ?? 'bn';
    if (businessId != null) req.fields['business'] = '$businessId';
    req.fields['confirm'] = confirm ? 'true' : 'false';
    req.files.add(await http.MultipartFile.fromPath('file', filePath));
    final streamed = await req.send();
    final body = await streamed.stream.bytesToString();
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      _throwFrom(body, streamed.statusCode, 'Import failed');
    }
    return body.isEmpty ? {} : jsonDecode(body) as Map<String, dynamic>;
  }

  // --------------------------------------------------------------- cart
  //
  // The cart is CLIENT-HELD — there is NO server-side cart. Every endpoint
  // takes the current cart object under `cart` and returns the recomputed cart
  // under `cart` (plus an optional `line` for the affected line). The screen
  // holds the cart in state and threads it through each call, replacing its
  // local copy with the returned one. `cartGet` just seeds an empty cart.

  /// Seed an empty client cart. No network — kept async-shaped so callers that
  /// previously awaited a GET keep working; the server never owns a cart.
  Future<Map<String, dynamic>> cartGet({int? businessId}) async =>
      <String, dynamic>{
        'lines': <Map<String, dynamic>>[],
        'subtotal': 0,
        'discount': 0,
        'total': 0,
        if (businessId != null) 'business': businessId,
      };

  /// Extract the updated cart from a stateless-cart response, falling back to
  /// the response itself if the server returned the cart at the top level.
  Map<String, dynamic> _cartOf(Map<String, dynamic> res) {
    final c = res['cart'];
    if (c is Map) return c.cast<String, dynamic>();
    return res;
  }

  /// POST cart/add/ — add a product/variant line to [cart]. `cart_add_line`
  /// rejects a below-min unit price with 422 `below_min` → [BelowMinException].
  /// Returns the updated cart object.
  Future<Map<String, dynamic>> cartAdd({
    required Map<String, dynamic> cart,
    required int productId,
    String? variantKey,
    int qty = 1,
    num? unitPriceTaka,
    int? businessId,
  }) async {
    final res = await _postGuardMin('/business/cart/add', {
      'cart': cart,
      'product': productId,
      // rt1: the server identifies a variant by its KEY (cart_add_line's
      // variant_key); variants carry no numeric id.
      if (variantKey != null) 'variant_key': variantKey,
      'qty': qty,
      if (unitPriceTaka != null) 'unit_price': '$unitPriceTaka',
      if (businessId != null) 'business': businessId,
    });
    return _cartOf(res);
  }

  /// POST cart/line/{id}/price/ — bargain override on a line in [cart].
  /// Below-min → 422 `below_min` and the price is left UNCHANGED. Returns the
  /// updated cart object.
  Future<Map<String, dynamic>> cartSetPrice(
      Map<String, dynamic> cart, int lineId, num unitPriceTaka) async {
    final res = await _postGuardMin('/business/cart/line/$lineId/price',
        {'cart': cart, 'unit_price': '$unitPriceTaka'});
    return _cartOf(res);
  }

  /// POST cart/line/{id}/qty/ — set the quantity of a line in [cart]. Returns
  /// the updated cart object.
  Future<Map<String, dynamic>> cartSetQty(
      Map<String, dynamic> cart, int lineId, int qty) async {
    final res = await postJson(
        '/business/cart/line/$lineId/qty', {'cart': cart, 'qty': qty});
    return _cartOf(res);
  }

  /// POST cart/line/{id}/remove/ — drop a line from [cart]. Returns the updated
  /// cart object (the cart is client-held, so removal recomputes totals).
  Future<Map<String, dynamic>> cartRemove(
      Map<String, dynamic> cart, int lineId) async {
    final res = await postJson(
        '/business/cart/line/$lineId/remove', {'cart': cart});
    return _cartOf(res);
  }

  /// POST cart/discount/preview/ — try a blanket discount on [cart]. The server
  /// CLAMPS any discount that would breach the min floor and returns the cart
  /// with `discount_clamped: true` (NOT a 422 — a successful, clamped preview).
  /// Screens show `biz_discount_clamped`. Returns the updated cart object (the
  /// `discount_clamped` flag is carried on the returned cart).
  Future<Map<String, dynamic>> cartDiscountPreview({
    required Map<String, dynamic> cart,
    num? amountTaka,
    num? percent,
  }) async {
    final res = await postJson('/business/cart/discount/preview', {
      'cart': cart,
      if (amountTaka != null) 'amount': '$amountTaka',
      if (percent != null) 'percent': percent,
    });
    final updated = _cartOf(res);
    // Surface the clamp flag on the returned cart even if the server put it at
    // the response top level.
    if (res['discount_clamped'] == true) updated['discount_clamped'] = true;
    return updated;
  }

  // --------------------------------------------------------------- checkout

  /// POST sales/checkout/ — persist the sale. Staff MAY complete a sale; the
  /// response is `redact_sale(res, role)` so staff get no profit/cost. Any
  /// discount is clamped to the min floor server-side (`discount_clamped`).
  /// Throws [BelowMinException] if a line price is still below min (defensive).
  Future<Map<String, dynamic>> checkout({
    required Map<String, dynamic> cart,
    int? businessId,
    int? customerId,
    required String paymentMethod, // cash | bkash | nagad | due
    num? paidTaka,
    num? discountTaka,
    num? discountPercent,
    String? note,
  }) =>
      _postGuardMin('/business/sales/checkout', {
        'cart': cart,
        if (businessId != null) 'business': businessId,
        if (customerId != null) 'customer': customerId,
        'payment_method': paymentMethod,
        if (paidTaka != null) 'paid': '$paidTaka',
        if (discountTaka != null) 'discount': '$discountTaka',
        if (discountPercent != null) 'discount_percent': discountPercent,
        if (note != null && note.isNotEmpty) 'note': note,
      });

  /// GET sales/{id}/receipt/ — structured receipt (`build_receipt`). Staff see
  /// it without profit. Returns the receipt map; screens render + share it.
  Future<Map<String, dynamic>> saleReceipt(int saleId) =>
      getJson('/business/sales/$saleId/receipt');

  /// GET sales/{id}/receipt.pdf — raw PDF bytes for share (optional). Falls
  /// back to text share in the UI if the backend returns non-PDF.
  Future<List<int>> saleReceiptPdf(int saleId) =>
      getBytes('/business/sales/$saleId/receipt.pdf');

  // --------------------------------------------------------------- customers

  Future<List<Map<String, dynamic>>> customersList({
    int? businessId,
    String? query,
  }) async {
    final r = await getJson(_q('business/customers', {
      if (businessId != null) 'business': '$businessId',
      if (query != null && query.isNotEmpty) 'q': query,
    }));
    return ((r['customers'] ?? r['results'] ?? []) as List)
        .cast<Map<String, dynamic>>();
  }

  /// POST customers/ — create/update. Dedupe is by normalised phone
  /// (`phone_key`): re-posting a known phone updates the existing row.
  Future<Map<String, dynamic>> customerSave(Map<String, dynamic> body) =>
      postJson('/business/customers', body);

  // (m2-reality: unused customerDelete() removed — no such backend route.)

  /// POST customers/dedupe/ — merge duplicate phone rows (owner).
  Future<Map<String, dynamic>> customersDedupe({int? businessId}) =>
      postJson('/business/customers/dedupe',
          {if (businessId != null) 'business': businessId});

  /// GET customers/{phone}/history/ — purchase history + open dues
  /// (`purchase_history`, `customer_dues_poisha`). Staff OK (no cost).
  Future<Map<String, dynamic>> customerHistory(String phone) =>
      getJson('/business/customers/${Uri.encodeComponent(phone)}/history');

  // --------------------------------------------------------------- reports

  /// GET reports/?period=daily|weekly|monthly — `full_report`. For a staff
  /// role the server calls `full_report(..., role='staff')` so profit / cost /
  /// net are absent; screens detect the missing keys and hide those rows.
  Future<Map<String, dynamic>> report({
    String period = 'daily',
    int? businessId,
  }) =>
      getJson(_q('business/reports', {
        'period': period,
        if (businessId != null) 'business': '$businessId',
      }));

  // --------------------------------------------------------------- internals

  Future<Map<String, dynamic>> _postGuardMin(
      String path, Map<String, dynamic> body) async {
    try {
      return await postJson(path, body);
    } on ApiException catch (e) {
      if (e.status == 422 && (e.ref == 'below_min' || e.ref == 'min_price')) {
        throw BelowMinException(e.message, e.ref);
      }
      rethrow;
    }
  }

  Never _throwFrom(String body, int status, String fallback) {
    String msg = fallback;
    String? ref;
    try {
      final j = jsonDecode(body);
      if (j is Map) {
        ref = j['ref']?.toString();
        msg = (j['detail'] ?? j['error'] ?? fallback).toString();
      }
    } catch (_) {}
    if (status == 422 && (ref == 'below_min' || ref == 'min_price')) {
      throw BelowMinException(msg, ref);
    }
    throw ApiException(msg, status, ref);
  }

  String _q(String path, Map<String, String> qs) {
    final p = path.startsWith('/') ? path : '/$path';
    if (qs.isEmpty) return p;
    final query = qs.entries
        .map((e) =>
            '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    return '$p?$query';
  }
}

/// Raised when the server rejects a sale/price for breaching the minimum price
/// floor (HTTP 422, ref `below_min`). Screens catch this specifically and show
/// the localised `biz_below_min` message — the hard, server-side gate.
class BelowMinException extends ApiException {
  BelowMinException(String message, [String? ref]) : super(message, 422, ref);
}

/// POISHA ⇄ taka helpers (mirror of the backend converters). All money in the
/// selling module crosses the wire as integer poisha; render with [fmtTaka].
extension MoneyX on int {
  /// poisha → taka (double, for arithmetic only — never stored).
  double get takaValue => this / 100.0;

  /// "৳1,250.50" style display (2 dp, trailing .00 trimmed, thousands
  /// grouped — matches the money screens).
  String get fmtTaka {
    final neg = this < 0;
    final abs = this.abs();
    final whole = (abs ~/ 100).toString();
    final frac = abs % 100;
    final buf = StringBuffer();
    for (var i = 0; i < whole.length; i++) {
      if (i > 0 && (whole.length - i) % 3 == 0) buf.write(',');
      buf.write(whole[i]);
    }
    final dec = frac == 0 ? '' : '.${frac.toString().padLeft(2, '0')}';
    return '${neg ? '-' : ''}৳$buf$dec';
  }
}

/// Parse a possibly-null money value from an API map as poisha (int).
int poishaOf(dynamic v) {
  if (v == null) return 0;
  if (v is int) return v;
  if (v is double) return v.round();
  if (v is String) return int.tryParse(v) ?? (double.tryParse(v)?.round() ?? 0);
  return 0;
}
