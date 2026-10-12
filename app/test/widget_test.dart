// Minimal smoke test (replaces flutter create's default MyApp test).
import 'package:flutter_test/flutter_test.dart';
import 'package:assisto/config.dart';

void main() {
  test('config has api base', () {
    expect(AppConfig.apiBase.isNotEmpty, true);
    expect(AppConfig.api('/health').toString().contains('/api/v1/health'), true);
  });
}
