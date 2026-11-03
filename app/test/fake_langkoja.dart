// langkoja — fakes for the Korea/Japan work-language path screens. Shapes are
// copied from the real server packs (backend/core/data/langpacks/ko.json,
// langpacks_listening/ko.json) via GET /learn/pack/ko and /learn/ko/listening.

const _label = {
  'en': 'Assisto practice estimate — not an official exam result.',
  'bn': 'Assisto অনুশীলনের অনুমান — অফিসিয়াল পরীক্ষার ফল নয়।',
};

Map<String, dynamic> fakeWorkPathPack(String lang) => {
      'format': 1,
      'lang': lang,
      'stt_locale': lang == 'ko' ? 'ko-KR' : 'ja-JP',
      'estimate_label': _label,
      'work_path': lang == 'ko'
          ? {
              'title_en': 'Work in Korea: the EPS path',
              'title_bn': 'কোরিয়ায় কাজ: EPS পথ',
              'steps': [
                {
                  'en': 'EPS (Employment Permit System) is government-to-government. In Bangladesh only BOESL runs it. Never pay a broker or agent.',
                  'bn': 'EPS (এমপ্লয়মেন্ট পারমিট সিস্টেম) সরকার-থেকে-সরকার পদ্ধতি। বাংলাদেশে শুধু BOESL এটা চালায়। কোনো দালাল বা এজেন্টকে টাকা দেবেন না।'
                },
                {
                  'en': 'Learn Korean and pass EPS-TOPIK (reading + listening, on a computer or tablet). A higher score ranks you higher.',
                  'bn': 'কোরিয়ান শিখে EPS-TOPIK পাস করুন (রিডিং + লিসেনিং, কম্পিউটার বা ট্যাবলেটে)। নম্বর বেশি হলে তালিকায় আগে থাকবেন।'
                },
              ],
              'links': [
                {'en': 'BOESL (Bangladesh)', 'bn': 'BOESL (বাংলাদেশ)', 'url': 'https://boesl.gov.bd/'},
                {'en': 'EPS Korea (official)', 'bn': 'EPS কোরিয়া (অফিসিয়াল)', 'url': 'https://www.eps.go.kr/'},
              ],
            }
          : {
              'title_en': 'Work in Japan: the JFT-Basic path',
              'title_bn': 'জাপানে কাজ: JFT-Basic পথ',
              'steps': [
                {
                  'en': 'JFT-Basic is a computer test at Prometric centres. Check dates and centres on the Japan Foundation JFT-Basic site.',
                  'bn': 'JFT-Basic কম্পিউটারে, Prometric কেন্দ্রে হয়। তারিখ ও কেন্দ্র Japan Foundation-এর JFT-Basic সাইটে দেখুন।'
                },
              ],
              'links': [
                {'en': 'JFT-Basic (Japan Foundation)', 'bn': 'JFT-Basic (Japan Foundation)', 'url': 'https://www.jpf.go.jp/jft-basic/'},
              ],
            },
    };

Map<String, dynamic> fakeListening(String lang) => {
      'lang': lang,
      'tts_locale': lang == 'ko' ? 'ko-KR' : 'ja-JP',
      'label_en': "Read by your phone's voice — not exam audio. Practice only.",
      'label_bn': 'ফোনের কণ্ঠে পড়া — পরীক্ষার অডিও নয়। শুধু অনুশীলন।',
      'estimate_label': _label,
      'questions': [
        {
          'id': 'kl1',
          'type': 'mcq',
          'skill': 'listening',
          'say': '물 좀 주세요.',
          'text': '무엇을 달라고 합니까?',
          'options': ['밥', '물', '돈', '우유'],
        },
        {
          'id': 'kl2',
          'type': 'mcq',
          'skill': 'listening',
          'say': '안전모를 꼭 쓰세요.',
          'text': '무엇을 써야 합니까?',
          'options': ['안경', '마스크', '안전모', '모자 없이'],
        },
      ],
    };

Map<String, dynamic> fakeListeningResult() => {
      'ok': true,
      'correct': 1,
      'total': 2,
      'answered': 2,
      'score_pct': 50,
      'estimate': true,
      'estimate_label': _label,
      'rows': [
        {'id': 'kl1', 'given': 1, 'answer': 1, 'correct': true, 'explain_bn': '물 = পানি।', 'explain_en': 'Water.'},
        {'id': 'kl2', 'given': 0, 'answer': 2, 'correct': false, 'explain_bn': '안전모 = হেলমেট।', 'explain_en': 'A hard hat.'},
      ],
    };

Map<String, dynamic>? fakeLangkojaGet(String path) {
  if (path == '/learn/pack/ko') return fakeWorkPathPack('ko');
  if (path == '/learn/pack/ja') return fakeWorkPathPack('ja');
  if (path == '/learn/ko/listening') return fakeListening('ko');
  if (path == '/learn/ja/listening') return fakeListening('ja');
  return null;
}

Map<String, dynamic>? fakeLangkojaPost(String path, Map body) {
  if (path == '/learn/ko/listening/grade' || path == '/learn/ja/listening/grade') {
    return fakeListeningResult();
  }
  return null;
}
