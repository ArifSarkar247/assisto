# quranread: generates app/lib/l10n/quran_learn_content.dart (our own lesson
# text). Run: python3 tool/qlgen/gen_quran_learn.py <quran-uthmani.txt> lib/l10n/quran_learn_content.dart
import sys, json

FA, KA, DA = 'َ', 'ِ', 'ُ'      # fatha kasra damma
FT, KT, DT = 'ً', 'ٍ', 'ٌ'      # tanween
SK, SH = 'ْ', 'ّ'                    # sukun, shadda
SUP_ALIF, SUB_ALIF, INV_DAMMA = 'ٰ', 'ٖ', 'ٗ'
BN_DIG = str.maketrans('0123456789', '০১২৩৪৫৬৭৮৯')

# makhraj groups (our own short wording)
G = {
 'jawf':  ('মুখ ও গলার ফাঁকা জায়গা (জাওফ)', 'the empty space of mouth and throat (jawf)'),
 'throat_deep': ('গলার একেবারে ভেতরের অংশ (বুকের কাছে)', 'the deepest part of the throat (near the chest)'),
 'throat_mid': ('গলার মাঝখান', 'the middle of the throat'),
 'throat_top': ('গলার উপরের অংশ (মুখের কাছে)', 'the top of the throat (near the mouth)'),
 'tongue_back': ('জিহ্বার গোড়া', 'the back of the tongue'),
 'tongue_mid': ('জিহ্বার মাঝখান ও উপরের তালু', 'the middle of the tongue and the hard palate'),
 'tongue_side': ('জিহ্বার পাশ ও উপরের মাড়ির দাঁত', 'the side of the tongue and the upper molars'),
 'tongue_tip': ('জিহ্বার আগা', 'the tip of the tongue'),
 'lips': ('দুই ঠোঁট', 'the lips'),
}

# (ar, name_ar, bn_name, en_name, bn_cons, latin, group, heavy, note_bn, note_en)
LETTERS = [
 ('ا','ألف','আলিফ','Alif','আ','a','jawf',False,
  'নিজের কোনো আওয়াজ নেই — যবর/যের/পেশ বা হামযা লাগলে পড়া যায়; যবরের পরে খালি আলিফ থাকলে আওয়াজ টেনে লম্বা হয় (মাদ্দ)।',
  'Has no sound of its own; it is read with a vowel mark or hamza. After a fatha a bare alif lengthens the sound (madd).'),
 ('ب','باء','বা','Ba','ব','b','lips',False,
  'দুই ঠোঁটের ভেজা অংশ একসাথে চেপে ছেড়ে দিন — বাংলা "ব"-এর মতো, কিন্তু পরিষ্কার।',
  'Press the wet inner parts of both lips together and release, like a clear "b".'),
 ('ت','تاء','তা','Ta','ত','t','tongue_tip',False,
  'জিহ্বার আগা উপরের সামনের দুই দাঁতের গোড়ায় লাগিয়ে হালকা "ত"।',
  'Tongue tip on the roots of the upper front teeth; a light "t".'),
 ('ث','ثاء','ছা','Tha','ছ','th','tongue_tip',False,
  'জিহ্বার আগা উপরের সামনের দাঁতের মাথায় আলতো লাগিয়ে বাতাস ছাড়ুন — ইংরেজি "think"-এর "th"। বাংলা "স" নয়।',
  'Tongue tip lightly on the edges of the upper front teeth with air flowing, as "th" in "think" - not an "s".'),
 ('ج','جيم','জীম','Jim','জ','j','tongue_mid',False,
  'জিহ্বার মাঝখান উপরের তালুতে লাগিয়ে — "জ"।',
  'Middle of the tongue against the hard palate - "j".'),
 ('ح','حاء','হা (হা-এ-হুত্তি)','Ha (deep)','হ','h','throat_mid',False,
  'গলার মাঝখান থেকে চাপা, ফিসফিসে "হ" — গলা একটু সরু করে বাতাস ছাড়ুন।',
  'From the middle of the throat: a breathy, narrowed "h".'),
 ('خ','خاء','খা','Kha','খ','kh','throat_top',True,
  'গলার উপরের অংশ থেকে খসখসে "খ" — মোটা আওয়াজ।',
  'From the top of the throat: a rough "kh" - a heavy letter.'),
 ('د','دال','দাল','Dal','দ','d','tongue_tip',False,
  'জিহ্বার আগা উপরের সামনের দাঁতের গোড়ায় — হালকা "দ"।',
  'Tongue tip on the roots of the upper front teeth - a light "d".'),
 ('ذ','ذال','যাল','Dhal','য','dh','tongue_tip',False,
  'জিহ্বার আগা উপরের সামনের দাঁতের মাথায় — ইংরেজি "this"-এর "th"; "জ" নয়।',
  'Tongue tip on the edges of the upper front teeth - as "th" in "this"; not a "j".'),
 ('ر','راء','রা','Ra','র','r','tongue_tip',False,
  'জিহ্বার আগা উপরের মাড়ির কাছে — "র"; যবর/পেশ থাকলে মোটা, যের থাকলে চিকন।',
  'Tongue tip near the upper gum - "r"; heavy with fatha or damma, light with kasra.'),
 ('ز','زاي','যা','Zay','য','z','tongue_tip',False,
  'জিহ্বার আগা নিচের সামনের দাঁতের কাছে — গুনগুনে "z" (ইংরেজি zoo)।',
  'Tongue tip near the lower front teeth - a buzzing "z" as in "zoo".'),
 ('س','سين','সীন','Sin','স','s','tongue_tip',False,
  'জিহ্বার আগা নিচের দাঁতের কাছে — শিসের মতো পাতলা "স"।',
  'Tongue tip near the lower front teeth - a thin, whistling "s".'),
 ('ش','شين','শীন','Shin','শ','sh','tongue_mid',False,
  'জিহ্বার মাঝখান তালুর দিকে — "শ"।',
  'Middle of the tongue towards the palate - "sh".'),
 ('ص','صاد','সোয়াদ','Sad','স','s','tongue_tip',True,
  'س-এর জায়গা থেকেই, কিন্তু মুখ ভরা মোটা "স"।',
  'Same place as س but heavy - a full-mouth "s".'),
 ('ض','ضاد','দোয়াদ','Dad','দ','d','tongue_side',True,
  'জিহ্বার পাশ উপরের মাড়ির দাঁতে লাগিয়ে — মোটা আওয়াজ; এটা শেখা কঠিন, শিক্ষকের কাছে শুনে নিন।',
  'Side of the tongue against the upper molars - heavy; hard to learn, hear it from a teacher.'),
 ('ط','طاء','তোয়া','Ta (heavy)','ত','t','tongue_tip',True,
  'ت-এর জায়গা থেকেই, কিন্তু জিহ্বা উঁচু করে মোটা "ত"।',
  'Same place as ت with the tongue raised - a heavy "t".'),
 ('ظ','ظاء','যোয়া','Dha (heavy)','য','dh','tongue_tip',True,
  'ذ-এর জায়গা থেকেই (জিহ্বার আগা দাঁতের মাথায়), কিন্তু মোটা।',
  'Same place as ذ (tongue tip on the teeth edges) but heavy.'),
 ('ع','عين','আইন','Ain','আ','‘','throat_mid',False,
  'গলার মাঝখান চেপে বের হওয়া আওয়াজ — বাংলায় এর মতো কোনো হরফ নেই; শিক্ষকের কাছে শুনে নিন।',
  'A squeezed sound from the middle of the throat - no Bangla letter matches it; hear it from a teacher.'),
 ('غ','غين','গাইন','Ghain','গ','gh','throat_top',True,
  'গলার উপরের অংশ থেকে গড়গড়ে "গ" — মোটা আওয়াজ।',
  'From the top of the throat: a gargling "gh" - heavy.'),
 ('ف','فاء','ফা','Fa','ফ','f','lips',False,
  'নিচের ঠোঁটের ভেতরের দিক উপরের সামনের দাঁতে লাগিয়ে — ইংরেজি "f"।',
  'Inner lower lip against the upper front teeth - an "f".'),
 ('ق','قاف','ক্বাফ','Qaf','ক্ব','q','tongue_back',True,
  'জিহ্বার একেবারে গোড়া নরম তালুতে — গভীর, মোটা "ক"।',
  'The very back of the tongue against the soft palate - a deep, heavy "q".'),
 ('ك','كاف','কাফ','Kaf','ক','k','tongue_back',False,
  'জিহ্বার গোড়া, ق-এর একটু সামনে — হালকা "ক"।',
  'Back of the tongue, a little in front of ق - a light "k".'),
 ('ل','لام','লাম','Lam','ল','l','tongue_tip',False,
  'জিহ্বার আগার দুই পাশ উপরের মাড়িতে — "ল"।',
  'Edges of the tongue tip on the upper gum - "l".'),
 ('م','ميم','মীম','Mim','ম','m','lips',False,
  'দুই ঠোঁটের শুকনো অংশ মিলিয়ে, নাক দিয়েও একটু আওয়াজ — "ম"।',
  'Dry parts of both lips together, with a little sound through the nose - "m".'),
 ('ن','نون','নূন','Nun','ন','n','tongue_tip',False,
  'জিহ্বার আগা উপরের মাড়িতে, নাক দিয়েও আওয়াজ — "ন"।',
  'Tongue tip on the upper gum, with sound through the nose - "n".'),
 ('و','واو','ওয়াও','Waw','ও','w','lips',False,
  'দুই ঠোঁট গোল করে, পুরো বন্ধ না করে — ইংরেজি "w"।',
  'Round both lips without closing them - "w".'),
 ('ه','هاء','হা (হা-এ-হাওয়াজ)','Ha (light)','হ','h','throat_deep',False,
  'গলার একেবারে ভেতর থেকে হালকা "হ"।',
  'From the deepest part of the throat - a light "h".'),
 ('ء','همزة','হামযা','Hamza','আ','’','throat_deep',False,
  'গলার একেবারে ভেতরে একটু থেমে ছেড়ে দেওয়া আওয়াজ — "আ"-এর শুরুর ধাক্কা।',
  'A short catch released from the deepest part of the throat.'),
 ('ي','ياء','ইয়া','Ya','ইয়','y','tongue_mid',False,
  'জিহ্বার মাঝখান তালুর দিকে — ইংরেজি "y"।',
  'Middle of the tongue towards the palate - "y".'),
]
VOWEL_START = {'ء', 'ع', 'ا'}   # Bangla hint starts with a vowel letter
# Bangla "w"/"y" syllables
WY = {'و': 'ওয়', 'ي': 'ইয়'}
MAT = {'a': 'া', 'i': 'ি', 'u': 'ু'}          # া ি ু
LONG = {'a': 'া', 'i': 'ী', 'u': 'ূ'}         # া ী ূ
IND = {'a': 'আ', 'i': 'ই', 'u': 'উ'}
IND_LONG = {'a': 'আ', 'i': 'ঈ', 'u': 'ঊ'}
HAS = '্'  # hasanta

L = {l[0]: l for l in LETTERS}
SLUG = dict(zip([l[0] for l in LETTERS], 'alif ba ta tha jim hha kha dal dhal ra zay sin shin sad dad tta zha ain ghain fa qaf kaf lam mim nun waw ha hamza ya'.split()))
assert len(SLUG) == 29

def bn_syl(ch, v, long=False):
    """Bangla hint for consonant ch + vowel v ('a','i','u')."""
    if ch in VOWEL_START:
        return (IND_LONG if long else IND)[v]
    if ch in WY:
        base = WY[ch]
        return base + (LONG if long else MAT)[v]
    return L[ch][4] + (LONG if long else MAT)[v]

def en_syl(ch, v, long=False):
    lat = L[ch][5]
    if ch == 'ا': lat = ''
    vv = {'a': 'a', 'i': 'i', 'u': 'u'}[v]
    if long: vv = {'a': 'aa', 'i': 'ee', 'u': 'oo'}[v]
    return lat + vv

def bn_coda(ch):  # consonant with hasanta at the end of a syllable
    if ch == 'ع': return '\''
    if ch in WY: return {'و': 'ও', 'ي': 'ই'}[ch]
    return L[ch][4] + HAS

def carrier(ch):
    return 'أ' if ch in ('ا', 'ء') else ch

out = []
def T(bn, en):
    return 'QlText(%s, %s)' % (json.dumps(bn, ensure_ascii=False), json.dumps(en, ensure_ascii=False))

def item(iid, ar=None, ref=None, say=None, note=None, check=None, heavy=False):
    parts = [json.dumps(iid)]
    if ar is not None: parts.append('ar: ' + json.dumps(ar, ensure_ascii=False))
    if ref is not None:
        parts.append('ref: QlRef(%s)' % ', '.join(str(x) for x in ref))
    if say is not None: parts.append('say: ' + T(*say))
    if note is not None: parts.append('note: ' + T(*note))
    if check is not None: parts.append('check: ' + json.dumps(check, ensure_ascii=False))
    if heavy: parts.append('heavy: true')
    return 'QlItem(%s)' % ', '.join(parts)

def lesson(lid, title, intro, items, grid=True):
    s = 'QlLesson(%s, %s, %s, [\n' % (json.dumps(lid), T(*title), T(*intro))
    s += ''.join('      %s,\n' % i for i in items)
    s += '    ]%s)' % ('' if grid else ', grid: false')
    return s

def stage(n, course, title, summary, lessons):
    s = '  QlStage(%d, %s, %s, %s, [\n' % (n, course, T(*title), T(*summary))
    s += ''.join('    %s,\n' % l for l in lessons)
    s += '  ]),\n'
    return s

def heavy_note(ch):
    return L[ch][7]

# ---------------------------------------------------------------- stage 1
def letter_items(chars):
    res = []
    for ch in chars:
        l = L[ch]
        g = G[l[6]]
        res.append(item('l_' + SLUG[ch],
                        ar=ch, check=l[1],
                        say=(l[2], l[3]),
                        note=('মাখরাজ: %s। %s' % (g[0], l[8]), 'Makhraj: %s. %s' % (g[1], l[9])),
                        heavy=l[7]))
    return res

order = [l[0] for l in LETTERS]
s1 = [
 lesson('letters1', ('হরফ ১ (ا থেকে خ)', 'Letters 1 (ا to خ)'),
  ('প্রতিটি হরফে ট্যাপ করে নাম আর কোথা থেকে আওয়াজ বের হয় (মাখরাজ) দেখুন। হরফের নাম জোরে বলুন — আরবি লেখা ডান থেকে বাঁয়ে পড়া হয়।',
   'Tap each letter to see its name and where its sound comes from (makhraj). Say the name aloud - Arabic is read from right to left.'),
  letter_items(order[0:7])),
 lesson('letters2', ('হরফ ২ (د থেকে ص)', 'Letters 2 (د to ص)'),
  ('ذ ز ظ — তিনটাই বাংলায় "য" মনে হয়, কিন্তু আওয়াজ আলাদা; ব্যাখ্যা মন দিয়ে পড়ুন।',
   'ذ ز ظ all sound like one Bangla letter, but they are different sounds - read each note carefully.'),
  letter_items(order[7:14])),
 lesson('letters3', ('হরফ ৩ (ض থেকে ق)', 'Letters 3 (ض to ق)'),
  ('"মোটা" চিহ্নের হরফগুলো (خ ص ض غ ط ق ظ) সবসময় মুখ ভরে মোটা করে পড়া হয়।',
   'Letters marked "heavy" (خ ص ض غ ط ق ظ) are always read with a full, heavy mouth.'),
  letter_items(order[14:21])),
 lesson('letters4', ('হরফ ৪ (ك থেকে ي)', 'Letters 4 (ك to ي)'),
  ('শেষ হরফগুলো। হামযা (ء) আলিফের মতো দেখালেও নিজে একটা হরফ।',
   'The last letters. Hamza (ء) is a letter of its own, even when it sits on an alif.'),
  letter_items(order[21:29])),
]

# ---------------------------------------------------------------- stage 2
H28 = [c for c in order if c != 'ء']   # alif row is written with hamza (أ)
def harakah_items(mark, v, prefix):
    res = []
    for ch in H28:
        res.append(item('%s_%s' % (prefix, SLUG[ch]),
                        ar=carrier(ch) + mark,
                        say=(bn_syl(ch, v), en_syl(ch, v)), heavy=heavy_note(ch)))
    return res
s2 = [
 lesson('fatha', ('যবর ( ـَ )', 'Fatha ( ـَ )'),
  ('হরফের উপরে ছোট বাঁকা দাগ = যবর। আওয়াজে "আ"-কার যোগ হয়: بَ = "বা"। খাটো করে, এক মাত্রায় পড়ুন।',
   'A small slanted stroke above = fatha. It adds a short "a": بَ = "ba". Keep it short (one count).'),
  harakah_items(FA, 'a', 'fa')),
 lesson('kasra', ('যের ( ـِ )', 'Kasra ( ـِ )'),
  ('হরফের নিচে ছোট দাগ = যের। "ই"-কার: بِ = "বি"।',
   'A small stroke below = kasra. It adds a short "i": بِ = "bi".'),
  harakah_items(KA, 'i', 'ka')),
 lesson('damma', ('পেশ ( ـُ )', 'Damma ( ـُ )'),
  ('হরফের উপরে ছোট "و"-এর মতো চিহ্ন = পেশ। "উ"-কার: بُ = "বু"। ঠোঁট একটু গোল করুন।',
   'A small و-like mark above = damma. It adds a short "u": بُ = "bu". Round the lips a little.'),
  harakah_items(DA, 'u', 'da')),
]

# ---------------------------------------------------------------- stage 3
def tanween_items(mark, v, prefix, chars):
    res = []
    for ch in chars:
        base = bn_syl(ch, v)
        res.append(item('%s_%s' % (prefix, SLUG[ch]),
                        ar=carrier(ch) + mark,
                        say=(base + 'ন', en_syl(ch, v) + 'n'), heavy=heavy_note(ch)))
    return res
T14a = ['ب','ت','ج','د','ر','س','ص','ط','ف','ق','ك','ل','م','ن']
T14b = ['ث','ح','خ','ذ','ز','ش','ض','ظ','ع','غ','و','ه','ي','ء']
s3 = [
 lesson('fathatan', ('দুই যবর ( ـً )', 'Fathatan ( ـً )'),
  ('দুই যবর = যবর + "ন"-এর আওয়াজ: بً = "বান"। এই "ন" লেখা থাকে না, কিন্তু পড়া হয় — একে তানবীন বলে।',
   'Two fathas = fatha + an "n" sound: بً = "ban". The "n" is not written but read - this is tanween.'),
  tanween_items(FT, 'a', 'ft', T14a)),
 lesson('kasratan', ('দুই যের ( ـٍ )', 'Kasratan ( ـٍ )'),
  ('দুই যের = "ইন": بٍ = "বিন"।', 'Two kasras = "in": بٍ = "bin".'),
  tanween_items(KT, 'i', 'kt', T14b)),
 lesson('dammatan', ('দুই পেশ ( ـٌ )', 'Dammatan ( ـٌ )'),
  ('দুই পেশ = "উন": بٌ = "বুন"।', 'Two dammas = "un": بٌ = "bun".'),
  tanween_items(DT, 'u', 'dt', T14a)),
]

# ---------------------------------------------------------------- stage 4
QALQ = set('قطبجد')
def sukun_items(chars):
    res = []
    for ch in chars:
        q = ch in QALQ
        res.append(item('sk_' + SLUG[ch],
                        ar='أَ' + ch + SK,
                        say=('আ' + bn_coda(ch), 'a' + L[ch][5]),
                        note=(('কলকলা হরফ: জযম থাকলে আওয়াজ একটু ধাক্কা দিয়ে ছাড়ুন।', 'Qalqalah letter: with a sukun, release it with a slight bounce.') if q else None),
                        heavy=heavy_note(ch)))
    return res
SK_CH = ['ب','ت','ج','د','ر','س','ش','ف','ق','ك','ل','م','ن','ه']
JW = [  # our own short practice syllables (common Arabic words)
 ('مِنْ','মিন্','min'), ('عَنْ','আন্','‘an'), ('قُلْ','কুল্','qul'), ('لَمْ','লাম্','lam'),
 ('هَلْ','হাল্','hal'), ('قَدْ','ক্বাদ্','qad'), ('بَلْ','বাল্','bal'), ('كُنْ','কুন্','kun'),
 ('لَكُمْ','লাকুম্','lakum'), ('رَبْ','রাব্','rab'), ('عَبْدُ','আবদু','‘abdu'), ('يَوْمَ','ইয়াওমা','yawma'),
]
s4 = [
 lesson('sukun1', ('জযম ( ـْ ) ১', 'Sukun ( ـْ ) 1'),
  ('হরফের উপরে ছোট গোল চিহ্ন = জযম (সুকুন)। ঐ হরফে কোনো স্বর নেই — আগের হরফের সাথে মিলে থেমে যায়: أَبْ = "আব্"।',
   'A small circle above = sukun. The letter has no vowel; it closes the syllable before it: أَبْ = "ab".'),
  sukun_items(SK_CH)),
 lesson('sukun2', ('জযম ২ — ছোট শব্দ', 'Sukun 2 - short words'),
  ('জযম দিয়ে ছোট শব্দ। আগে হরফে হরফে (হিজ্জে) পড়ুন, তারপর একসাথে।',
   'Short words with sukun. First spell letter by letter, then read them together.'),
  [item('jw%d' % i, ar=a, say=(b, e)) for i, (a, b, e) in enumerate(JW)]),
]

# ---------------------------------------------------------------- stage 5
def conj(ch):
    if ch == 'ق': return 'ক্ক'
    return L[ch][4] + HAS + L[ch][4]
SH_CH = ['ب','ت','ج','د','س','ش','ف','ك','ل','م','ن','ق']
def shadda_items():
    res = []
    for ch in SH_CH:
        gh = ch in 'من'
        res.append(item('sh_' + SLUG[ch],
                        ar='أَ' + ch + SH + FA,
                        say=('আ' + conj(ch) + MAT['a'], 'a' + L[ch][5] * 2 + 'a'),
                        note=(('গুন্নাহ: نّ ও مّ-এ নাক দিয়ে দুই মাত্রা গুনগুন করুন।', 'Ghunnah: hum through the nose for two counts on نّ and مّ.') if gh else None),
                        heavy=heavy_note(ch)))
    return res
def shadda3(ch):
    l = L[ch]
    return [item('sh3_%s_%s' % (SLUG[ch], v), ar=p + ch + SH + m,
                 say=(IND[v] + conj(ch) + MAT[v], {'a': 'a', 'i': 'i', 'u': 'u'}[v] + l[5] * 2 + v))
            for v, p, m in (('a', 'أَ', FA), ('i', 'إِ', KA), ('u', 'أُ', DA))]
s5 = [
 lesson('shadda1', ('তাশদীদ ( ـّ ) ১', 'Shadda ( ـّ ) 1'),
  ('ছোট "w"-এর মতো চিহ্ন = তাশদীদ। হরফটা দুবার পড়া হয় — প্রথমবার জযম দিয়ে আগের হরফের সাথে, তারপর নিজের স্বরে: أَبَّ = "আব্বা"।',
   'A small w-like mark = shadda. The letter is read twice - once closing the syllable before, then with its own vowel: أَبَّ = "abba".'),
  shadda_items()),
 lesson('shadda2', ('তাশদীদ ২ — যবর, যের, পেশ', 'Shadda 2 - with each vowel'),
  ('তাশদীদের সাথে তিন স্বর। نّ ও مّ-এ গুন্নাহ (নাকের আওয়াজ) মনে রাখুন।',
   'Shadda with the three vowels. Remember the ghunnah (nasal sound) on نّ and مّ.'),
  shadda3('ب') + shadda3('ل') + shadda3('م') + shadda3('ن')),
]

# ---------------------------------------------------------------- stage 6
MA = ['ب','ت','ج','د','ر','س','ق','ك','ل','م','ن','ه']
def madd_a():
    return [item('ma_' + SLUG[ch], ar=ch + FA + 'ا',
                 say=(bn_syl(ch, 'a', True) + ' —', en_syl(ch, 'a', True)), heavy=heavy_note(ch)) for ch in MA]
def madd_iu():
    res = []
    for ch in ['ب','ت','ج','ل','م','ن']:
        res.append(item('mi_' + SLUG[ch], ar=ch + KA + 'ي', say=(bn_syl(ch, 'i', True) + ' —', en_syl(ch, 'i', True))))
        res.append(item('mu_' + SLUG[ch], ar=ch + DA + 'و', say=(bn_syl(ch, 'u', True) + ' —', en_syl(ch, 'u', True))))
    return res
def standing():
    res = []
    for ch in ['ب','ت','ل','م','ن','ه']:
        l = L[ch]
        res.append(item('sa_' + SLUG[ch], ar=ch + SUP_ALIF, say=(bn_syl(ch, 'a', True) + ' —', en_syl(ch, 'a', True))))
        res.append(item('si_' + SLUG[ch], ar=ch + SUB_ALIF, say=(bn_syl(ch, 'i', True) + ' —', en_syl(ch, 'i', True))))
        res.append(item('su_' + SLUG[ch], ar=ch + INV_DAMMA, say=(bn_syl(ch, 'u', True) + ' —', en_syl(ch, 'u', True))))
    return res
def leen():
    res = []
    for ch in ['ب','خ','ق','ل','م','ع']:
        l = L[ch]
        res.append(item('ly_' + SLUG[ch], ar=ch + FA + 'ي' + SK, say=(bn_syl(ch, 'a') + 'ই', en_syl(ch, 'a') + 'y'), heavy=l[7]))
        res.append(item('lw_' + SLUG[ch], ar=ch + FA + 'و' + SK, say=(bn_syl(ch, 'a') + 'ও', en_syl(ch, 'a') + 'w'), heavy=l[7]))
    return res
LONGM = [((110,1,5,5),'জা — আ', 'jaaa-a'), ((1,7,8,8),'আদ্দোয়াল্লীন', 'ad-daaal-leen'),
         ((2,4,2,2),'বিমা —', 'bimaaa'), ((2,6,3,3),'সাওয়া — উন', 'sawaaa-un'), ((108,1,4,4),'ইন্না —', 'innaaa')]
s6 = [
 lesson('madd1', ('মাদ্দ — আলিফ দিয়ে টানা', 'Madd - lengthening with alif'),
  ('যবরের পরে খালি আলিফ থাকলে "আ" দুই মাত্রা টেনে পড়ুন (এক মাত্রা ≈ একটা আঙুল খোলার সময়): بَا = "বা —"।',
   'An empty alif after a fatha stretches the "a" to two counts (one count ≈ opening one finger): بَا = "baa".'),
  madd_a()),
 lesson('madd2', ('মাদ্দ — ي ও و দিয়ে', 'Madd - with ي and و'),
  ('যেরের পরে জযমহীন ي = "ঈ" টানা; পেশের পরে জযমহীন و = "ঊ" টানা — দুই মাত্রা।',
   'An unmarked ي after a kasra = long "ee"; an unmarked و after a damma = long "oo" - two counts.'),
  madd_iu()),
 lesson('madd3', ('খাড়া যবর, খাড়া যের, উল্টা পেশ', 'Standing fatha, kasra and damma'),
  ('কুরআনে ছোট খাড়া আলিফ ( ـٰ ), নিচে খাড়া যের ( ـٖ ) ও উল্টা পেশ ( ـٗ ) দেখা যায় — এগুলোও দুই মাত্রা টেনে পড়া হয়।',
   'The Quran uses a small standing alif ( ـٰ ), a standing kasra ( ـٖ ) and an inverted damma ( ـٗ ) - each is also stretched to two counts.'),
  standing()),
 lesson('madd4', ('লীন — নরম আওয়াজ', 'Leen - the soft sound'),
  ('যবরের পরে জযমওয়ালা ي বা و = নরম, দ্রুত "আই" / "আও"; টানবেন না (থামার সময় ছাড়া)।',
   'A ي or و with sukun after a fatha = a soft, quick "ay" / "aw"; do not stretch it (except when stopping).'),
  leen()),
 lesson('madd5', ('মাদ্দ চিহ্ন ( ـٓ ) — লম্বা টান', 'The maddah sign ( ـٓ ) - long stretch'),
  ('মাদ্দের হরফের উপরে ঢেউ-চিহ্ন থাকলে সাধারণত ৪–৫ মাত্রা, আর পরে তাশদীদ/জযম থাকলে ৬ মাত্রা টানা হয়। উদাহরণগুলো কুরআন থেকে (রেফারেন্স দেওয়া)।',
   'A wavy sign over a madd letter usually means 4-5 counts, and 6 counts when a shadda/sukun follows. The examples are from the Quran (reference shown).'),
  [item('mx%d' % i, ref=r, say=(b, e)) for i, (r, b, e) in enumerate(LONGM)]),
]

# ---------------------------------------------------------------- stage 7 (words, Quran refs)
W1 = [((112,1,4,4),'কুল্','qul'), ((112,1,5,5),'হুয়া','huwa'), ((112,1,7,7),'আহাদুন','ahadun'),
      ((112,3,0,0),'লাম্','lam'), ((112,3,1,1),'ইয়ালিদ্','yalid'), ((1,4,1,1),'ইয়াওমি','yawmi'),
      ((1,2,2,2),'রাব্বি','rabbi'), ((113,2,3,3),'খালাক্বা','khalaqa'), ((111,2,5,5),'কাসাবা','kasaba'),
      ((113,5,4,4),'হাসাদা','hasada'), ((108,2,0,0),'ফাসাল্লি','fasalli'), ((114,2,0,0),'মালিকি','maliki')]
W2 = [((1,2,0,0),'আলহামদু','al-hamdu','moon'), ((113,1,7,7),'আলফালাক্বি','al-falaqi','moon'),
      ((108,1,6,6),'আলকাওছারা','al-kawthara','moon'), ((114,1,7,7),'আন্নাসি','an-naasi','sun'),
      ((1,1,3,3),'আর্রাহীমি','ar-raheemi','sun'), ((112,2,1,1),'আস্সামাদু','as-samadu','sun'),
      ((1,4,2,2),'আদ্দীনি','ad-deeni','sun'), ((112,2,0,0),'আল্লাহু','allahu','allah')]
NOTE_AL = {
 'moon': ('চাঁদের হরফ: ل পড়া হয় (জযমসহ) — "আল"।', 'Moon letter: the ل is read (with sukun) - "al".'),
 'sun': ('সূর্যের হরফ: ل পড়া হয় না, পরের হরফে তাশদীদ — দুবার পড়ুন।', 'Sun letter: the ل is silent and the next letter has a shadda - read it twice.'),
 'allah': ('"আল্লাহ" শব্দের লাম: আগে যবর/পেশ থাকলে মোটা, যের থাকলে চিকন।', 'The lam of "Allah": heavy after a fatha/damma, light after a kasra.'),
}
s7 = [
 lesson('words1', ('শব্দ ১ — কুরআনের ছোট শব্দ', 'Words 1 - short Quran words'),
  ('এখন কুরআনের আসল শব্দ (লেখা Tanzil উসমানি পাঠ থেকে, নিচে সূরা:আয়াত)। আগে হরফে হরফে, তারপর একটানা পড়ুন। শব্দের শেষে থামলে শেষ স্বর বাদ দিয়ে জযম করে থামুন।',
   'Now real Quran words (text from the Tanzil Uthmani edition, sura:ayah shown). Spell first, then read in one go. When you stop at a word, drop its last vowel and stop with a sukun.'),
  [item('w1_%d' % i, ref=r, say=(b, e)) for i, (r, b, e) in enumerate(W1)]),
 lesson('words2', ('শব্দ ২ — আলিফ-লাম (ٱلْ)', 'Words 2 - the article ٱلْ'),
  ('শুরুর ٱ (হামযাতুল ওয়াসল) শব্দ দিয়ে পড়া শুরু করলে "আ" পড়া হয়, আগের শব্দের সাথে মিলিয়ে পড়লে পড়া হয় না। লাম চাঁদের হরফের আগে পড়া হয়, সূর্যের হরফের আগে পড়া হয় না।',
   'The opening ٱ (hamzat al-wasl) is read "a" when you start with the word and is silent when joined to the word before. The lam is read before moon letters and silent before sun letters.'),
  [item('w2_%d' % i, ref=r, say=(b, e), note=NOTE_AL[k]) for i, (r, b, e, k) in enumerate(W2)]),
]

# ---------------------------------------------------------------- stage 8 (ayat)
def ayat(sura, n, first_from=None):
    res = []
    for a in range(1, n + 1):
        if a == 1 and first_from is not None:
            res.append(item('a%d_%d' % (sura, a), ref=(sura, a, first_from)))
        else:
            res.append(item('a%d_%d' % (sura, a), ref=(sura, a)))
    return res
INTRO_AYAT = ('আয়াত ধীরে, শব্দে শব্দে পড়ুন; আয়াতের শেষে থামুন। "আমি পড়ি, যাচাই করুন" চাপলে ফোন শুনে দেখাবে কোন হরফ মিলল — এটা সহায়ক মাত্র, শিক্ষকের কাছে শুনিয়ে নিন।',
              'Read each ayah slowly, word by word, and stop at its end. "I read, check me" listens and shows which letters matched - only a helper; recite to a teacher too.')
s8 = [
 lesson('fatiha', ('সূরা আল-ফাতিহা (১)', 'Sura Al-Fatiha (1)'), INTRO_AYAT, ayat(1, 7), grid=False),
 lesson('ikhlas', ('সূরা আল-ইখলাস (১১২)', 'Sura Al-Ikhlas (112)'), INTRO_AYAT, ayat(112, 4, 4), grid=False),
 lesson('falaq', ('সূরা আল-ফালাক্ব (১১৩)', 'Sura Al-Falaq (113)'), INTRO_AYAT, ayat(113, 5, 4), grid=False),
 lesson('nas', ('সূরা আন-নাস (১১৪)', 'Sura An-Nas (114)'), INTRO_AYAT, ayat(114, 6, 4), grid=False),
 lesson('kawthar', ('সূরা আল-কাওসার (১০৮)', 'Sura Al-Kawthar (108)'), INTRO_AYAT, ayat(108, 3, 4), grid=False),
 lesson('asr', ('সূরা আল-আসর (১০৩)', 'Sura Al-Asr (103)'), INTRO_AYAT, ayat(103, 3, 4), grid=False),
]

# ---------------------------------------------------------------- stage 9 (basic tajweed)
def ex(iid, ref, bn, en):
    return item(iid, ref=ref, note=(bn, en))
s9 = [
 lesson('t_ghunnah', ('গুন্নাহ', 'Ghunnah'),
  ('نّ ও مّ (তাশদীদওয়ালা নূন ও মীম) পড়ার সময় নাক দিয়ে দুই মাত্রা গুনগুন আওয়াজ হয় — একে গুন্নাহ বলে।',
   'On نّ and مّ (nun and mim with shadda) a nasal hum is held for two counts - this is ghunnah.'),
  [ex('tg1', (103,2,0,0), 'نّ — গুন্নাহ, দুই মাত্রা।', 'نّ - ghunnah, two counts.'),
   ex('tg2', (114,1,7,7), 'ٱلنَّاسِ — নূনে তাশদীদ, গুন্নাহ।', 'ٱلنَّاسِ - nun with shadda, ghunnah.'),
   ex('tg3', (114,4,3,3), 'ٱلْخَنَّاسِ — নূনে তাশদীদ, গুন্নাহ।', 'ٱلْخَنَّاسِ - nun with shadda, ghunnah.'),
   ex('tg4', (108,1,4,4), 'إِنَّآ — গুন্নাহ, তারপর মাদ্দ।', 'إِنَّآ - ghunnah, then madd.')], grid=False),
 lesson('t_qalqalah', ('কলকলা', 'Qalqalah'),
  ('ق ط ب ج د — এই পাঁচ হরফে জযম থাকলে (বা শব্দের শেষে থামলে) আওয়াজ একটু ধাক্কা দিয়ে, প্রতিধ্বনির মতো ছাড়ুন। থামার সময় ধাক্কা একটু বেশি।',
   'ق ط ب ج د - when these five letters have a sukun (or you stop on them), release them with a slight bounce, like an echo. The bounce is stronger when stopping.'),
  [ex('tq1', (112,3,1,1), 'يَلِدْ — দাল-এ জযম: কলকলা।', 'يَلِدْ - dal with sukun: qalqalah.'),
   ex('tq2', (112,3,3,3), 'يُولَدْ — দাল-এ জযম: কলকলা।', 'يُولَدْ - dal with sukun: qalqalah.'),
   ex('tq3', (97,1,8,8), 'ٱلْقَدْرِ — মাঝখানের দাল-এ জযম: কলকলা।', 'ٱلْقَدْرِ - the middle dal has a sukun: qalqalah.'),
   ex('tq4', (113,1,7,7), 'ٱلْفَلَقِ — আয়াতের শেষে থামলে ق-এ বড় কলকলা।', 'ٱلْفَلَقِ - stopping at the ayah end gives a strong qalqalah on ق.'),
   ex('tq5', (111,1,7,7), 'لَهَبٍ — থামলে ب-এ কলকলা।', 'لَهَبٍ - stopping gives a qalqalah on ب.')], grid=False),
 lesson('t_noon', ('নূন সাকিন ও তানবীন', 'Nun sakinah and tanween'),
  ('জযমওয়ালা ن বা তানবীনের পরে কোন হরফ আছে তা দেখে চার নিয়ম: ইযহার (পরিষ্কার পড়া — গলার হরফ ء ه ع ح غ খ-এর আগে), ইদগাম (মিলিয়ে পড়া — ي ر م ل و ن-এর আগে), ইকলাব (ب-এর আগে "ম" হয়ে যায়), ইখফা (বাকি ১৫ হরফের আগে নাকে লুকিয়ে পড়া)।',
   'What follows a ن with sukun or a tanween decides four rules: izhar (clear - before the throat letters ء ه ع ح غ خ), idgham (merging - before ي ر م ل و ن), iqlab (becomes "m" before ب), ikhfa (hidden in the nose - before the other 15 letters).'),
  [ex('tn1', (106,4,5,6), 'مِّنْ خَوْفٍۭ — ইযহার: خ গলার হরফ, ن পরিষ্কার পড়ুন।', 'مِّنْ خَوْفٍۭ - izhar: خ is a throat letter, read the ن clearly.'),
   ex('tn2', (111,5,3,4), 'مِّن مَّسَدٍۭ — ইদগাম গুন্নাহসহ: ن মিশে যায় م-এ।', 'مِّن مَّسَدٍۭ - idgham with ghunnah: the ن merges into م.'),
   ex('tn3', (112,4,1,2), 'يَكُن لَّهُۥ — ইদগাম গুন্নাহ ছাড়া: ن মিশে যায় ل-এ।', 'يَكُن لَّهُۥ - idgham without ghunnah: the ن merges into ل.'),
   ex('tn4', (86,7,1,2), 'مِنۢ بَيْنِ — ইকলাব: ছোট م চিহ্ন, ن পড়া হয় "ম" গুন্নাহসহ।', 'مِنۢ بَيْنِ - iqlab: the small م sign; the ن is read as "m" with ghunnah.'),
   ex('tn5', (113,2,0,1), 'مِن شَرِّ — ইখফা: ن নাকে লুকিয়ে, দুই মাত্রা।', 'مِن شَرِّ - ikhfa: the ن is hidden in the nose, two counts.'),
   ex('tn6', (109,3,1,1), 'أَنتُمْ — ইখফা (একই শব্দের ভেতরে)।', 'أَنتُمْ - ikhfa (inside one word).')], grid=False),
 lesson('t_meem', ('মীম সাকিন', 'Mim sakinah'),
  ('জযমওয়ালা م-এর পরে ب এলে ঠোঁটে লুকিয়ে (ইখফা শাফাবি), م এলে মিলিয়ে গুন্নাহসহ (ইদগাম শাফাবি), অন্য হরফ এলে পরিষ্কার (ইযহার শাফাবি)।',
   'After a م with sukun: before ب it is hidden at the lips (ikhfa shafawi), before م it merges with ghunnah (idgham shafawi), before any other letter it is clear (izhar shafawi).'),
  [ex('tm1', (105,4,0,1), 'تَرْمِيهِم بِحِجَارَةٍ — ইখফা শাফাবি।', 'تَرْمِيهِم بِحِجَارَةٍ - ikhfa shafawi.'),
   ex('tm2', (106,4,1,2), 'أَطْعَمَهُم مِّن — ইদগাম শাফাবি, গুন্নাহ।', 'أَطْعَمَهُم مِّن - idgham shafawi, ghunnah.'),
   ex('tm3', (112,3,0,1), 'لَمْ يَلِدْ — ইযহার শাফাবি: م পরিষ্কার।', 'لَمْ يَلِدْ - izhar shafawi: the م is clear.')], grid=False),
 lesson('t_heavy', ('মোটা ও চিকন পড়া', 'Heavy and light letters'),
  ('খ ص ض غ ط ق ظ সবসময় মোটা। "আল্লাহ"-র লাম আগে যবর/পেশ থাকলে মোটা, যের থাকলে চিকন। বাকি হরফ চিকন।',
   'خ ص ض غ ط ق ظ are always heavy. The lam of "Allah" is heavy after a fatha/damma and light after a kasra. Other letters are light.'),
  [ex('th1', (112,2,0,0), 'ٱللَّهُ — শুরুতে "আল্লাহ": লাম মোটা।', 'ٱللَّهُ - starting with "Allah": heavy lam.'),
   ex('th2', (1,2,1,1), 'لِلَّهِ — আগে যের: লাম চিকন।', 'لِلَّهِ - kasra before it: light lam.'),
   ex('th3', (1,6,1,1), 'ٱلصِّرَٰطَ — ص ও ط মোটা।', 'ٱلصِّرَٰطَ - ص and ط are heavy.'),
   ex('th4', (1,7,5,5), 'ٱلْمَغْضُوبِ — غ ও ض মোটা।', 'ٱلْمَغْضُوبِ - غ and ض are heavy.')], grid=False),
 lesson('t_waqf', ('আয়াতের শেষে থামা', 'Stopping at the end of an ayah'),
  ('থামার সময় শেষ হরফের স্বর বাদ দিয়ে জযম করুন; দুই যবর হলে "আ" টেনে থামুন; ة থাকলে "হ" করে থামুন।',
   'When stopping, drop the last vowel and end with a sukun; with fathatan stop on a long "a"; a ة becomes "h".'),
  [ex('tw1', (112,2,1,1), 'ٱلصَّمَدُ — থামলে "আস্সামাদ্"।', 'ٱلصَّمَدُ - stopping: "as-samad".'),
   ex('tw2', (114,1,7,7), 'ٱلنَّاسِ — থামলে "আন্নাস্"।', 'ٱلنَّاسِ - stopping: "an-naas".'),
   ex('tw3', (110,2,6,6), 'أَفْوَاجًا — দুই যবরে থামলে "আফওয়াজা"।', 'أَفْوَاجًا - stopping on fathatan: "afwaajaa".'),
   ex('tw4', (104,1,7,7), 'لُّمَزَةٍ — ة-তে থামলে "লুমাযাহ্"।', 'لُّمَزَةٍ - stopping on ة: "lumazah".')], grid=False),
]

STAGES = [
 (1, 'kCourseQaida', ('হরফ ও মাখরাজ', 'Letters and makhraj'), ('২৯টি হরফ, নাম ও উচ্চারণের জায়গা', 'The 29 letters, their names and where each sound comes from'), s1),
 (2, 'kCourseQaida', ('হরকত (যবর, যের, পেশ)', 'Harakat (fatha, kasra, damma)'), ('ছোট স্বরচিহ্ন দিয়ে পড়া', 'Reading with the short vowel marks'), s2),
 (3, 'kCourseQaida', ('তানবীন', 'Tanween'), ('দুই যবর, দুই যের, দুই পেশ', 'Double vowel marks with an "n" sound'), s3),
 (4, 'kCourseQaida', ('জযম (সুকুন)', 'Jazm (sukun)'), ('স্বরহীন হরফ, ছোট শব্দ', 'Letters without a vowel; short words'), s4),
 (5, 'kCourseQaida', ('তাশদীদ', 'Tashdeed (shadda)'), ('দুবার পড়া হরফ, গুন্নাহ', 'Doubled letters and ghunnah'), s5),
 (6, 'kCourseQaida', ('মাদ্দ', 'Madd'), ('টেনে পড়া — ২, ৪–৫, ৬ মাত্রা', 'Lengthening - 2, 4-5 and 6 counts'), s6),
 (7, 'kCourseQaida', ('শব্দ', 'Words'), ('কুরআনের শব্দ পড়া', 'Reading Quran words'), s7),
 (8, 'kCourseNazera', ('আয়াত', 'Ayat'), ('ছোট সূরা পুরো পড়া', 'Reading short suras in full'), s8),
 (9, 'kCourseNazera', ('সহজ তাজবীদ', 'Basic tajweed'), ('গুন্নাহ, কলকলা, নূন ও মীম সাকিন, মোটা-চিকন, থামা', 'Ghunnah, qalqalah, nun and mim sakinah, heavy and light, stopping'), s9),
]

# ---- verify every Quran ref against the real file
U = {}
for line in open(sys.argv[1], encoding='utf-8'):
    if line.startswith('#') or '|' not in line: continue
    s, a, t = line.rstrip('\n').split('|')
    U[(int(s), int(a))] = t.split(' ')

import re
body = ''.join(stage(n, c, t, sm, ls) for n, c, t, sm, ls in STAGES)
for m in re.finditer(r'ref: QlRef\(([0-9, ]+)\)', body):
    p = [int(x) for x in m.group(1).split(',')]
    ws = U[(p[0], p[1])]
    if len(p) > 2:
        to = p[3] if len(p) > 3 else len(ws) - 1
        assert 0 <= p[2] <= to < len(ws), p
        print(p, ' '.join(ws[p[2]:to + 1]), file=sys.stderr)
    else:
        print(p, ' '.join(ws), file=sys.stderr)
ids = re.findall(r'QlItem\("([^"]+)"', body)
dup = {i for i in ids if ids.count(i) > 1}
assert not dup, dup
# Bangla text must use Bangla digits
for m in re.finditer(r'QlText\(("(?:[^"\\]|\\.)*")', body):
    assert not re.search(r'[0-9]', json.loads(m.group(1))), m.group(1)

hdr = '''// GENERATED by tool/qlgen/gen_quran_learn.py (quranread) - edit the generator, not
// this file. Learn-to-read-Quran lessons: OUR OWN explanations, written for
// Assisto; only the ORDER follows the Noorani Qaida method (letters + makhraj,
// harakat, tanween, jazm, tashdeed, madd, words, ayat, basic tajweed). No book
// pages were copied. Quran words / ayat are references (QlRef) - their text is
// read from the bundled, verbatim Tanzil Uthmani file. Lives under lib/l10n/
// because it carries Bangla text (lang gate). EXPERIMENTAL until a qualified
// Qari reviews it (owner action, FEATURE_CARD_QURAN_READING_BN.md).
import '../quran_learn/qaida_model.dart';

const List<QlStage> kQlStages = [
'''
open(sys.argv[2], 'w', encoding='utf-8').write(hdr + body + '];\n')
print('items', len(ids), file=sys.stderr)
