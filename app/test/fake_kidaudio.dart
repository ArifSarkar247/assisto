// kidaudio: fake server answers for the Child emergency audio screen
// (screenshots + FakeApi). Real shapes of backend/core/kid_audio.py rows.

Map<String, dynamic> _consent(int id, String role, String name,
        {required bool active, bool childOk = true, bool watch = false}) =>
    {
      'id': id, 'role': role, 'other_id': 40 + id, 'other_name': name,
      'birth_year': 2014, 'minor': true,
      'parent_ok_at': '2026-11-01T10:00:00Z',
      'child_ok_at': childOk ? '2026-11-01T10:05:00Z' : null,
      'revoked_at': null, 'revoked_by': '', 'active': active,
      'watch_id': watch ? 4 : null, 'has_watch_phone': watch,
    };

Map<String, dynamic>? fakeKidAudioGet(String path, {required bool bn, required bool empty}) {
  final p = path.split('?').first;
  if (p == '/kid-audio/config') {
    if (empty) {
      return {'enabled': true, 'max_session_s': 180, 'max_sessions': 3, 'adult_age': 18,
              'children': const [], 'watches': const [], 'consents': const []};
    }
    return {
      'enabled': true, 'max_session_s': 180, 'max_sessions': 3, 'adult_age': 18,
      'children': [
        {'id': 41, 'name': bn ? 'রিনা' : 'Rina'},
        {'id': 43, 'name': bn ? 'রাফি' : 'Rafi'},
      ],
      'watches': const [],
      'consents': [
        _consent(1, 'guardian', bn ? 'রিনা' : 'Rina', active: true, watch: true),
        _consent(3, 'guardian', bn ? 'রাফি' : 'Rafi', active: false, childOk: false),
        _consent(2, 'child', bn ? 'বাবা' : 'Baba', active: false, childOk: false),
      ],
    };
  }
  if (p == '/kid-audio/log') {
    if (empty) return {'sessions': const []};
    Map<String, dynamic> row(int id, String status, String reason, String at, int? secs) => {
          'id': id, 'channel': 'phone', 'status': status, 'reason': reason, 'role': 'guardian',
          'guardian_name': bn ? 'আপনি' : 'You', 'child_name': bn ? 'রিনা' : 'Rina',
          'emergency_kind': status == 'refused' ? '' : 'sos', 'requested_at': at,
          'started_at': secs == null ? null : at, 'ended_at': null, 'ended_by': '',
          'seconds': secs, 'limit_s': 180, 'notice_shown': secs != null,
        };
    return {
      'sessions': [
        row(12, 'ended', 'time_limit', '2026-11-02T08:40:00Z', 180),
        row(11, 'refused', 'no_emergency', '2026-11-01T19:10:00Z', null),
      ]
    };
  }
  if (p == '/kid-audio/pending') return {'pending': null};
  return null;
}

Map<String, dynamic>? fakeKidAudioPost(String path) {
  if (!path.startsWith('/kid-audio/')) return null;
  return {'ok': true, '_status': 200};
}
