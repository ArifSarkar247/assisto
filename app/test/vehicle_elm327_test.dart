import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/vehicle/elm327.dart';

void main() {
  group('Elm327 parsing', () {
    test('coolant with spaces, prompt and SEARCHING noise', () {
      expect(Elm327.coolantC('SEARCHING...\r41 05 7B \r\r>'), 83);
      expect(Elm327.coolantC('41057B>'), 83);
    });

    test('no data / errors give null, never a fake value', () {
      expect(Elm327.coolantC('NO DATA\r>'), isNull);
      expect(Elm327.fuelPct('UNABLE TO CONNECT'), isNull);
      expect(Elm327.rpm('?'), isNull);
      expect(Elm327.dtcs('NO DATA'), isEmpty);
    });

    test('fuel, rpm and battery voltage', () {
      expect(Elm327.fuelPct('41 2F 80')!.round(), 50);
      expect(Elm327.rpm('41 0C 0C 80'), 800);
      expect(Elm327.voltage('12.6V'), 12.6);
      expect(Elm327.voltage('ATRV\r 14.1 V\r>'), 14.1);
      expect(Elm327.voltage('NO DATA'), isNull);
    });

    test('mode 03 legacy (no count byte)', () {
      expect(Elm327.dtcs('43 01 33 00 00 00 00'), ['P0133']);
      expect(Elm327.dtcs('43 03 01 04 20 00 00'), ['P0301', 'P0420']);
    });

    test('mode 03 CAN (count byte, multi-frame prefixes)', () {
      expect(Elm327.dtcs('43 02 03 01 04 20'), ['P0301', 'P0420']);
      expect(Elm327.dtcs('00A\r0: 43 03 03 01 04 20\r1: C1 23 00 00 00 00\r>'),
          ['P0301', 'P0420', 'U0123']);
    });

    test('dtc letter decoding', () {
      expect(Elm327.decodeDtc(0x01, 0x71), 'P0171');
      expect(Elm327.decodeDtc(0x41, 0x23), 'C0123');
      expect(Elm327.decodeDtc(0x91, 0x00), 'B1100');
      expect(Elm327.decodeDtc(0xC1, 0x00), 'U0100');
      expect(Elm327.decodeDtc(0, 0), isNull);
    });
  });
}
