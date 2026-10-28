// c1-contacts: the on-device canonicaliser must agree byte-for-byte with the
// server (backend/core/phone.py, pinned in backend/core/tests_c1_contacts.py).
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/services/phone_canon.dart';

void main() {
  const canon = '+8801711000777';

  test('Bangladesh numbers in any format', () {
    for (final raw in [
      '01711000777',
      '+8801711000777',
      '8801711000777',
      '008801711000777',
      '+880 1711-000777',
      '(+880) 1711 000777',
      '01711-000777',
      '017.1100.0777',
      '1711000777',
      '+880 01711000777',
      '০১৭১১০০০৭৭৭',
    ]) {
      expect(PhoneCanon.canonical(raw), canon, reason: raw);
    }
  });

  test('invalid numbers are rejected honestly', () {
    for (final raw in [
      '',
      '   ',
      '12345',
      '0171100077',
      '017110007771',
      '01211000777',
      'abc01711000777',
      '+8801234',
      '++880',
      '0000000000',
    ]) {
      expect(PhoneCanon.canonical(raw), isNull, reason: raw);
    }
  });

  test('foreign numbers need an explicit + or 00', () {
    expect(PhoneCanon.canonical('+1 (415) 555-0100'), '+14155550100');
    expect(PhoneCanon.canonical('0044 20 7946 0958'), '+442079460958');
    expect(PhoneCanon.canonical('4155550100'), isNull);
  });

  test('probashi-otp: the 13 expat countries + trunk 0 (mirror of tests_probashi_foreign_login)', () {
    const cases = {
      '+966 50 123 4567': '+966501234567',
      '00966501234567': '+966501234567',
      '+966 050 123 4567': '+966501234567',
      '+971 50 123 4567': '+971501234567',
      '+971 050 123 4567': '+971501234567',
      '+974 3312 3456': '+97433123456',
      '+968 9212 3456': '+96892123456',
      '+965 5012 3456': '+96550123456',
      '+973 3612 3456': '+97336123456',
      '+60 12-345 6789': '+60123456789',
      '+60 012-345 6789': '+60123456789',
      '+65 8123 4567': '+6581234567',
      '+39 312 345 6789': '+393123456789',
      '+39 06 1234 5678': '+390612345678',
      '+44 7700 900123': '+447700900123',
      '+44 07700 900123': '+447700900123',
      '+1 202 555 0143': '+12025550143',
      '+1 416 555 0143': '+14165550143',
      '+61 412 345 678': '+61412345678',
      '+61 0412 345 678': '+61412345678',
    };
    cases.forEach((raw, want) {
      expect(PhoneCanon.canonical(raw), want, reason: raw);
    });
    // local foreign formats can't be told apart from a BD number -> rejected
    expect(PhoneCanon.canonical('0501234567'), isNull);
    expect(PhoneCanon.canonical('966501234567'), isNull);
  });

  test('hash matches the server HMAC-SHA256 contract', () {
    // python: hmac.new(b'test-salt', b'+8801711000777', sha256).hexdigest()[:32]
    expect(PhoneCanon.hashCanonical(canon, 'test-salt'),
        '4031ff64a7d6e569798b0e6c44b8a4c3');
    expect(PhoneCanon.hashCanonical(canon, 'test-salt').length, 32);
    expect(PhoneCanon.hashCanonical('', 'test-salt'), '');
  });

  test('local display form', () {
    expect(PhoneCanon.localForm(canon), '01711000777');
    expect(PhoneCanon.localForm('+14155550100'), '+14155550100');
  });
}
