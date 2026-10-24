// own-device (owner 24 Oct): the home urgent card never shows anti-theft items
// about the signed-in user's OWN phone; the app sends a hashed install id.
import 'package:assisto/config.dart';
import 'package:assisto/device_id.dart';
import 'package:assisto/screens/agent_thread_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('isOwnDeviceAlert', () {
    test('drops anti-theft rows about my own phone', () {
      expect(isOwnDeviceAlert({'type': 'antitheft', 'owner_id': 7}, 7), isTrue);
      expect(isOwnDeviceAlert({'type': 'security', 'owner_id': '7'}, 7), isTrue);
      expect(isOwnDeviceAlert({'type': 'x', 'own_device': true}, 7), isTrue);
    });

    test('keeps family phones and everything else', () {
      expect(isOwnDeviceAlert({'type': 'antitheft', 'owner_id': 8}, 7), isFalse);
      expect(isOwnDeviceAlert({'type': 'antitheft'}, 7), isFalse);
      expect(isOwnDeviceAlert({'type': 'antitheft', 'owner_id': 7}, null), isFalse);
      expect(isOwnDeviceAlert({'type': 'loan_due', 'owner_id': 7}, 7), isFalse);
    });
  });

  group('DeviceId', () {
    test('derive is a stable 32-hex hash, never the raw id', () {
      final a = DeviceId.derive('00112233445566778899aabbccddeeff');
      expect(a, hasLength(32));
      expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(a), isTrue);
      expect(a, DeviceId.derive('00112233445566778899aabbccddeeff'));
      expect(a, isNot(contains('00112233445566778899')));
      expect(DeviceId.derive('other'), isNot(a));
    });

    test('get loads from the install id and mirrors into AppConfig', () async {
      SharedPreferences.setMockInitialValues(
          {'p5_install_id': '00112233445566778899aabbccddeeff'});
      AppConfig.deviceId = null;
      final id = await DeviceId.get();
      expect(id, DeviceId.derive('00112233445566778899aabbccddeeff'));
      expect(AppConfig.deviceId, id);
      expect(await DeviceId.get(), id);
      expect(DeviceId.now(), id);
      AppConfig.deviceId = null;
    });
  });
}
