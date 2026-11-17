// speedproof: the Guard Box phone's live-request poll period (ipcam_logic).
import 'package:assisto/ipcam/ipcam_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('0 or less = off (heartbeat only)', () {
    expect(livePollEvery(0), isNull);
    expect(livePollEvery(-3), isNull);
  });
  test('server value is clamped to 2..60 s', () {
    expect(livePollEvery(4), const Duration(seconds: 4));
    expect(livePollEvery(1), const Duration(seconds: 2));
    expect(livePollEvery(600), const Duration(seconds: 60));
  });
}
