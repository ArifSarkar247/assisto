// c1-contacts: screenshot-gallery stubs for the WhatsApp-style contacts
// screen (FakeApi hooks + a fake phonebook source).
import 'dart:async';

import 'package:assisto/services/contacts_source.dart';
import 'package:assisto/services/phone_canon.dart';

const _salt = 'gallery-salt';

final Map<String, Map<String, dynamic>> _users = {
  '+8801711000777': {
    'id': 2, 'name': 'Rahim Uddin', 'photo': '',
    'circle': {'state': 'none', 'member_id': null, 'member': null},
  },
  '+8801711000555': {
    'id': 3, 'name': 'Karim Hossain', 'photo': '',
    'circle': {
      'state': 'accepted', 'member_id': 30,
      'member': {'id': 30, 'name': 'Karim Hossain', 'state': 'accepted'},
    },
  },
  '+8801811000666': {
    'id': 4, 'name': 'Nasrin Akter', 'photo': '',
    'circle': {'state': 'pending', 'member_id': 31, 'member': null},
  },
};

Map<String, dynamic>? fakeC1Get(String path) {
  if (path == '/messenger/contacts/contract') {
    return {'salt': _salt, 'hash_len': 32, 'country_code': '880'};
  }
  return null;
}

Map<String, dynamic>? fakeC1Post(String path, Map<String, dynamic> body) {
  if (path == '/messenger/contacts/match') {
    final hs = (body['hashes'] as List?) ?? const [];
    return {
      'ok': true,
      'stored': false,
      'matches': [
        for (final e in _users.entries)
          if (hs.contains(PhoneCanon.hashCanonical(e.key, _salt)))
            {'contact_hash': PhoneCanon.hashCanonical(e.key, _salt),
             'user': Map.of(e.value)},
      ],
    };
  }
  if (path == '/messenger/contacts/lookup') {
    final p = '${body['phone']}';
    final u = _users[p];
    return u == null
        ? {'ok': true, 'found': false, 'phone': p, 'is_self': false}
        : {'ok': true, 'found': true, 'phone': p, 'user': Map.of(u)};
  }
  return null;
}

class C1GallerySource implements ContactsSource {
  const C1GallerySource();

  @override
  bool get available => true;
  @override
  Future<ContactsPermission> status() async => ContactsPermission.granted;
  @override
  Future<ContactsPermission> request() async => ContactsPermission.granted;
  @override
  Future<List<DeviceContact>> read() async => const [
        DeviceContact(name: 'Rahim (office)', numbers: ['+880 1711-000777']),
        DeviceContact(name: 'Karim bhai', numbers: ['01711-000555']),
        DeviceContact(name: 'Nasrin', numbers: ['01811000666']),
        DeviceContact(name: 'Ammu', numbers: ['01999 888777']),
        DeviceContact(name: 'Sadia Rahman Chowdhury', numbers: ['01555123456']),
      ];
  @override
  Stream<void> get changes => const Stream<void>.empty();
  @override
  Future<bool> openSettings() async => true;
}
