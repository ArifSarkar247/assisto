import 'dart:async';

import 'package:assisto/security/secret_store.dart';

/// Applies to every test file: the app's SecretStore writes real files in the
/// app sandbox, which never completes under the widget-test fake clock, so
/// tests back it with the mocked secure-storage plugin they already reset
/// (FlutterSecureStorage.setMockInitialValues). identity_vault_test builds its
/// own file-backed stores to cover the real path.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  SecretStore.instance = SecretStore.forTests();
  await testMain();
}
