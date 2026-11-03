import json, sys
K = [
 ('qlTitle', 'Learn to read Quran', 'কুরআন পড়া শিখি', []),
 ('qlAbout', 'Sources and notes', 'উৎস ও সতর্কতা', []),
 ('qlExperimentalTitle', 'Experimental', 'পরীক্ষামূলক', []),
 ('qlExperimentalBody', 'These lessons follow the Noorani method order and are written by Assisto. Until a qualified Qari reviews them, use them for practice and learn correct pronunciation from a teacher.', 'পাঠগুলো নূরানী পদ্ধতির ক্রমে, Assisto-র নিজের লেখা। একজন যোগ্য ক্বারি যাচাই না করা পর্যন্ত এগুলো অনুশীলনের জন্য — সঠিক উচ্চারণ শিক্ষকের কাছ থেকে শিখুন।', []),
 ('qlToday', 'Today {done} of {goal}', 'আজ {goal}টির মধ্যে {done}টি', ['done', 'goal']),
 ('qlStreak', '{n}-day streak - keep going!', 'টানা {n} দিন — চালিয়ে যান!', ['n']),
 ('qlNoStreak', 'A few letters a day is enough. Start today.', 'দিনে কয়েকটা হরফই যথেষ্ট। আজই শুরু করুন।', []),
 ('qlGoalTitle', 'Daily goal', 'দৈনিক লক্ষ্য', []),
 ('qlGoalItems', '{n} items a day', 'দিনে {n}টি', ['n']),
 ('qlGoalChange', 'Change daily goal', 'দৈনিক লক্ষ্য বদলান', []),
 ('qlGoalDone', "Today's goal is done. Well done!", 'আজকের লক্ষ্য পূর্ণ হয়েছে। খুব ভালো!', []),
 ('qlStart', 'Start with lesson 1', 'প্রথম পাঠ দিয়ে শুরু করুন', []),
 ('qlContinue', 'Continue: {lesson}', 'চালিয়ে যান: {lesson}', ['lesson']),
 ('qlAllDone', 'Every lesson is marked learned. Keep reading daily and recite to a teacher.', 'সব পাঠে "শিখেছি" দেওয়া হয়েছে। প্রতিদিন পড়ুন আর শিক্ষককে শুনিয়ে নিন।', []),
 ('qlCourseQaida', 'Qaida (stages 1-7)', 'কায়দা (ধাপ ১–৭)', []),
 ('qlCourseNazera', 'Nazera reading (stages 8-9)', 'নাজেরা পড়া (ধাপ ৮–৯)', []),
 ('qlCourseDone', 'Completed {date}', 'সম্পন্ন {date}', ['date']),
 ('qlCourseCompleted', 'Course completed! You can get an Assisto learning certificate.', 'কোর্স সম্পন্ন! আপনি Assisto শেখার সার্টিফিকেট নিতে পারবেন।', []),
 ('qlProgress', '{done} of {total} learned', '{total}টির মধ্যে {done}টি শেখা', ['done', 'total']),
 ('qlStageN', 'Stage {n} · {title}', 'ধাপ {n} · {title}', ['n', 'title']),
 ('qlTapLetter', 'Tap any item to see it large.', 'বড় করে দেখতে যেকোনোটিতে ট্যাপ করুন।', []),
 ('qlSay', 'Say: {text}', 'উচ্চারণ (আনুমানিক): {text}', ['text']),
 ('qlHeavy', 'Heavy letter', 'মোটা হরফ', []),
 ('qlPrev', 'Previous', 'আগেরটি', []),
 ('qlNext', 'Next', 'পরেরটি', []),
 ('qlQuranRef', 'Quran {ref}', 'কুরআন {ref}', ['ref']),
 ('qlListen', 'Listen', 'শুনুন', []),
 ('qlCheckMe', 'I read, check me', 'আমি পড়ি, যাচাই করুন', []),
 ('qlLearned', 'Learned', 'শিখেছি', []),
 ('qlMarkLearned', 'Mark as learned', 'শিখেছি চিহ্ন দিন', []),
 ('qlLessonDone', 'Lesson learned! Go on to the next one.', 'পাঠ শেখা হয়েছে! পরের পাঠে যান।', []),
 ('qlNextLessonNamed', 'Next lesson: {lesson}', 'পরের পাঠ: {lesson}', ['lesson']),
 ('qlBestCheck', 'Best helper check: {score}% letters matched', 'সহায়ক যাচাইয়ে সেরা: {score}% হরফ মিলেছে', ['score']),
 ('qlNoAudioTitle', 'Audio not available yet', 'অডিও এখনো নেই', []),
 ('qlNoAudioBody', 'We will only play a recitation from a Qari who has given permission or published it under an open licence. None is licensed yet, and we never use a machine voice for the Quran. Until then, listen to your teacher or a Qari you trust.', 'আমরা শুধু এমন ক্বারির তিলাওয়াত বাজাব যিনি অনুমতি দিয়েছেন বা খোলা লাইসেন্সে প্রকাশ করেছেন। এখনো কোনোটির লাইসেন্স নেই, আর কুরআনের জন্য আমরা কখনো যন্ত্রের কণ্ঠ ব্যবহার করি না। ততদিন আপনার শিক্ষক বা ভরসার ক্বারির কাছে শুনুন।', []),
 ('qlGotIt', 'Got it', 'বুঝেছি', []),
 ('qlHelperLabel', 'Helper - not a replacement for a teacher', 'সহায়ক — শিক্ষকের বিকল্প নয়', []),
 ('qlReciteTitle', 'Check my reading', 'আমার পড়া যাচাই', []),
 ('qlReciteHint', 'Tap Start and read the text above clearly and slowly.', '"শুরু করুন" চাপুন, তারপর উপরের লেখাটি পরিষ্কার ও ধীরে পড়ুন।', []),
 ('qlReciteLetterHint', 'For a single letter, say its name (for example "Ba").', 'একক হরফে হরফের নাম বলুন (যেমন "বা")।', []),
 ('qlReciteStart', 'Start', 'শুরু করুন', []),
 ('qlReciteStop', 'Stop', 'থামুন', []),
 ('qlReciteAgain', 'Try again', 'আবার চেষ্টা করুন', []),
 ('qlReciteListening', 'Listening...', 'শুনছি…', []),
 ('qlReciteHeard', 'The phone heard:', 'ফোন যা শুনেছে:', []),
 ('qlReciteScore', 'Letters matched: {score}%', 'হরফ মিলেছে: {score}%', ['score']),
 ('qlReciteGood', 'The letters match well. Ask a teacher to check your tajweed too.', 'হরফগুলো ভালো মিলেছে। তাজবীদ ঠিক আছে কিনা শিক্ষককেও শুনিয়ে নিন।', []),
 ('qlReciteClose', 'Close - some words were missed (shown in red). Read slowly and try again.', 'কাছাকাছি — কিছু শব্দ মেলেনি (লাল রঙে)। ধীরে পড়ে আবার চেষ্টা করুন।', []),
 ('qlReciteRetry', 'Many letters did not match. Read slowly, letter by letter, and try again.', 'অনেক হরফ মেলেনি। ধীরে, হরফে হরফে পড়ে আবার চেষ্টা করুন।', []),
 ('qlReciteLimits', 'The phone compares letters only. It cannot judge vowel marks, madd length, ghunnah or makhraj - a teacher can.', 'ফোন শুধু হরফ মেলায়। হরকত, মাদ্দের দৈর্ঘ্য, গুন্নাহ বা মাখরাজ সে বুঝতে পারে না — শিক্ষক পারেন।', []),
 ('qlReciteNoArabic', "This phone's voice typing has no Arabic. Add it: Settings > System > Languages > On-screen keyboard > Gboard > Voice typing > Languages > Arabic.", 'এই ফোনের ভয়েস টাইপিং-এ আরবি নেই। যোগ করুন: সেটিংস > সিস্টেম > ভাষা > অন-স্ক্রিন কীবোর্ড > Gboard > ভয়েস টাইপিং > ভাষা > আরবি।', []),
 ('qlReciteNoCheck', 'This item has no letter the phone can compare (alif / hamza) - read it to your teacher.', 'এতে ফোনের মেলানোর মতো হরফ নেই (আলিফ / হামযা) — শিক্ষককে পড়ে শোনান।', []),
 ('qlWordOk', 'matched', 'মিলেছে', []),
 ('qlWordMissed', 'not matched', 'মেলেনি', []),
 ('qlOpenSettings', 'Open settings', 'সেটিংস খুলুন', []),
 ('qlDone', 'Done', 'শেষ', []),
 ('qlLoadFailed', 'Could not open the Quran text on this phone. Please try again.', 'ফোনে কুরআনের লেখা খোলা গেল না। আবার চেষ্টা করুন।', []),
 ('qlRetry', 'Try again', 'আবার চেষ্টা করুন', []),
 ('qlTanzilCredit', 'Quran text: Tanzil Project (tanzil.net), Uthmani, CC BY 3.0, unchanged.', 'কুরআনের লেখা: Tanzil Project (tanzil.net), উসমানি, CC BY ৩.০, অপরিবর্তিত।', []),
 ('qlTanzilNotice', 'Tanzil notice (kept unchanged)', 'Tanzil-এর নোটিশ (হুবহু)', []),
 ('qlOpenTanzil', 'Open tanzil.net', 'tanzil.net খুলুন', []),
 ('qlAboutMethod', 'Lesson order follows the Noorani Qaida method (letters and makhraj, harakat, tanween, jazm, tashdeed, madd, words, ayat, basic tajweed) in the simple adult-learning style used in Bangladesh. Every explanation is written by Assisto - no book pages are copied.', 'পাঠের ক্রম নূরানী কায়দার পদ্ধতি অনুযায়ী (হরফ ও মাখরাজ, হরকত, তানবীন, জযম, তাশদীদ, মাদ্দ, শব্দ, আয়াত, সহজ তাজবীদ), বাংলাদেশের বড়দের সহজ শেখার ধাঁচে। সব ব্যাখ্যা Assisto-র নিজের লেখা — কোনো বইয়ের পাতা কপি করা হয়নি।', []),
 ('qlAboutText', "Quran words and ayat come from the Tanzil Quran Text (Uthmani), Tanzil Project, CC BY 3.0, shown unchanged. It follows the Madinah mushaf of the King Fahd Complex, riwayah Hafs 'an 'Asim.", 'কুরআনের শব্দ ও আয়াত Tanzil Quran Text (উসমানি) থেকে — Tanzil Project, CC BY ৩.০, অপরিবর্তিত। এটি বাদশাহ ফাহাদ কমপ্লেক্সের মদিনা মুসহাফ অনুযায়ী, রিওয়ায়াত হাফস আন আসিম।', []),
 ('qlAboutFont', 'Arabic font: Amiri Quran (SIL Open Font License 1.1).', 'আরবি ফন্ট: Amiri Quran (SIL Open Font License ১.১)।', []),
 ('qlAboutAudio', 'Audio: none yet. Only a recitation by a Qari with written permission or an open licence will be added - never a machine voice.', 'অডিও: এখনো নেই। শুধু লিখিত অনুমতি বা খোলা লাইসেন্সসহ ক্বারির তিলাওয়াত যোগ হবে — যন্ত্রের কণ্ঠ কখনো নয়।', []),
 ('qlAboutVoice', '"I read, check me" uses your phone\'s own speech service (for example Google). Assisto keeps no recording.', '"আমি পড়ি, যাচাই করুন" আপনার ফোনের নিজের ভয়েস-চেনা সেবা (যেমন Google) ব্যবহার করে। Assisto কোনো রেকর্ড রাখে না।', []),
 ('qlAboutPron', 'Bangla pronunciation hints are approximate - Arabic has sounds that Bangla letters cannot show.', 'বাংলায় লেখা উচ্চারণ আনুমানিক — আরবির কিছু আওয়াজ বাংলা হরফে লেখা যায় না।', []),
 ('qlFreeNoAds', 'Core learning is free. No ads.', 'মূল শেখা ফ্রি। কোনো বিজ্ঞাপন নেই।', []),
]
en, bn = {}, {}
for k, e, b, ph in K:
    en[k] = e
    meta = {'description': 'quranread: learn to read Quran'}
    if ph:
        meta['placeholders'] = {p: {'type': 'String'} for p in ph}
    en['@' + k] = meta
    bn[k] = b
    import re
    assert set(re.findall(r'\{(\w+)\}', e)) == set(ph) == set(re.findall(r'\{(\w+)\}', b)), k
    assert not re.search(r'[0-9]', b) or k in (), (k, b)
json.dump({'en': en, 'bn': bn}, open(sys.argv[1], 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
print(len(K))
