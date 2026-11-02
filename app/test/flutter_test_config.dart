import 'dart:async';

import 'package:assisto/ads/ad_rules.dart';
import 'package:assisto/crypto/plain_cache.dart';
import 'package:assisto/security/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// Applies to every test file: the app's SecretStore writes real files in the
/// app sandbox, which never completes under the widget-test fake clock, so
/// tests back it with the mocked secure-storage plugin they already reset
/// (FlutterSecureStorage.setMockInitialValues). identity_vault_test builds its
/// own file-backed stores to cover the real path.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  SecretStore.instance = SecretStore.forTests();
  // e2e-recover: the decrypted-message cache is process-wide; tests reuse
  // small message ids, so each test starts with an empty one.
  setUp(() => PlainCache.instance.resetForTests());
  // admobump: the app loads REAL ad units only in a release build; tests
  // cover that release path (ads_consent_ump_test flips it off to prove the
  // debug-build guard).
  setUp(() => AdIds.realUnitsAllowed = true);
  await testMain();
}
