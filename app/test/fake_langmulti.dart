// langmulti: extracts of the REAL Arabic / Chinese / German / Spanish packs
// (backend/core/data/langpacks/*.json, answer keys stripped like public_pack)
// for widget tests and gallery shots. Regenerate from the packs; never hand-edit.
import 'dart:convert';

final Map<String, dynamic> _data = jsonDecode(r'''{
"lessons": {
"ar-s1": {
"id": "ar-s1",
"level": "W1",
"title_en": "Script 1: alif to raa",
"title_bn": "বর্ণমালা ১: আলিফ থেকে রা",
"items": [
{
"kind": "note",
"target": "ا   ـا",
"bn": "আরবি ডান থেকে বামে পড়ে। বেশিরভাগ অক্ষর শব্দের শুরু, মাঝে ও শেষে আকার বদলায়।",
"en": "Arabic is read right to left. Most letters change shape at the start, middle and end of a word."
},
{
"kind": "vocab",
"target": "ا   ـا",
"bn": "লম্বা 'আ' — পরের অক্ষরের সাথে জোড়ে না",
"en": "long 'aa' (also carries other vowels)",
"roman": "alif",
"note_bn": "উচ্চারণ: আ · অক্ষরের নাম: আলিফ",
"note_en": "Letter name: alif"
},
{
"kind": "vocab",
"target": "ب   بـ ـبـ ـب",
"bn": "বাংলা 'ব' — নিচে এক ফোঁটা",
"en": "b as in 'bag' (one dot below)",
"roman": "baa",
"note_bn": "উচ্চারণ: ব · অক্ষরের নাম: বা",
"note_en": "Letter name: baa"
},
{
"kind": "vocab",
"target": "ت   تـ ـتـ ـت",
"bn": "বাংলা 'ত' — উপরে দুই ফোঁটা",
"en": "t (two dots above)",
"roman": "taa",
"note_bn": "উচ্চারণ: ত · অক্ষরের নাম: তা",
"note_en": "Letter name: taa"
},
{
"kind": "vocab",
"target": "ث   ثـ ـثـ ـث",
"bn": "জিভ দাঁতের ফাঁকে রেখে নরম 'স' — উপরে তিন ফোঁটা",
"en": "'th' as in 'think'",
"roman": "thaa",
"note_bn": "উচ্চারণ: ছ/থ · অক্ষরের নাম: ছা",
"note_en": "Letter name: thaa"
},
{
"kind": "vocab",
"target": "ج   جـ ـجـ ـج",
"bn": "বাংলা 'জ'",
"en": "j as in 'job'",
"roman": "jiim",
"note_bn": "উচ্চারণ: জ · অক্ষরের নাম: জীম",
"note_en": "Letter name: jiim"
},
{
"kind": "vocab",
"target": "ح   حـ ـحـ ـح",
"bn": "গলার মাঝখান থেকে বাতাস ছেড়ে 'হ' — ফোঁটা নেই",
"en": "breathy h from the throat",
"roman": "Haa",
"note_bn": "উচ্চারণ: হ (গলা) · অক্ষরের নাম: হা",
"note_en": "Letter name: Haa"
},
{
"kind": "vocab",
"target": "خ   خـ ـخـ ـخ",
"bn": "গলায় ঘষা দিয়ে 'খ' — উপরে এক ফোঁটা",
"en": "rough 'kh' like clearing the throat",
"roman": "khaa",
"note_bn": "উচ্চারণ: খ (ঘর্ষণ) · অক্ষরের নাম: খা",
"note_en": "Letter name: khaa"
},
{
"kind": "vocab",
"target": "د   ـد",
"bn": "বাংলা 'দ' — পরের অক্ষরের সাথে জোড়ে না",
"en": "d",
"roman": "daal",
"note_bn": "উচ্চারণ: দ · অক্ষরের নাম: দাল",
"note_en": "Letter name: daal"
},
{
"kind": "vocab",
"target": "ذ   ـذ",
"bn": "জিভ দাঁতে ছুঁয়ে নরম 'য'",
"en": "'th' as in 'this'",
"roman": "dhaal",
"note_bn": "উচ্চারণ: য (দাঁতে জিভ) · অক্ষরের নাম: যাল",
"note_en": "Letter name: dhaal"
},
{
"kind": "vocab",
"target": "ر   ـر",
"bn": "বাংলা 'র' — একটু কাঁপিয়ে",
"en": "rolled r",
"roman": "raa",
"note_bn": "উচ্চারণ: র · অক্ষরের নাম: রা",
"note_en": "Letter name: raa"
}
]
},
"ar-x1": {
"id": "ar-x1",
"level": "W3",
"title_en": "Salary, passport and your rights",
"title_bn": "বেতন, পাসপোর্ট ও আপনার অধিকার",
"items": [
{
"kind": "note",
"target": "الراتب",
"bn": "পাসপোর্ট আপনার। সমস্যা হলে শান্তভাবে বলুন, আর বাংলাদেশ দূতাবাস বা শ্রম উইংয়ে যোগাযোগ করুন।",
"en": "Your passport belongs to you. If there is a problem, say it calmly and contact the Bangladesh embassy or labour wing."
},
{
"kind": "phrase",
"target": "الراتب",
"bn": "বেতন",
"en": "salary",
"roman": "ar-raatib",
"note_bn": "উচ্চারণ: আর-রাতিব",
"note_en": ""
},
{
"kind": "phrase",
"target": "ما استلمت الراتب من شهرين",
"bn": "দুই মাস বেতন পাইনি",
"en": "I have not received my salary for two months",
"roman": "ma istalamt ar-raatib min shahreen",
"note_bn": "উচ্চারণ: মা ইসতালামত আর-রাতিব মিন শাহরেইন",
"note_en": ""
},
{
"kind": "phrase",
"target": "العقد",
"bn": "চুক্তিপত্র",
"en": "the contract",
"roman": "al-'aqd",
"note_bn": "উচ্চারণ: আল-আকদ",
"note_en": ""
},
{
"kind": "phrase",
"target": "هذا مو في العقد",
"bn": "এটা চুক্তিতে নেই",
"en": "This is not in the contract",
"roman": "haadha mu fil-'aqd",
"note_bn": "উচ্চারণ: হাযা মু ফিল-আকদ",
"note_en": ""
},
{
"kind": "phrase",
"target": "الجواز / الإقامة",
"bn": "পাসপোর্ট / ইকামা",
"en": "passport / residence permit (iqama)",
"roman": "al-jawaaz / al-iqaama",
"note_bn": "উচ্চারণ: আল-জাওয়ায / আল-ইকামা",
"note_en": ""
},
{
"kind": "phrase",
"target": "أبي جوازي لو سمحت",
"bn": "দয়া করে আমার পাসপোর্ট দিন",
"en": "I want my passport, please",
"roman": "abi jawaazi law samaHt",
"note_bn": "উচ্চারণ: আবি জাওয়াযি লাও সামাহত",
"note_en": ""
},
{
"kind": "phrase",
"target": "ساعات إضافية",
"bn": "ওভারটাইম",
"en": "overtime hours",
"roman": "saa'aat iDaafiyya",
"note_bn": "উচ্চারণ: সাআত ইদাফিয়্যা",
"note_en": ""
},
{
"kind": "phrase",
"target": "أبي أكلّم السفارة",
"bn": "দূতাবাসের সাথে কথা বলতে চাই",
"en": "I want to speak to the embassy",
"roman": "abi akallim as-safaara",
"note_bn": "উচ্চারণ: আবি আকাল্লিম আস-সাফারা",
"note_en": ""
},
{
"kind": "phrase",
"target": "ساعدني لو سمحت",
"bn": "দয়া করে সাহায্য করুন",
"en": "Please help me",
"roman": "saa'idni law samaHt",
"note_bn": "উচ্চারণ: সাইদনি লাও সামাহত",
"note_en": ""
},
{
"kind": "phrase",
"target": "الكفيل",
"bn": "কফিল (নিয়োগকর্তা)",
"en": "the sponsor (employer)",
"roman": "al-kafiil",
"note_bn": "উচ্চারণ: আল-কাফীল",
"note_en": ""
}
],
"practice": [
"الراتب",
"ما استلمت الراتب من شهرين",
"العقد"
]
},
"zh-p1": {
"id": "zh-p1",
"level": "HSK1",
"title_en": "Pinyin and the four tones",
"title_bn": "পিনইন ও চার টোন",
"items": [
{
"kind": "note",
"target": "妈  mā",
"bn": "ভুল টোন মানে অন্য শব্দ: mǎ (ঘোড়া) ≠ mā (মা)। শুনে টোন-চিহ্ন দেখে নকল করুন।",
"en": "A wrong tone makes a different word: mǎ (horse) ≠ mā (mother). Listen, then copy the tone mark."
},
{
"kind": "vocab",
"target": "妈  mā",
"bn": "মা — টোন ১: উঁচু ও সমান",
"en": "mother — tone 1: high, level",
"roman": "mā",
"note_bn": "উচ্চারণ: মা (উঁচু, সমান)",
"note_en": ""
},
{
"kind": "vocab",
"target": "麻  má",
"bn": "শণ — টোন ২: প্রশ্নের মতো উঠে যায়",
"en": "hemp — tone 2: rising, like a question",
"roman": "má",
"note_bn": "উচ্চারণ: মা↗ (নিচ থেকে ওঠে)",
"note_en": ""
},
{
"kind": "vocab",
"target": "马  mǎ",
"bn": "ঘোড়া — টোন ৩: নেমে আবার ওঠে",
"en": "horse — tone 3: falls then rises",
"roman": "mǎ",
"note_bn": "উচ্চারণ: মা↘↗ (নেমে উঠে)",
"note_en": ""
},
{
"kind": "vocab",
"target": "骂  mà",
"bn": "বকা — টোন ৪: আদেশের মতো ঝটকায় নামে",
"en": "to scold — tone 4: sharp fall, like a command",
"roman": "mà",
"note_bn": "উচ্চারণ: মা↘ (ঝটকা দিয়ে নামে)",
"note_en": ""
},
{
"kind": "vocab",
"target": "你好  nǐ hǎo",
"bn": "হ্যালো — পরপর দুই টোন ৩: প্রথমটি টোন ২ হয়ে যায়",
"en": "hello — two 3rd tones: the first becomes rising",
"roman": "nǐ hǎo → ní hǎo",
"note_bn": "উচ্চারণ: নি হাও",
"note_en": ""
},
{
"kind": "vocab",
"target": "不是  bú shì",
"bn": "নয় — টোন ৪-এর আগে 不 হয় bú",
"en": "is not — 不 changes to bú before tone 4",
"roman": "bù → bú shì",
"note_bn": "উচ্চারণ: বু শি",
"note_en": ""
},
{
"kind": "vocab",
"target": "中国  Zhōngguó",
"bn": "চীন — zh, ch, sh: জিভ পেছনে বাঁকিয়ে",
"en": "China — zh, ch, sh: tongue curled back",
"roman": "Zhōngguó",
"note_bn": "উচ্চারণ: চোং-গুও",
"note_en": ""
},
{
"kind": "vocab",
"target": "谢谢  xièxie",
"bn": "ধন্যবাদ — x, q, j: ঠোঁট ছড়িয়ে",
"en": "thank you — x, q, j: lips spread",
"roman": "xièxie",
"note_bn": "উচ্চারণ: শিয়েশিয়ে",
"note_en": ""
},
{
"kind": "vocab",
"target": "去  qù",
"bn": "যাওয়া — এখানে u আসলে ü (ঠোঁট গোল 'ই')",
"en": "to go — the u here is ü (rounded 'ই')",
"roman": "qù",
"note_bn": "উচ্চারণ: চ্যু",
"note_en": ""
}
]
},
"de-a1-1": {
"id": "de-a1-1",
"level": "A1",
"title_en": "Hello! Introduce yourself",
"title_bn": "হ্যালো! নিজের পরিচয়",
"items": [
{
"kind": "note",
"target": "Hallo! / Guten Morgen!",
"bn": "অপরিচিত ও কাজে 'Sie' (আপনি), বন্ধু ও শিশুদের 'du' (তুমি)।",
"en": "Use 'Sie' with strangers and at work, 'du' with friends and children."
},
{
"kind": "phrase",
"target": "Hallo! / Guten Morgen!",
"bn": "হ্যালো! / সুপ্রভাত!",
"en": "Hello! / Good morning!",
"note_bn": "উচ্চারণ: হালো / গুটেন মর্গেন",
"note_en": ""
},
{
"kind": "phrase",
"target": "Ich heiße Karim.",
"bn": "আমার নাম করিম।",
"en": "My name is Karim.",
"note_bn": "উচ্চারণ: ইশ হাইসে করিম",
"note_en": ""
},
{
"kind": "phrase",
"target": "Ich komme aus Bangladesch.",
"bn": "আমি বাংলাদেশ থেকে এসেছি।",
"en": "I come from Bangladesh.",
"note_bn": "উচ্চারণ: ইশ কমে আউস বাংলাদেশ",
"note_en": ""
},
{
"kind": "phrase",
"target": "Wie geht es Ihnen?",
"bn": "আপনি কেমন আছেন? (ভদ্র রূপ)",
"en": "How are you? (formal)",
"note_bn": "উচ্চারণ: ভি গেট এস ইনেন? · বন্ধুদের: ভি গেটস?",
"note_en": "Friends: Wie geht's?"
},
{
"kind": "phrase",
"target": "Gut, danke. Und Ihnen?",
"bn": "ভালো, ধন্যবাদ। আপনি?",
"en": "Fine, thanks. And you?",
"note_bn": "উচ্চারণ: গুট, ডাঙ্কে। উন্ট ইনেন?",
"note_en": ""
},
{
"kind": "phrase",
"target": "Bitte. / Danke schön.",
"bn": "দয়া করে / স্বাগত। / অনেক ধন্যবাদ।",
"en": "Please / You're welcome. / Thank you very much.",
"note_bn": "উচ্চারণ: বিটে / ডাঙ্কে শ্যোন",
"note_en": ""
},
{
"kind": "phrase",
"target": "Entschuldigung!",
"bn": "মাফ করবেন!",
"en": "Excuse me! / Sorry!",
"note_bn": "উচ্চারণ: এন্টশুলডিগুং",
"note_en": ""
},
{
"kind": "phrase",
"target": "Ich verstehe das nicht.",
"bn": "আমি এটা বুঝিনি।",
"en": "I don't understand that.",
"note_bn": "উচ্চারণ: ইশ ফেয়াশটেয়ে দাস নিশট",
"note_en": ""
},
{
"kind": "phrase",
"target": "Sprechen Sie bitte langsam.",
"bn": "দয়া করে আস্তে বলুন।",
"en": "Please speak slowly.",
"note_bn": "উচ্চারণ: শপ্রেশেন জি বিটে লাংজাম",
"note_en": ""
},
{
"kind": "phrase",
"target": "Auf Wiedersehen! / Tschüss!",
"bn": "বিদায়! (ভদ্র / ঘরোয়া)",
"en": "Goodbye! (formal / casual)",
"note_bn": "উচ্চারণ: আউফ ভিডারজেয়েন / চুস",
"note_en": ""
}
],
"practice": [
"Hallo! / Guten Morgen!",
"Ich heiße Karim.",
"Ich komme aus Bangladesch."
]
}
},
"mocks": {
"es": {
"id": "es_style_1",
"title_en": "DELE FORMAT style (comprensión de lectura, comprensión auditiva, expresión e interacción escritas y orales) — original Assisto questions, never a real exam paper",
"title_bn": "DELE ফরম্যাটের ধাঁচ (পড়া, শোনা, লেখা, বলা) — Assisto-র নিজস্ব প্রশ্ন, কখনো আসল প্রশ্নপত্র নয়",
"format_en": "DELE FORMAT style (comprensión de lectura, comprensión auditiva, expresión e interacción escritas y orales) — original Assisto questions, never a real exam paper",
"format_bn": "DELE ফরম্যাটের ধাঁচ (পড়া, শোনা, লেখা, বলা) — Assisto-র নিজস্ব প্রশ্ন, কখনো আসল প্রশ্নপত্র নয়",
"minutes": 40,
"sections": [
{
"id": "reading",
"skill": "reading",
"title_en": "Reading and understanding (listening items are shown as text until phone-voice listening is enabled)",
"title_bn": "পড়া ও বোঝা (ফোনের কণ্ঠে শোনা চালু না হওয়া পর্যন্ত শোনার প্রশ্ন লেখা আকারে)",
"questions": [
{
"id": "es-mk-l1",
"type": "mcq",
"skill": "reading",
"level": "A1",
"text": "কোন প্ল্যাটফর্ম?\nEl tren a Sevilla sale de la vía siete.",
"text_en": "Which platform?\nEl tren a Sevilla sale de la vía siete.",
"text_bn": "কোন প্ল্যাটফর্ম?\nEl tren a Sevilla sale de la vía siete.",
"tts_text": "El tren a Sevilla sale de la vía siete.",
"options": [
"৩",
"৫",
"৭"
],
"options_en": [
"3",
"5",
"7"
],
"options_bn": [
"৩",
"৫",
"৭"
]
},
{
"id": "es-mk-l2",
"type": "mcq",
"skill": "reading",
"level": "A1",
"text": "সত্য না মিথ্যা: দোকান ১০টায় খোলে।\nLa tienda abre mañana a las nueve.",
"text_en": "True or false: the shop opens at 10.\nLa tienda abre mañana a las nueve.",
"text_bn": "সত্য না মিথ্যা: দোকান ১০টায় খোলে।\nLa tienda abre mañana a las nueve.",
"tts_text": "La tienda abre mañana a las nueve.",
"options": [
"সত্য",
"মিথ্যা"
],
"options_en": [
"True",
"False"
],
"options_bn": [
"সত্য",
"মিথ্যা"
]
},
{
"id": "es-mk-l3",
"type": "mcq",
"skill": "reading",
"level": "A2",
"text": "আলী কী আনবেন?\nSeñor Ali, traiga mañana el pasaporte y el contrato de trabajo.",
"text_en": "What must Ali bring?\nSeñor Ali, traiga mañana el pasaporte y el contrato de trabajo.",
"text_bn": "আলী কী আনবেন?\nSeñor Ali, traiga mañana el pasaporte y el contrato de trabajo.",
"tts_text": "Señor Ali, traiga mañana el pasaporte y el contrato de trabajo.",
"options": [
"পাসপোর্ট ও চুক্তিপত্র",
"টাকা",
"শুধু ছবি"
],
"options_en": [
"Passport and contract",
"Money",
"A photo only"
],
"options_bn": [
"পাসপোর্ট ও চুক্তিপত্র",
"টাকা",
"শুধু ছবি"
]
},
{
"id": "es-mk-l4",
"type": "mcq",
"skill": "reading",
"level": "B1",
"text": "সময়সূচি কেন বদলাল?\nAtención: cambia el horario del domingo porque Marta está de baja. Por favor, venid a las diez.",
"text_en": "Why does the schedule change?\nAtención: cambia el horario del domingo porque Marta está de baja. Por favor, venid a las diez.",
"text_bn": "সময়সূচি কেন বদলাল?\nAtención: cambia el horario del domingo porque Marta está de baja. Por favor, venid a las diez.",
"tts_text": "Atención: cambia el horario del domingo porque Marta está de baja. Por favor, venid a las diez.",
"options": [
"একজন সহকর্মী অসুস্থ",
"ছুটির দিন",
"রান্নাঘর বন্ধ"
],
"options_en": [
"A colleague is ill",
"It's a holiday",
"The kitchen is closed"
],
"options_bn": [
"একজন সহকর্মী অসুস্থ",
"ছুটির দিন",
"রান্নাঘর বন্ধ"
]
},
{
"id": "es-mk-l5",
"type": "mcq",
"skill": "reading",
"level": "B2",
"text": "পরামর্শদাতা কী বললেন?\nLes recomiendo empadronarse cuanto antes, porque lo piden para casi todos los trámites.",
"text_en": "What does the advisor recommend?\nLes recomiendo empadronarse cuanto antes, porque lo piden para casi todos los trámites.",
"text_bn": "পরামর্শদাতা কী বললেন?\nLes recomiendo empadronarse cuanto antes, porque lo piden para casi todos los trámites.",
"tts_text": "Les recomiendo empadronarse cuanto antes, porque lo piden para casi todos los trámites.",
"options": [
"যত দ্রুত সম্ভব ঠিকানা নিবন্ধন",
"এক বছর অপেক্ষা",
"পৌরসভা এড়ানো"
],
"options_en": [
"Register your address as soon as possible",
"Wait a year",
"Avoid the town hall"
],
"options_bn": [
"যত দ্রুত সম্ভব ঠিকানা নিবন্ধন",
"এক বছর অপেক্ষা",
"পৌরসভা এড়ানো"
]
},
{
"id": "es-mk-l6",
"type": "mcq",
"skill": "reading",
"level": "C1",
"text": "বক্তার মনোভাব কী?\nLa medida supone un avance, aunque habrá que ver si se aplica de verdad.",
"text_en": "What is the speaker's attitude?\nLa medida supone un avance, aunque habrá que ver si se aplica de verdad.",
"text_bn": "বক্তার মনোভাব কী?\nLa medida supone un avance, aunque habrá que ver si se aplica de verdad.",
"tts_text": "La medida supone un avance, aunque habrá que ver si se aplica de verdad.",
"options": [
"ইতিবাচক, তবে সংশয় আছে",
"পুরোপুরি বিপক্ষে",
"উদাসীন"
],
"options_en": [
"Positive with doubts",
"Totally against",
"Indifferent"
],
"options_bn": [
"ইতিবাচক, তবে সংশয় আছে",
"পুরোপুরি বিপক্ষে",
"উদাসীন"
]
},
{
"id": "es-mk-r1",
"type": "mcq",
"skill": "reading",
"level": "A2",
"text": "স্বাস্থ্যকেন্দ্রের নোটিশ। কখন বন্ধ?\nCentro de salud: lunes a viernes de 8:00 a 20:00. Sábados y domingos cerrado.",
"text_en": "Notice at a health centre. When is it closed?\nCentro de salud: lunes a viernes de 8:00 a 20:00. Sábados y domingos cerrado.",
"text_bn": "স্বাস্থ্যকেন্দ্রের নোটিশ। কখন বন্ধ?\nCentro de salud: lunes a viernes de 8:00 a 20:00. Sábados y domingos cerrado.",
"options": [
"সপ্তাহান্তে",
"সোমবার সকাল",
"প্রতি বিকেল"
],
"options_en": [
"Weekends",
"Monday morning",
"Every afternoon"
],
"options_bn": [
"সপ্তাহান্তে",
"সোমবার সকাল",
"প্রতি বিকেল"
]
},
{
"id": "es-mk-r2",
"type": "mcq",
"skill": "reading",
"level": "A2",
"text": "সত্য না মিথ্যা: এখানে ধূমপান করা যায়।\nProhibido fumar en todo el edificio.",
"text_en": "True or false: you may smoke here.\nProhibido fumar en todo el edificio.",
"text_bn": "সত্য না মিথ্যা: এখানে ধূমপান করা যায়।\nProhibido fumar en todo el edificio.",
"options": [
"সত্য",
"মিথ্যা"
],
"options_en": [
"True",
"False"
],
"options_bn": [
"সত্য",
"মিথ্যা"
]
},
{
"id": "es-mk-r3",
"type": "mcq",
"skill": "reading",
"level": "B1",
"text": "লুসিয়া কী চাইছেন?\nHola Rahim, ¿podríamos cambiar los turnos? Yo hago tu sábado y tú haces mi martes. ¡Gracias! Lucía",
"text_en": "What does Lucía ask?\nHola Rahim, ¿podríamos cambiar los turnos? Yo hago tu sábado y tú haces mi martes. ¡Gracias! Lucía",
"text_bn": "লুসিয়া কী চাইছেন?\nHola Rahim, ¿podríamos cambiar los turnos? Yo hago tu sábado y tú haces mi martes. ¡Gracias! Lucía",
"options": [
"শিফট বদল",
"বেতন বৃদ্ধি",
"বাসায় পৌঁছে দেওয়া"
],
"options_en": [
"To swap shifts",
"A pay rise",
"A lift home"
],
"options_bn": [
"শিফট বদল",
"বেতন বৃদ্ধি",
"বাসায় পৌঁছে দেওয়া"
]
},
{
"id": "es-mk-r4",
"type": "mcq",
"skill": "reading",
"level": "B1",
"text": "নাদিয়ার কোর্স কেন ফ্রি?\nCurso de español: 200 €. Gratuito para personas desempleadas inscritas. Nadia está inscrita como desempleada.",
"text_en": "Why is the course free for Nadia?\nCurso de español: 200 €. Gratuito para personas desempleadas inscritas. Nadia está inscrita como desempleada.",
"text_bn": "নাদিয়ার কোর্স কেন ফ্রি?\nCurso de español: 200 €. Gratuito para personas desempleadas inscritas. Nadia está inscrita como desempleada.",
"options": [
"বেকার হিসেবে নিবন্ধিত",
"ছাত্রী",
"অনলাইনে বুক করেছেন"
],
"options_en": [
"She is registered as unemployed",
"She is a student",
"She booked online"
],
"options_bn": [
"বেকার হিসেবে নিবন্ধিত",
"ছাত্রী",
"অনলাইনে বুক করেছেন"
]
},
{
"id": "es-mk-r5",
"type": "mcq",
"skill": "reading",
"level": "B2",
"text": "নিয়োগকর্তা কী দিচ্ছেন?\nBuscamos personal de cocina con nivel B1 de español. Ofrecemos alojamiento durante la temporada de verano.",
"text_en": "What does the employer offer?\nBuscamos personal de cocina con nivel B1 de español. Ofrecemos alojamiento durante la temporada de verano.",
"text_bn": "নিয়োগকর্তা কী দিচ্ছেন?\nBuscamos personal de cocina con nivel B1 de español. Ofrecemos alojamiento durante la temporada de verano.",
"options": [
"মৌসুমে থাকার ব্যবস্থা",
"বিনামূল্যে গাড়ি",
"দূর থেকে কাজ"
],
"options_en": [
"Accommodation for the season",
"A free car",
"Remote work"
],
"options_bn": [
"মৌসুমে থাকার ব্যবস্থা",
"বিনামূল্যে গাড়ি",
"দূর থেকে কাজ"
]
},
{
"id": "es-mk-r6",
"type": "mcq",
"skill": "reading",
"level": "C1",
"text": "কোন বাক্য লেখার সাথে মেলে?\nLa administración electrónica agiliza los trámites, siempre que los ciudadanos reciban apoyo.",
"text_en": "Which statement matches the text?\nLa administración electrónica agiliza los trámites, siempre que los ciudadanos reciban apoyo.",
"text_bn": "কোন বাক্য লেখার সাথে মেলে?\nLa administración electrónica agiliza los trámites, siempre que los ciudadanos reciban apoyo.",
"options": [
"সহায়তা পেলে তবেই অনলাইন প্রক্রিয়া কাজে দেয়",
"অনলাইন প্রক্রিয়া সবসময় কাজে দেয়",
"কাগজে দ্রুত"
],
"options_en": [
"Online procedures help only if people get support",
"Online procedures always help",
"Paper is faster"
],
"options_bn": [
"সহায়তা পেলে তবেই অনলাইন প্রক্রিয়া কাজে দেয়",
"অনলাইন প্রক্রিয়া সবসময় কাজে দেয়",
"কাগজে দ্রুত"
]
}
]
},
{
"id": "writing",
"skill": "writing",
"title_en": "Writing",
"title_bn": "লেখা",
"prompts": [
{
"id": "es-mk-w1",
"text": "বন্ধু Pablo-কে ছোট বার্তা (প্রায় ৪০ শব্দ): শনিবার আসতে পারবেন না, কেন, অন্য দিন প্রস্তাব।",
"text_en": "Write a short message (about 40 words) to your friend Pablo: you can't come on Saturday, say why, propose another day.",
"text_bn": "বন্ধু Pablo-কে ছোট বার্তা (প্রায় ৪০ শব্দ): শনিবার আসতে পারবেন না, কেন, অন্য দিন প্রস্তাব।",
"min_words": 25,
"max_words": 70,
"checks": [
{
"any": [
"hola",
"querido",
"querida"
],
"en": "Greeting",
"bn": "সম্বোধন"
},
{
"any": [
"sábado",
"sabado"
],
"en": "Mention Saturday",
"bn": "শনিবার বলা"
},
{
"any": [
"porque"
],
"en": "A reason (porque)",
"bn": "কারণ (porque)"
},
{
"any": [
"lunes",
"martes",
"miércoles",
"jueves",
"viernes",
"domingo"
],
"en": "Another day",
"bn": "অন্য দিন"
}
]
},
{
"id": "es-mk-w2",
"text": "বাড়িওয়ালাকে লিখুন (প্রায় ১২০ শব্দ): গরম পানির যন্ত্র নষ্ট, কবে থেকে, মেরামতের তারিখ চান, ভদ্র সমাপ্তি।",
"text_en": "Write to your landlord (about 120 words): the water heater is broken, since when, ask for a repair date, polite close.",
"text_bn": "বাড়িওয়ালাকে লিখুন (প্রায় ১২০ শব্দ): গরম পানির যন্ত্র নষ্ট, কবে থেকে, মেরামতের তারিখ চান, ভদ্র সমাপ্তি।",
"min_words": 90,
"max_words": 180,
"checks": [
{
"any": [
"estimado",
"estimada",
"buenos días"
],
"en": "Formal greeting",
"bn": "আনুষ্ঠানিক সম্বোধন"
},
{
"any": [
"calentador",
"agua caliente"
],
"en": "Name the problem",
"bn": "সমস্যার নাম"
},
{
"any": [
"desde"
],
"en": "Since when (desde)",
"bn": "কবে থেকে (desde)"
},
{
"any": [
"podría",
"podrían",
"le agradecería",
"por favor"
],
"en": "Polite request",
"bn": "ভদ্র অনুরোধ"
},
{
"any": [
"atentamente",
"saludos"
],
"en": "Formal close",
"bn": "আনুষ্ঠানিক সমাপ্তি"
}
]
}
]
},
{
"id": "speaking",
"skill": "speaking",
"title_en": "Speaking — read aloud, the phone checks",
"title_bn": "বলা — জোরে পড়ুন, ফোন যাচাই করবে",
"read_aloud": [
"Hola, me llamo Karim.",
"Soy de Bangladés y vivo en Madrid.",
"No entiendo, más despacio por favor.",
"Muchas gracias, hasta luego."
],
"speak_prompts": [
{
"id": "es-mk-s1",
"text_en": "Introduce yourself: name, country, city, job, languages.",
"text_bn": "নিজের পরিচয়: নাম, দেশ, শহর, কাজ, ভাষা।",
"seconds": 60,
"prep_seconds": 0,
"checks": [
{
"any": [
"llamo"
],
"en": "Name",
"bn": "নাম"
},
{
"any": [
"bangladés",
"bangladesh"
],
"en": "Country",
"bn": "দেশ"
},
{
"any": [
"vivo"
],
"en": "Where you live",
"bn": "কোথায় থাকেন"
},
{
"any": [
"trabajo",
"estudio",
"soy"
],
"en": "Job or studies",
"bn": "কাজ বা পড়াশোনা"
},
{
"any": [
"hablo"
],
"en": "Languages",
"bn": "ভাষা"
}
]
},
{
"id": "es-mk-s2",
"text_en": "Give your opinion for 1 minute: 'Working abroad — advantages and disadvantages'.",
"text_bn": "১ মিনিট মত দিন: 'বিদেশে কাজ — সুবিধা ও অসুবিধা'।",
"seconds": 90,
"prep_seconds": 60,
"checks": [
{
"any": [
"ventaja"
],
"en": "An advantage",
"bn": "সুবিধা"
},
{
"any": [
"desventaja",
"inconveniente"
],
"en": "A disadvantage",
"bn": "অসুবিধা"
},
{
"any": [
"en mi opinión",
"creo que",
"pienso que"
],
"en": "Your opinion",
"bn": "নিজের মত"
},
{
"any": [
"porque",
"por eso",
"así que"
],
"en": "A reason",
"bn": "কারণ"
}
]
}
]
}
],
"bands": [
{
"min_pct": 0,
"level": "A1"
},
{
"min_pct": 30,
"level": "A2"
},
{
"min_pct": 50,
"level": "B1"
},
{
"min_pct": 70,
"level": "B2"
},
{
"min_pct": 88,
"level": "C1"
}
]
},
"ar": {
"id": "ar_style_1",
"title_en": "Assisto work-Arabic skills check (no official exam exists for this)",
"title_bn": "Assisto কাজের আরবি দক্ষতা যাচাই (এর কোনো অফিসিয়াল পরীক্ষা নেই)",
"format_en": "Assisto work-Arabic skills check (no official exam exists for this)",
"format_bn": "Assisto কাজের আরবি দক্ষতা যাচাই (এর কোনো অফিসিয়াল পরীক্ষা নেই)",
"minutes": 20,
"sections": [
{
"id": "reading",
"skill": "reading",
"title_en": "Reading and understanding (listening items are shown as text until phone-voice listening is enabled)",
"title_bn": "পড়া ও বোঝা (ফোনের কণ্ঠে শোনা চালু না হওয়া পর্যন্ত শোনার প্রশ্ন লেখা আকারে)",
"questions": [
{
"id": "ar-mk-l1",
"type": "mcq",
"skill": "reading",
"level": "W1",
"text": "দাম কত?\nعشرين ريال",
"text_en": "What is the price?\nعشرين ريال",
"text_bn": "দাম কত?\nعشرين ريال",
"tts_text": "عشرين ريال",
"options": [
"১০",
"২০",
"৫০",
"১০০"
],
"options_en": [
"10",
"20",
"50",
"100"
],
"options_bn": [
"১০",
"২০",
"৫০",
"১০০"
]
},
{
"id": "ar-mk-l2",
"type": "mcq",
"skill": "reading",
"level": "W1",
"text": "লোকটি কী চান?\nمرة ثانية لو سمحت",
"text_en": "What does the person want?\nمرة ثانية لو سمحت",
"text_bn": "লোকটি কী চান?\nمرة ثانية لو سمحت",
"tts_text": "مرة ثانية لو سمحت",
"options": [
"আবার বলুন",
"বাসায় যাওয়া",
"পানি",
"ট্যাক্সি"
],
"options_en": [
"Say it again",
"Go home",
"Water",
"A taxi"
],
"options_bn": [
"আবার বলুন",
"বাসায় যাওয়া",
"পানি",
"ট্যাক্সি"
]
},
{
"id": "ar-mk-l3",
"type": "mcq",
"skill": "reading",
"level": "W2",
"text": "ড্রাইভার কোন দিকে যাবেন?\nروح سيدا، بعدين يمين",
"text_en": "Where should the driver go?\nروح سيدا، بعدين يمين",
"text_bn": "ড্রাইভার কোন দিকে যাবেন?\nروح سيدا، بعدين يمين",
"tts_text": "روح سيدا، بعدين يمين",
"options": [
"সোজা, তারপর ডানে",
"বামে, তারপর থামা",
"হোটেলে ফেরা",
"বিমানবন্দরে"
],
"options_en": [
"Straight, then right",
"Left, then stop",
"Back to the hotel",
"To the airport"
],
"options_bn": [
"সোজা, তারপর ডানে",
"বামে, তারপর থামা",
"হোটেলে ফেরা",
"বিমানবন্দরে"
]
},
{
"id": "ar-mk-l4",
"type": "mcq",
"skill": "reading",
"level": "W2",
"text": "আগে কী করবেন?\nلبس الخوذة أول",
"text_en": "What must you do first?\nلبس الخوذة أول",
"text_bn": "আগে কী করবেন?\nلبس الخوذة أول",
"tts_text": "لبس الخوذة أول",
"options": [
"হেলমেট পরা",
"পানি আনা",
"সুপারভাইজারকে ডাকা",
"দুপুরের খাবারে যাওয়া"
],
"options_en": [
"Wear the helmet",
"Bring water",
"Call the supervisor",
"Go to lunch"
],
"options_bn": [
"হেলমেট পরা",
"পানি আনা",
"সুপারভাইজারকে ডাকা",
"দুপুরের খাবারে যাওয়া"
]
},
{
"id": "ar-mk-l5",
"type": "mcq",
"skill": "reading",
"level": "W2",
"text": "ম্যাডাম কী বলছেন?\nاكوي الملابس اليوم",
"text_en": "What is madam asking?\nاكوي الملابس اليوم",
"text_bn": "ম্যাডাম কী বলছেন?\nاكوي الملابس اليوم",
"tts_text": "اكوي الملابس اليوم",
"options": [
"কাপড় ইস্ত্রি",
"রাতের রান্না",
"রান্নাঘর পরিষ্কার",
"বাচ্চাকে জাগানো"
],
"options_en": [
"Iron the clothes",
"Cook dinner",
"Clean the kitchen",
"Wake the child"
],
"options_bn": [
"কাপড় ইস্ত্রি",
"রাতের রান্না",
"রান্নাঘর পরিষ্কার",
"বাচ্চাকে জাগানো"
]
},
{
"id": "ar-mk-l6",
"type": "mcq",
"skill": "reading",
"level": "W3",
"text": "ওষুধ কতবার?\nمرتين باليوم بعد الأكل",
"text_en": "How often is the medicine?\nمرتين باليوم بعد الأكل",
"text_bn": "ওষুধ কতবার?\nمرتين باليوم بعد الأكل",
"tts_text": "مرتين باليوم بعد الأكل",
"options": [
"দিনে দুবার",
"দিনে একবার",
"দিনে তিনবার",
"শুধু রাতে"
],
"options_en": [
"Twice a day",
"Once a day",
"Three times a day",
"Only at night"
],
"options_bn": [
"দিনে দুবার",
"দিনে একবার",
"দিনে তিনবার",
"শুধু রাতে"
]
},
{
"id": "ar-mk-l7",
"type": "mcq",
"skill": "reading",
"level": "W3",
"text": "ম্যানেজার কী কথা দিলেন?\nالراتب الأسبوع الجاي إن شاء الله",
"text_en": "What did the manager promise?\nالراتب الأسبوع الجاي إن شاء الله",
"text_bn": "ম্যানেজার কী কথা দিলেন?\nالراتب الأسبوع الجاي إن شاء الله",
"tts_text": "الراتب الأسبوع الجاي إن شاء الله",
"options": [
"আগামী সপ্তাহে বেতন",
"নতুন ঘর",
"কাল ছুটি",
"দেশে যাওয়ার টিকিট"
],
"options_en": [
"Salary next week",
"A new room",
"A day off tomorrow",
"A ticket home"
],
"options_bn": [
"আগামী সপ্তাহে বেতন",
"নতুন ঘর",
"কাল ছুটি",
"দেশে যাওয়ার টিকিট"
]
},
{
"id": "ar-mk-r1",
"type": "mcq",
"skill": "reading",
"level": "W1",
"text": "বের হবেন কোন দরজা দিয়ে?",
"text_en": "Where do you go out?",
"text_bn": "বের হবেন কোন দরজা দিয়ে?",
"options": [
"مخرج",
"دخول",
"مغلق",
"رجال"
]
},
{
"id": "ar-mk-r2",
"type": "mcq",
"skill": "reading",
"level": "W1",
"text": "দরজায় এই সাইন। মানে কী?\nممنوع الدخول",
"text_en": "This sign is on a door. What does it mean?\nممنوع الدخول",
"text_bn": "দরজায় এই সাইন। মানে কী?\nممنوع الدخول",
"options": [
"প্রবেশ নিষেধ",
"খোলা",
"নারী",
"ওষুধের দোকান"
],
"options_en": [
"No entry",
"Open",
"Women",
"Pharmacy"
],
"options_bn": [
"প্রবেশ নিষেধ",
"খোলা",
"নারী",
"ওষুধের দোকান"
]
},
{
"id": "ar-mk-r3",
"type": "mcq",
"skill": "reading",
"level": "W1",
"text": "এটা কোন সংখ্যা?\n٥٧",
"text_en": "Which number is this?\n٥٧",
"text_bn": "এটা কোন সংখ্যা?\n٥٧",
"options": [
"৫৭",
"৭৫",
"৫২",
"২৭"
],
"options_en": [
"57",
"75",
"52",
"27"
],
"options_bn": [
"৫৭",
"৭৫",
"৫২",
"২৭"
]
},
{
"id": "ar-mk-r4",
"type": "mcq",
"skill": "reading",
"level": "W2",
"text": "কফিলের বার্তা। কাল কাজ কয়টায়?\nبكرة الشغل الساعة ٧ الصبح",
"text_en": "A message from your sponsor. When is work tomorrow?\nبكرة الشغل الساعة ٧ الصبح",
"text_bn": "কফিলের বার্তা। কাল কাজ কয়টায়?\nبكرة الشغل الساعة ٧ الصبح",
"options": [
"৬",
"৭",
"৮",
"৯"
],
"options_en": [
"6",
"7",
"8",
"9"
],
"options_bn": [
"৬",
"৭",
"৮",
"৯"
]
},
{
"id": "ar-mk-r5",
"type": "mcq",
"skill": "reading",
"level": "W2",
"text": "রাতে আঘাত পেলে কোথায় যাবেন?",
"text_en": "Where do you go if you are hurt at night?",
"text_bn": "রাতে আঘাত পেলে কোথায় যাবেন?",
"options": [
"طوارئ",
"مخرج",
"صيدلية",
"دخول"
]
},
{
"id": "ar-mk-r6",
"type": "mcq",
"skill": "reading",
"level": "W3",
"text": "কোন বাক্যে ওভারটাইমের টাকা চাওয়া হচ্ছে?",
"text_en": "Which sentence asks for overtime pay?",
"text_bn": "কোন বাক্যে ওভারটাইমের টাকা চাওয়া হচ্ছে?",
"options": [
"أبي فلوس الساعات الإضافية",
"أبي ماي بارد",
"وين الدوّار؟",
"الياهل نايم"
]
}
]
},
{
"id": "writing",
"skill": "writing",
"title_en": "Writing",
"title_bn": "লেখা",
"prompts": [
{
"id": "ar-mk-w1",
"text": "আরবিতে লিখুন: আপনার দেশ, আর আরবি অঙ্কে ফোন নম্বর। উদাহরণ: بنغلاديش — ٠٥٠١٢٣٤٥٦٧",
"text_en": "Write in Arabic: your country, and your phone number in Arabic digits. Example: بنغلاديش — ٠٥٠١٢٣٤٥٦٧",
"text_bn": "আরবিতে লিখুন: আপনার দেশ, আর আরবি অঙ্কে ফোন নম্বর। উদাহরণ: بنغلاديش — ٠٥٠١٢٣٤٥٦٧",
"min_words": 1,
"max_words": 20,
"checks": [
{
"any": [
"بنغلاديش",
"بنجلاديش"
],
"en": "Country written in Arabic",
"bn": "দেশের নাম আরবিতে"
},
{
"any": [
"٠",
"١",
"٢",
"٣",
"٤",
"٥",
"٦",
"٧",
"٨",
"٩"
],
"en": "Number in Arabic digits",
"bn": "আরবি অঙ্কে নম্বর"
}
]
}
]
},
{
"id": "speaking",
"skill": "speaking",
"title_en": "Speaking — read aloud, the phone checks",
"title_bn": "বলা — জোরে পড়ুন, ফোন যাচাই করবে",
"read_aloud": [
"السلام عليكم",
"أنا من بنغلاديش",
"ما أفهم، شوي شوي لو سمحت",
"شكراً جزيلاً"
],
"speak_prompts": [
{
"id": "ar-mk-s1",
"text_en": "Greet, say your name and that you are from Bangladesh.",
"text_bn": "সালাম দিন, নাম বলুন, বাংলাদেশ থেকে এসেছেন বলুন।",
"seconds": 30,
"prep_seconds": 0,
"checks": [
{
"any": [
"السلام",
"سلام"
],
"en": "Greeting",
"bn": "সালাম"
},
{
"any": [
"اسمي"
],
"en": "Your name (ismi…)",
"bn": "নাম (ইসমি…)"
},
{
"any": [
"بنغلاديش",
"بنجلاديش",
"بنغلادش"
],
"en": "Bangladesh",
"bn": "বাংলাদেশ"
}
]
},
{
"id": "ar-mk-s2",
"text_en": "Tell your supervisor you are sick and need a doctor.",
"text_bn": "সুপারভাইজারকে বলুন আপনি অসুস্থ, ডাক্তার দরকার।",
"seconds": 40,
"prep_seconds": 0,
"checks": [
{
"any": [
"مريض",
"مريضة",
"تعبان",
"تعبانة"
],
"en": "Say you are sick/tired",
"bn": "অসুস্থ/ক্লান্ত বলা"
},
{
"any": [
"دكتور",
"طبيب",
"مستشفى"
],
"en": "Ask for a doctor/hospital",
"bn": "ডাক্তার/হাসপাতাল চাওয়া"
}
]
}
]
}
],
"bands": [
{
"min_pct": 0,
"level": "W1"
},
{
"min_pct": 50,
"level": "W2"
},
{
"min_pct": 80,
"level": "W3"
}
]
}
}
}''') as Map<String, dynamic>;

Map<String, dynamic> langmultiLesson(String id) =>
    ((_data['lessons'] as Map)[id] as Map).cast<String, dynamic>();

Map<String, dynamic> langmultiMock(String lang) =>
    ((_data['mocks'] as Map)[lang] as Map).cast<String, dynamic>();
