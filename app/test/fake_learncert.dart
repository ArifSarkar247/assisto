// learncert: fake server answers for the Assisto learning certificate
// screens (gallery + FakeApi). Same shapes as backend core/learn_cert.py
// as_dict(): every visible line in both languages, Bangla digits in bn.

Map<String, dynamic> _lines(String lang,
        {required String name, required String course, required String level,
         String score = '', required String date}) =>
    lang == 'bn'
        ? {
            'title': 'Assisto শেখার সনদ', 'awarded': 'এই মর্মে জানানো যাচ্ছে যে',
            'completed': 'অনুশীলন শেষ করেছেন —', 'name': name, 'course': course,
            'level': level, 'score': score, 'date': date, 'level_label': 'লেভেল',
            'score_label': 'স্কোর', 'date_label': 'তারিখ', 'code_label': 'যাচাই কোড',
            'disclaimer': 'Assisto শেখার সনদ — এটি কোনো অফিসিয়াল যোগ্যতা নয়',
          }
        : {
            'title': 'Assisto Learning Certificate', 'awarded': 'This is to certify that',
            'completed': 'completed practice in', 'name': name, 'course': course,
            'level': level, 'score': score, 'date': date, 'level_label': 'Level',
            'score_label': 'Score', 'date_label': 'Date', 'code_label': 'Verify code',
            'disclaimer': 'Assisto learning certificate — not an official qualification',
          };

Map<String, dynamic> fakeLangCert({bool valid = true}) => {
      'id': 11, 'code': 'ALC-KMPR-TXWA-HBQE', 'course': 'lang_ko', 'level': 'L3',
      'score': 78, 'name': 'Rahim Uddin', 'issued_at': '2026-11-03T09:00:00+06:00',
      'valid': valid, 'revoked_at': valid ? null : '2026-11-04T10:00:00+06:00',
      'verify_url': 'https://lifeassisto.com/verify/ALC-KMPR-TXWA-HBQE', 'kind': 'language',
      'bn': _lines('bn', name: 'রহিম উদ্দিন', course: 'কোরিয়ান — ভাষা শেখার সঙ্গী',
          level: 'লেভেল ৩ (TOPIK-ধাঁচের অনুশীলন) · Assisto অনুশীলন · আনুমানিক',
          score: '৭৮/১০০', date: '৩ নভেম্বর ২০২৬'),
      'en': _lines('en', name: 'Rahim Uddin', course: 'Korean — Language Partner',
          level: 'Level 3 (TOPIK-style practice) · Assisto practice · estimated',
          score: '78/100', date: '3 November 2026'),
    };

Map<String, dynamic> fakeQuranCert() => {
      'id': 12, 'code': 'ALC-QDNZ-RAEB-CMWT', 'course': 'quran_qaida', 'level': 'qaida',
      'score': null, 'name': 'Rahim Uddin', 'issued_at': '2026-11-02T09:00:00+06:00',
      'valid': true, 'revoked_at': null,
      'verify_url': 'https://lifeassisto.com/verify/ALC-QDNZ-RAEB-CMWT', 'kind': 'quran',
      'bn': _lines('bn', name: 'রহিম উদ্দিন', course: 'কুরআন পড়া শেখা — কায়দা',
          level: 'কায়দা সম্পন্ন', date: '২ নভেম্বর ২০২৬'),
      'en': _lines('en', name: 'Rahim Uddin', course: 'Learn to read Quran — Qaida',
          level: 'Qaida completed', date: '2 November 2026'),
    };

Map<String, dynamic>? fakeLearnCertGet(String path, {required bool empty}) {
  final p = path.split('?').first;
  if (p == '/learn/certs' || p == 'learn/certs') {
    return {
      'ok': true,
      'default_name': 'Rahim Uddin',
      'items': empty ? const [] : [fakeLangCert(), fakeQuranCert()],
    };
  }
  return null;
}

Map<String, dynamic>? fakeLearnCertPost(String path, Map<String, dynamic> body) {
  final p = path.split('?').first;
  if (p.endsWith('/learn/certs/claim')) {
    if (body['token'] == null || '${body['token']}'.isEmpty) {
      return {'ok': false, 'reason': 'bad_token', '_status': 400};
    }
    return {'ok': true, 'created': true, 'cert': fakeLangCert(), '_status': 201};
  }
  if (RegExp(r'/learn/certs/\d+/revoke$').hasMatch(p)) {
    return {'ok': true, 'cert': fakeLangCert(valid: false), '_status': 200};
  }
  return null;
}
