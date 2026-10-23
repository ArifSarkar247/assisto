// rt1 (reality audit, run 39884806316): Quick Sell could not add anything to
// the cart. The variant picker cast `v['id'] as int` but variants carry a
// string `key` (no id) and the client posted `variant` while the server reads
// `variant_key`. This pins the request contract the server expects.
import 'dart:convert';

import 'package:assisto/api.dart';
import 'package:assisto/business_selling_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('cartAdd posts the variant KEY as variant_key (never a numeric id)', () async {
    Map<String, dynamic>? body;
    String path = '';
    final mock = MockClient((req) async {
      path = req.url.path;
      body = (jsonDecode(req.body) as Map).cast<String, dynamic>();
      return http.Response(jsonEncode({'cart': {'lines': []}}), 200,
          headers: {'content-type': 'application/json'});
    });
    await http.runWithClient(() async {
      final api = ApiClient(token: 't');
      await api.cartAdd(cart: const {}, productId: 7, variantKey: 'L|red');
    }, () => mock);
    expect(path, endsWith('/business/cart/add'));
    expect(body!['product'], 7);
    expect(body!['variant_key'], 'L|red');
    expect(body!.containsKey('variant'), isFalse);
  });

  test('no variant key -> the server falls back to the only (base) variant', () async {
    Map<String, dynamic>? body;
    final mock = MockClient((req) async {
      body = (jsonDecode(req.body) as Map).cast<String, dynamic>();
      return http.Response(jsonEncode({'cart': {'lines': []}}), 200,
          headers: {'content-type': 'application/json'});
    });
    await http.runWithClient(() async {
      await ApiClient(token: 't').cartAdd(cart: const {}, productId: 3);
    }, () => mock);
    expect(body!.containsKey('variant_key'), isFalse);
    expect(body!['qty'], 1);
  });
}
