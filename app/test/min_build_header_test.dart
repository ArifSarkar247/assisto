// min-build: every request carries the FULL app version ("1.0.N+10N", as the
// push registration sends it) in X-App-Version, so the server's per-feature
// minimum build (core/views_features.py MIN_BUILD) can hold a feature back
// from a build that cannot open it.
import 'dart:convert';
import 'dart:io';

import 'package:assisto/api.dart';
import 'package:assisto/config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  tearDown(() => AppConfig.appBuildVersion = '');

  test('header falls back to the short label until the build is known', () {
    AppConfig.appBuildVersion = '';
    expect(AppConfig.appVersionHeader, AppConfig.appVersionLabel);
    AppConfig.appBuildVersion = '1.0.331+10381';
    expect(AppConfig.appVersionHeader, '1.0.331+10381');
  });

  test('a normal GET sends X-App-Version = version+build', () async {
    AppConfig.appBuildVersion = '1.0.331+10381';
    final seen = <String?>[];
    await http.runWithClient(() async {
      final api = ApiClient(token: 't');
      await api.getJson('/features/');
    }, () => MockClient((req) async {
          seen.add(req.headers['X-App-Version']);
          return http.Response(jsonEncode({'ok': true}), 200,
              headers: {'content-type': 'application/json'});
        }));
    expect(seen, isNotEmpty);
    expect(seen.every((v) => v == '1.0.331+10381'), isTrue, reason: '$seen');
  });

  test('main resolves the version after the first frame (never before)', () {
    final main = File('lib/main.dart').readAsStringSync();
    expect(main, contains('unawaited(AppVersion.resolve());'));
    final api = File('lib/api.dart').readAsStringSync();
    expect(api, contains("'X-App-Version': AppConfig.appVersionHeader"));
  });
}
