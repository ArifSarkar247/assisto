// m3-circle: screenshot-gallery stubs for My Circle requests (incoming +
// sent). Active only for the m3_* gallery shots (set in shoot()).
bool fakeM3On = false;

Map<String, dynamic>? fakeM3Get(String path, {bool bn = false}) {
  if (!fakeM3On) return null;
  if (path.startsWith('/circle/requests')) {
    return {
      'results': [
        {
          'id': 41, 'direction': 'incoming',
          'display_name': bn ? 'নাদিয়া রহমান' : 'Nadia Rahman',
          'relation_label': bn ? 'বন্ধু' : 'Friend',
          'note': bn ? 'আমি নাদিয়া, অফিসের' : "It's Nadia from the office",
          'actions': ['accept', 'decline', 'block'],
        },
        {
          'id': 42, 'direction': 'incoming',
          'display_name': bn ? 'করিম হোসেন' : 'Karim Hossain',
          'actions': ['accept', 'decline', 'block'],
        },
        {
          'id': 43, 'direction': 'outgoing',
          'display_name': bn ? 'সেলিনা আক্তার' : 'Selina Akter',
          'actions': ['cancel', 'block'],
        },
      ],
    };
  }
  return null;
}
