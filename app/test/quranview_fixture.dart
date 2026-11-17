// quranview: gallery + test fixture for the bilingual ayah view.
// Meaning / tafsir / footnote texts are the REAL QuranEnc.com texts, copied
// VERBATIM from https://quranenc.com/api/v1/translation/aya/<key>/<s>/<a>
// (9 Nov 2026; bengali_zakaria 1.1.1, english_saheeh 1.1.2,
// bengali_mokhtasar 1.0.0) — QuranEnc allows unmodified re-publishing with
// publisher, source and version. Nothing here is invented Quran meaning.
// The Quran Foundation part (word-by-word, transliteration, audio URL) is a
// SMALL TEST FIXTURE ONLY (never shipped, no QF data is bundled): standard
// dictionary glosses for the four words of 1:1, written for this test.
// The pronunciation line stands in for lane 15's rule engine output.

import 'dart:async';

import 'package:assisto/quran/quran_ayah_audio.dart';

/// Gallery / sweep player: never touches the audioplayers plugin (a real
/// AudioPlayer created in a test process stalls other screens' players).
class QvSilentPlayer implements QvPlayer {
  final _done = StreamController<void>.broadcast();
  @override
  Future<void> playUrl(String url) async {}
  @override
  Future<void> stop() async {}
  @override
  Stream<void> get completed => _done.stream;
  @override
  Future<void> dispose() async {}
}

const _zakPub = 'Encyclopedia of the Noble Quran';
const _sahPub = 'Noor International Center';
const _mukPub = 'Tafsir Center for Quranic Studies';

Map<String, dynamic> _book(String key, String lang, String tbn, String ten,
        String pub, String ver, List<Map<String, dynamic>> items) =>
    {
      'key': key, 'lang': lang, 'title_bn': tbn, 'title_en': ten,
      'publisher': pub, 'version': ver, 'source': 'QuranEnc.com',
      'source_url': 'https://quranenc.com', 'items': items,
    };

Map<String, dynamic> qvMeaning(int surah) => {
      'ok': true,
      'surah': surah,
      'bn': _book('bengali_zakaria', 'bn',
          'বাংলা অনুবাদ — আবু বকর মুহাম্মাদ যাকারিয়া',
          'Bengali Translation — Abu Bakr Zakaria', _zakPub, '1.1.1', [
        if (surah == 1) {'ayah': 1, 'text': "রহমান, রহীম [১] আল্লাহ্‌র নামে [২]", 'footnotes': ''},
        if (surah == 80) {'ayah': 1, 'text': "তিনি ভ্ৰকুঞ্চিত করলেন এবং মুখ ফিরিয়ে নিলেন [১] ,", 'footnotes': ''},
      ]),
      'en': _book('english_saheeh', 'en',
          'ইংরেজি অনুবাদ — Saheeh International',
          'English Translation — Saheeh International', _sahPub, '1.1.2', [
        if (surah == 1) {'ayah': 1, 'text': "In the name of Allāh,[2] the Entirely Merciful, the Especially Merciful.[3]", 'footnotes': ''},
        if (surah == 80) {'ayah': 1, 'text': "He [i.e., the Prophet (ﷺ) ] frowned and turned away", 'footnotes': ''},
      ]),
    };

Map<String, dynamic> _src(String id, String lang, String tbn, String ten,
        String pub, String ver, String text) =>
    {
      'id': id, 'lang': lang, 'title_bn': tbn, 'title_en': ten,
      'publisher': pub, 'version': ver, 'source': 'QuranEnc.com',
      'source_url': 'https://quranenc.com', 'text': text,
    };

const _mukBn = 'আল-মুখতাসার ফী তাফসীরিল কুরআন (বাংলা)';
const _mukEn = 'Al-Mukhtasar in Interpreting the Noble Quran (Bengali)';

/// 1:1 — no source states a reason of revelation -> the "none" line.
/// 80:1 — Abu Bakr Zakaria's note states it -> that whole unit, verbatim.
Map<String, dynamic>? qvTafsir(int surah, int ayah) {
  if (surah == 1 && ayah == 1) {
    return {
      'ok': true, 'surah': 1, 'ayah': 1,
      'sources': [
        _src('mukhtasar_bn', 'bn', _mukBn, _mukEn, _mukPub, '1.0.0',
            "১. আল্লাহর নামে কুরআন পাঠ শুরু করছি। তাঁরই সাহায্য কামনা করে ও তাঁরই নামের বরকত নিয়ে। বিসমিল্লাহর মধ্যে আল্লাহর তিনটি সুন্দরতম নাম রয়েছে: ক. “আল্লাহ” তথা সত্য মা’বূদ। এটি হলো আল্লাহ তা‘আলার সবিশেষ নাম। যা দিয়ে আল্লাহ ভিন্ন অন্য কারো নাম রাখা যায় না। খ. “আর-রাহমান” অর্থাৎ মহান দাতা, বিশাল দয়ার মালিক। তাঁর মূল সত্তাই তো দয়ালু। গ. “আর-রাহীম” অর্থাৎ পরম করুণাময়। তিনি সৃষ্টির যাকে চান দয়া করেন। এদের মধ্যে তাঁর মু’মিন বান্দারাও রয়েছেন।"),
        _src('saheeh_notes_en', 'en', 'ইংরেজি টীকা — Saheeh International',
            'English notes — Saheeh International', _sahPub, '1.1.2',
            "[2] Allāh is a proper name belonging only to the one Almighty God, Creator and Sustainer of the heavens and the earth and all that is within them, the Eternal and Absolute, to whom alone all worship is due.\n[3] Ar-Raḥmān and ar-Raḥeem are two names of Allāh derived from the word \"raḥmah\" (mercy) . In Arabic grammar both are intensive forms of \"merciful\" (i.e., extremely merciful) . A complimentary and comprehensive meaning is intended by using both together. Raḥmān is used only to describe Allāh, while raḥeem might be used to describe a person as well. The Prophet (ﷺ) was described in the Qur’ān as raḥeem. Raḥmān is above the human level (i.e., intensely merciful) . Since one usually understands intensity to be something of short duration, Allāh describes Himself also as raḥeem (i.e., continually merciful) . Raḥmān also carries a wider meaning - merciful to all creation. Justice is a part of this mercy. Raḥeem includes the concept of speciality - especially and specifically merciful to the believers. Forgiveness is a part of this mercy. In addition, Raḥmān is adjectival, referring to an attribute of Allāh and is part of His essence. Raḥeem is verbal, indicating what He does: i.e., bestowing and implementing mercy."),
      ],
      'shan_nuzul': const [],
      'shan_nuzul_rule': 'keyword_v1', 'shan_nuzul_review': 'under_review',
    };
  }
  if (surah == 80 && ayah == 1) {
    return {
      'ok': true, 'surah': 80, 'ayah': 1,
      'sources': [
        _src('zakaria_notes_bn', 'bn', 'বাংলা টীকা — আবু বকর যাকারিয়া',
            'Bengali notes — Abu Bakr Zakaria', _zakPub, '1.1.1',
            "<b> সূরা সম্পর্কিত তথ্য: </b>\n\nএ সূরাটি সাহাবী আবদুল্লাহ্ ইবন উম্মে মাকতুম রাদিয়াল্লাহু ‘আনহু এর সাথে বিশেষভাবে জড়িত। তাঁর মা উম্মে মাকতুম ছিলেন খাদীজা রাদিয়াল্লাহু ‘আনহার পিতা খুওয়াইলিদের সহোদর বোন। তিনি ছিলেন নবী সাল্লাল্লাহ আলাইহি ওয়া সাল্লামের শ্যালক। বংশ মর্যাদার দিক দিয়ে সমাজের সাধারণ শ্রেণীভুক্ত নন বরং অভিজাত বংশীয় ছিলেন। আবদুল্লাহ্ রাদিয়াল্লাহু ‘আনহু অন্ধ হওয়ার কারণে জানতে পারেননি যে, রাসূলুল্লাহ্ সাল্লাল্লাহু আলাইহি ওয়া সাল্লাম অন্যের সাথে আলোচনারত আছেন। তিনি মজলিসে প্রবেশ করেই রাসূলুল্লাহ্ সাল্লাল্লাহু আলাইহি ওয়া সাল্লামকে আওয়াজ দিতে শুরু করেন এবং বার বার আওয়াজ দেন। কোনো কোনো বর্ণনায় এসেছে যে, তিনি রাসূলুল্লাহ্ সাল্লাল্লাহু আলাইহি ওয়া সাল্লামকে কুরআন এর একটি আয়াতের পাঠ জিজ্ঞাসা করেন এবং সাথে সাথে জওয়াব দিতে পীড়াপীড়ি করেন। রাসূলুল্লাহ্ সাল্লাল্লাহু আলাইহি ওয়া সাল্লাম তখন মক্কার কাফের নেতৃবর্গের সাথে আলোচনায় মশগুল ছিলেন। এই নেতৃবর্গ ছিলেন ওতবা ইবন রবীয়া, আবু জাহল ইবন হিশাম এবং রাসূলুল্লাহ্ সাল্লাল্লাহু আলাইহি ওয়া সাল্লামের পিতৃব্য আব্বাস। তিনি তখনও মুসলিম হননি। এরূপ ক্ষেত্রে আবদুল্লাহ্ ইবন উম্মে মাকতুম রাদিয়াল্লাহু ‘আনহুর এভাবে কথা বলা এবং মামুলী প্রশ্ন নিয়ে তাৎক্ষনিক জওয়াবের জন্য পীড়াপীড়ি করা রাসূলুল্লাহ্ সাল্লাল্লাহু আলাইহি ওয়া সাল্লামের কাছে বিরক্তিকর ঠেকে। এই বিরক্তির প্রধান কারণ ছিল এই যে, আবদুল্লাহ্ রাদিয়াল্লাহু ‘আনহু পাক্কা মুসলিম ছিলেন এবং সদা সবৰ্দা মজলিসে উপস্থিত থাকতেন। তিনি এই প্রশ্ন অন্য সময়ও রাখতে পারতেন। তাঁর জওয়াব বিলম্বিত করার মধ্যে কোনো ধর্মীয় ক্ষতির আশংকা ছিল না। কিন্তু আল্লাহ্ তা'আলা নবীর এ বিরক্তি প্রকাশ পছন্দ করলেন না। তিনি আয়াত নাযিল করে তার প্রতিকার করেন। [দেখুন, তিরমিয়ী ৩৩২৮, ৩৩৩১, মুয়াত্তা মালেক ১/২০৩]\n\n___________________\n\n[১] عبس শব্দের অর্থ রুষ্টতা অবলম্বন করা এবং চোখে মুখে বিরক্তি প্ৰকাশ করা। تولى শব্দের অর্থ মুখ ফিরিয়ে নেয়া। [জালালাইন|"),
        _src('mukhtasar_bn', 'bn', _mukBn, _mukEn, _mukPub, '1.0.0',
            "১. রাসূল (সাল্লাল্লাহু আলাইহি ওয়াসাল্লাম) ভ্রƒ কুঞ্চিত করলেন এবং মুখ ফিরিয়ে নিলেন।"),
      ],
      'shan_nuzul': [
        {'source_id': 'zakaria_notes_bn', 'text': "<b> সূরা সম্পর্কিত তথ্য: </b>\n\nএ সূরাটি সাহাবী আবদুল্লাহ্ ইবন উম্মে মাকতুম রাদিয়াল্লাহু ‘আনহু এর সাথে বিশেষভাবে জড়িত। তাঁর মা উম্মে মাকতুম ছিলেন খাদীজা রাদিয়াল্লাহু ‘আনহার পিতা খুওয়াইলিদের সহোদর বোন। তিনি ছিলেন নবী সাল্লাল্লাহ আলাইহি ওয়া সাল্লামের শ্যালক। বংশ মর্যাদার দিক দিয়ে সমাজের সাধারণ শ্রেণীভুক্ত নন বরং অভিজাত বংশীয় ছিলেন। আবদুল্লাহ্ রাদিয়াল্লাহু ‘আনহু অন্ধ হওয়ার কারণে জানতে পারেননি যে, রাসূলুল্লাহ্ সাল্লাল্লাহু আলাইহি ওয়া সাল্লাম অন্যের সাথে আলোচনারত আছেন। তিনি মজলিসে প্রবেশ করেই রাসূলুল্লাহ্ সাল্লাল্লাহু আলাইহি ওয়া সাল্লামকে আওয়াজ দিতে শুরু করেন এবং বার বার আওয়াজ দেন। কোনো কোনো বর্ণনায় এসেছে যে, তিনি রাসূলুল্লাহ্ সাল্লাল্লাহু আলাইহি ওয়া সাল্লামকে কুরআন এর একটি আয়াতের পাঠ জিজ্ঞাসা করেন এবং সাথে সাথে জওয়াব দিতে পীড়াপীড়ি করেন। রাসূলুল্লাহ্ সাল্লাল্লাহু আলাইহি ওয়া সাল্লাম তখন মক্কার কাফের নেতৃবর্গের সাথে আলোচনায় মশগুল ছিলেন। এই নেতৃবর্গ ছিলেন ওতবা ইবন রবীয়া, আবু জাহল ইবন হিশাম এবং রাসূলুল্লাহ্ সাল্লাল্লাহু আলাইহি ওয়া সাল্লামের পিতৃব্য আব্বাস। তিনি তখনও মুসলিম হননি। এরূপ ক্ষেত্রে আবদুল্লাহ্ ইবন উম্মে মাকতুম রাদিয়াল্লাহু ‘আনহুর এভাবে কথা বলা এবং মামুলী প্রশ্ন নিয়ে তাৎক্ষনিক জওয়াবের জন্য পীড়াপীড়ি করা রাসূলুল্লাহ্ সাল্লাল্লাহু আলাইহি ওয়া সাল্লামের কাছে বিরক্তিকর ঠেকে। এই বিরক্তির প্রধান কারণ ছিল এই যে, আবদুল্লাহ্ রাদিয়াল্লাহু ‘আনহু পাক্কা মুসলিম ছিলেন এবং সদা সবৰ্দা মজলিসে উপস্থিত থাকতেন। তিনি এই প্রশ্ন অন্য সময়ও রাখতে পারতেন। তাঁর জওয়াব বিলম্বিত করার মধ্যে কোনো ধর্মীয় ক্ষতির আশংকা ছিল না। কিন্তু আল্লাহ্ তা'আলা নবীর এ বিরক্তি প্রকাশ পছন্দ করলেন না। তিনি আয়াত নাযিল করে তার প্রতিকার করেন। [দেখুন, তিরমিয়ী ৩৩২৮, ৩৩৩১, মুয়াত্তা মালেক ১/২০৩]\n\n___________________"},
      ],
      'shan_nuzul_rule': 'keyword_v1', 'shan_nuzul_review': 'under_review',
    };
  }
  return null;
}

/// TEST FIXTURE (not QF data): words of 1:1 with simple dictionary glosses.
Map<String, dynamic> qvQf(int surah, int ayah, {bool enabled = true, int reciter = 7}) =>
    !enabled
        ? {'ok': true, 'enabled': false}
        : {
            'ok': true, 'enabled': true, 'surah': surah, 'ayah': ayah,
            'translit': 'Bismi Allahi alrrahmani alrraheemi',
            'words': [
              {'pos': 1, 'ar': 'بِسْمِ', 'tr': "bis'mi", 'bn': 'নামে', 'en': '(In the) name'},
              {'pos': 2, 'ar': 'ٱللَّهِ', 'tr': 'l-lahi', 'bn': 'আল্লাহর', 'en': '(of) Allah'},
              {'pos': 3, 'ar': 'ٱلرَّحْمَـٰنِ', 'tr': 'l-raḥmāni', 'bn': 'পরম করুণাময়', 'en': 'the Most Gracious'},
              {'pos': 4, 'ar': 'ٱلرَّحِيمِ', 'tr': 'l-raḥīmi', 'bn': 'অতি দয়ালু', 'en': 'the Most Merciful'},
            ],
            'audio_url': 'https://verses.quran.foundation/Alafasy/mp3/001001.mp3',
            'reciter_id': reciter, 'max_age_days': 6, 'source': 'Quran Foundation',
          };

Map<String, dynamic> qvReciters({bool enabled = true}) => {
      'ok': true, 'enabled': enabled, 'default_id': 7,
      'items': enabled
          ? const [
              {'id': 7, 'name': 'Mishari Rashid al-`Afasy', 'style': ''},
              {'id': 2, 'name': 'AbdulBaset AbdulSamad', 'style': 'Murattal'},
            ]
          : const [],
    };

/// Lane 15 shape: {ok, surah, engine_version, label, source, items, bismillah_bn}.
Map<String, dynamic> qvPron(int surah) => {
      'ok': true, 'surah': surah, 'engine_version': 'test', 'label': 'under_review',
      'source': 'Tanzil Quran Text (Uthmani 1.1), CC BY 3.0',
      'items': [
        if (surah == 1) {'ayah': 1, 'bn': 'বিসমিল্লা-হির রাহমা-নির রাহীম', 'review': 'under_review'},
      ],
    };

/// FakeApi / gallery router for the quranview endpoints (null = not ours).
Map<String, dynamic>? fakeQuranViewGet(String path, {bool qfOn = true}) {
  final p = path.split('?').first.replaceFirst(RegExp(r'^/'), '');
  final rec = int.tryParse(Uri.parse(path).queryParameters['reciter'] ?? '') ?? 7;
  final seg = p.split('/');
  if (seg.isEmpty || seg[0] != 'quran' || seg.length < 2) return null;
  int n(int i) => seg.length > i ? (int.tryParse(seg[i]) ?? 0) : 0;
  switch (seg[1]) {
    case 'meaning':
      return qvMeaning(n(2));
    case 'tafsir':
      return qvTafsir(n(2), n(3)) ?? {'ok': false, 'reason': 'quranenc_unreachable'};
    case 'qf':
      return qvQf(n(2), n(3), enabled: qfOn, reciter: rec);
    case 'reciters':
      return qvReciters(enabled: qfOn);
    case 'pron':
      return qvPron(n(2));
  }
  return null;
}
