// c1-contacts: the on-device canonicaliser must agree byte-for-byte with the
// server (backend/core/phone.py, pinned in backend/core/tests_c1_contacts.py).
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/services/phone_canon.dart';

void main() {
  const canon = '+8801865052200';

  test('Bangladesh numbers in any format', () {
    for (final raw in [
      '01865052200',
      '+8801865052200',
      '8801865052200',
      '008801865052200',
      '+880 1865-052200',
      '(+880) 1865 052200',
      '01865-052200',
      '018.6505.2200',
      '1865052200',
      '+880 01865052200',
      '০১৮৬৫০৫২২০০',
    ]) {
      expect(PhoneCanon.canonical(raw), canon, reason: raw);
    }
  });

  test('invalid numbers are rejected honestly', () {
    for (final raw in [
      '',
      '   ',
      '12345',
      '0186505220',
      '018650522001',
      '01265052200',
      'abc01865052200',
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

  test('hash matches the server HMAC-SHA256 contract', () {
    // python: hmac.new(b'test-salt', b'+8801865052200', sha256).hexdigest()[:32]
    expect(PhoneCanon.hashCanonical(canon, 'test-salt'),
        '85c19d650555da8e76e6190a98d62829');
    expect(PhoneCanon.hashCanonical(canon, 'test-salt').length, 32);
    expect(PhoneCanon.hashCanonical('', 'test-salt'), '');
  });

  test('local display form', () {
    expect(PhoneCanon.localForm(canon), '01865052200');
    expect(PhoneCanon.localForm('+14155550100'), '+14155550100');
  });
}
