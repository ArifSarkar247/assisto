import 'package:assisto/play_update.dart';
import 'package:flutter_test/flutter_test.dart';

// ota1: the Play in-app update must be a silent no-op outside the Play build
// (the website APK and tests): it never loads the plugin or throws.
void main() {
  test('Play in-app update is a no-op on the direct APK build', () async {
    await PlayUpdate.checkSoon(delay: Duration.zero);
    await PlayUpdate.onBackground();
  });
}
