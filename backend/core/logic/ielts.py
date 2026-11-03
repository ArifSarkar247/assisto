"""
ielts.py — the deterministic, key-free engine behind Assisto's IELTS practice
(Language Partner, owner PART 2, flag `ielts_prep`).

PURE like language_partner.py: no Django, no DB, no network, no clock, no AI.
The AI band-estimate layer lives in core/ielts_views.py and only runs when a
key exists AND the learner chooses to spend credits.

CONTENT POLICY (owner rule): every prompt, passage, question and sentence
below was written for Assisto. Nothing is copied from Cambridge, IDP or the
British Council. The IELTS *format* (Speaking Parts 1-3, Writing Tasks 1-2,
True/False/Not Given) and the names of the four public band-descriptor
criteria are public knowledge. Listening needs licensed audio we do not have,
so we link the official free practice pages instead (OFFICIAL_LINKS).

HONESTY: nothing here produces an IELTS band. The key-free checks measure
things that can be counted (words, paragraphs, linking words, repetition,
words per minute, filler words, how many target words the phone's speech
recogniser heard) and say so. Every result carries `estimate=True` and the
UI shows "practice estimate — not an official band".

PRONUNCIATION: `align_words(target, heard)` aligns the target sentence with
the speech-to-text transcript word by word (Levenshtein on word tokens, with
a backtrace) and marks each target word ok / sub / miss. It is an estimate of
"how much of the sentence the phone understood", not phoneme analysis. The
app's Dart mirror (ielts_engine.dart) must give identical results; the shared
vectors are pinned in tests_p2lang.py and test/ielts_engine_test.dart.
"""
import re

ESTIMATE_LABEL = {
    "en": "Practice estimate — not an official IELTS band.",
    "bn": "অনুশীলনের অনুমান — অফিসিয়াল IELTS ব্যান্ড নয়।",
}

# Public band-descriptor criteria (names only — published openly by IELTS).
WRITING_CRITERIA = ("task", "coherence", "lexical", "grammar")
SPEAKING_CRITERIA = ("fluency", "lexical", "grammar", "pronunciation")

OFFICIAL_LINKS = [
    {"id": "bc_free", "org": "British Council",
     "url": "https://takeielts.britishcouncil.org/take-ielts/prepare",
     "en": "Free official practice tests (Listening, Reading, Writing, Speaking)",
     "bn": "অফিসিয়াল ফ্রি প্র্যাকটিস টেস্ট (Listening, Reading, Writing, Speaking)"},
    {"id": "idp_prepare", "org": "IDP",
     "url": "https://ielts.idp.com/prepare",
     "en": "IDP free preparation material and practice tests",
     "bn": "IDP-র ফ্রি প্রস্তুতি উপকরণ ও প্র্যাকটিস টেস্ট"},
    {"id": "ielts_org", "org": "IELTS",
     "url": "https://ielts.org",
     "en": "Official IELTS site — test format and public band descriptors",
     "bn": "অফিসিয়াল IELTS সাইট — পরীক্ষার ধরন ও পাবলিক ব্যান্ড ডেসক্রিপ্টর"},
]

# ------------------------------------------------------------- speaking
SPEAKING_P1 = [
    {"id": "p1_home", "topic_en": "Your home town", "topic_bn": "আপনার নিজের এলাকা",
     "questions": ["Where did you grow up?",
                   "What do you like most about that place?",
                   "Has your area changed much in recent years?",
                   "Would you like to live there in the future? Why?"]},
    {"id": "p1_study", "topic_en": "Work or study", "topic_bn": "কাজ বা পড়াশোনা",
     "questions": ["Do you work or are you a student?",
                   "What do you enjoy about your work or studies?",
                   "Is there anything you would like to change about it?",
                   "What do you plan to do in the next few years?"]},
    {"id": "p1_food", "topic_en": "Food", "topic_bn": "খাবার",
     "questions": ["What kind of food do you usually eat at home?",
                   "Do you prefer cooking or eating out?",
                   "Is there a dish from your region you would recommend to visitors?",
                   "Have your eating habits changed since you were a child?"]},
    {"id": "p1_phone", "topic_en": "Phones and apps", "topic_bn": "ফোন ও অ্যাপ",
     "questions": ["How much time do you spend on your phone each day?",
                   "Which app do you use the most?",
                   "Do you think people use phones too much?",
                   "Did you learn to use a phone easily?"]},
    {"id": "p1_rain", "topic_en": "Rain and weather", "topic_bn": "বৃষ্টি ও আবহাওয়া",
     "questions": ["Do you like rainy days?",
                   "What do people in your area do during the rainy season?",
                   "Which season do you like best?",
                   "Does the weather change your mood?"]},
]

SPEAKING_P2 = [
    {"id": "p2_helped", "title": "Describe a time you helped a member of your family.",
     "bullets": ["who you helped", "when it happened", "what you did",
                 "and explain how you felt afterwards."],
     "p3": ["Should children help with work at home? Why?",
            "How has the role of the family changed in your country?",
            "Do people help their neighbours less than in the past?"]},
    {"id": "p2_place", "title": "Describe a place in your country you would like to visit.",
     "bullets": ["where it is", "how you know about it", "what you would do there",
                 "and explain why you want to go there."],
     "p3": ["Why do people enjoy travelling within their own country?",
            "How can tourism affect a small town?",
            "Should historic places charge visitors an entry fee?"]},
    {"id": "p2_skill", "title": "Describe a skill you learned outside school.",
     "bullets": ["what the skill is", "who helped you learn it", "how long it took",
                 "and explain how it has been useful to you."],
     "p3": ["Which skills are not taught well in schools?",
            "Is it better to learn from a teacher or from the internet?",
            "Will people need different skills in twenty years?"]},
    {"id": "p2_app", "title": "Describe an app or website that is useful to you.",
     "bullets": ["what it is", "how you found it", "what you use it for",
                 "and explain why it is useful."],
     "p3": ["Do older people find technology difficult? Why?",
            "Should governments provide more services online?",
            "What are the risks of sharing personal information online?"]},
    {"id": "p2_teacher", "title": "Describe a person who taught you something important.",
     "bullets": ["who the person is", "what they taught you", "how they taught it",
                 "and explain why it was important."],
     "p3": ["What makes a good teacher?",
            "Do children learn more from parents or from teachers?",
            "Is respect for teachers changing in your country?"]},
    {"id": "p2_festival", "title": "Describe a festival or celebration you enjoy.",
     "bullets": ["what it is", "when it takes place", "what people do",
                 "and explain why you enjoy it."],
     "p3": ["Why are traditional festivals important?",
            "Are festivals becoming too commercial?",
            "How do young people celebrate differently from older people?"]},
]

# ------------------------------------------------------------- writing
WRITING_T1 = [  # General Training letters (no invented chart numbers)
    {"id": "t1_neighbour", "min_words": 150, "kind": "letter",
     "prompt": ("Your neighbour has been playing loud music late at night. "
                "Write a letter to your neighbour. In your letter: explain the problem, "
                "say how it is affecting you, and suggest a solution. "
                "Begin your letter: Dear ...")},
    {"id": "t1_course", "min_words": 150, "kind": "letter",
     "prompt": ("You want to join an evening English course at a local college. "
                "Write a letter to the college. In your letter: say why you want to "
                "join, describe your current level, and ask about fees and timings. "
                "Begin your letter: Dear Sir or Madam,")},
    {"id": "t1_friend", "min_words": 150, "kind": "letter",
     "prompt": ("A friend from abroad is coming to visit your city for one week. "
                "Write a letter to your friend. In your letter: suggest places to visit, "
                "recommend what to bring, and offer to help in some way. "
                "Begin your letter: Dear ...")},
]
WRITING_T2 = [
    {"id": "t2_online", "min_words": 250, "kind": "essay",
     "prompt": ("Some people think that studying online is as effective as studying "
                "in a classroom. To what extent do you agree or disagree? Give reasons "
                "for your answer and include relevant examples.")},
    {"id": "t2_cities", "min_words": 250, "kind": "essay",
     "prompt": ("More and more people are moving from villages to big cities. "
                "What problems does this cause, and what can be done to solve them?")},
    {"id": "t2_abroad", "min_words": 250, "kind": "essay",
     "prompt": ("Many young people go abroad to work or study. Do the advantages of "
                "this outweigh the disadvantages for their home country?")},
    {"id": "t2_screens", "min_words": 250, "kind": "essay",
     "prompt": ("Children today spend many hours in front of screens. Discuss the "
                "advantages and disadvantages of this and give your own opinion.")},
]

# ------------------------------------------------------------- reading
# Original passages. Answer keys + Bangla explanations. Facts kept general.
READING = [
    {"id": "r_floating", "title": "Gardens that float",
     "paragraphs": [
         "In the low-lying wetlands of southern Bangladesh, land can stay under water "
         "for several months of the year. For generations, farmers there have answered "
         "this problem in an unusual way: they build gardens that float.",
         "The beds are made mainly from water hyacinth, a fast-growing plant that "
         "covers ponds and canals. Farmers pile the plants into long rafts, add layers "
         "of other plant material, and let them rot slightly so that seeds can take "
         "root. Vegetables and seedlings are then grown on top of the raft while the "
         "fields below remain flooded.",
         "When the water goes down, the old beds are not wasted. They break down into "
         "rich material that farmers spread on their fields as natural fertiliser. "
         "The practice has been recognised by the UN's Food and Agriculture "
         "Organization as an important agricultural heritage system, and researchers "
         "have studied it as one way that farming can adapt to flooding.",
     ],
     "questions": [
         {"id": "q1", "type": "tfng",
          "text": "Floating gardens are used when fields are covered by water.",
          "answer": "true",
          "bn": "প্রথম ও দ্বিতীয় অনুচ্ছেদ: মাঠ পানির নিচে থাকলে ভাসমান বাগান ব্যবহার হয় — তাই True।"},
         {"id": "q2", "type": "tfng",
          "text": "Water hyacinth grows slowly.",
          "answer": "false",
          "bn": "লেখায় বলা আছে 'fast-growing' — দ্রুত বাড়ে। প্রশ্নটা উল্টো বলছে, তাই False।"},
         {"id": "q3", "type": "tfng",
          "text": "Floating gardens produce more food than ordinary fields.",
          "answer": "notgiven",
          "bn": "সাধারণ মাঠের সাথে উৎপাদনের তুলনা লেখায় কোথাও নেই — তাই Not Given। নিজের ধারণা দিয়ে উত্তর দেবেন না।"},
         {"id": "q4", "type": "mcq",
          "text": "What happens to the old beds after the flood?",
          "options": ["They are burned.", "They are used as fertiliser.",
                      "They are sold to other farmers.", "They float away."],
          "answer": "1",
          "bn": "তৃতীয় অনুচ্ছেদ: পুরনো বেড পচে সার হয়, মাঠে ছড়ানো হয় — দ্বিতীয় বিকল্প।"},
         {"id": "q5", "type": "tfng",
          "text": "The practice has received international recognition.",
          "answer": "true",
          "bn": "জাতিসংঘের FAO একে কৃষি ঐতিহ্য হিসেবে স্বীকৃতি দিয়েছে — আন্তর্জাতিক স্বীকৃতি, তাই True।"},
     ]},
    {"id": "r_forget", "title": "Why we forget — and how to remember",
     "paragraphs": [
         "In the 1880s the German psychologist Hermann Ebbinghaus tested his own memory "
         "by learning lists of nonsense syllables and checking how many he could recall "
         "after different lengths of time. He found that most forgetting happens soon "
         "after learning, and that the rate of loss then slows down. This pattern is now "
         "often called the forgetting curve.",
         "He also noticed that reviewing material made it last longer, and that each "
         "review allowed a longer gap before the next one was needed. Modern learning "
         "methods built on this idea are known as spaced repetition: instead of reading "
         "a list many times in one evening, the learner reviews it after one day, then "
         "a few days, then a week or more.",
         "Spaced repetition is not a shortcut. The learner still has to try to recall "
         "the answer before checking it, and this effort appears to be an important "
         "part of why the method works.",
     ],
     "questions": [
         {"id": "q1", "type": "tfng",
          "text": "Ebbinghaus used meaningful words in his experiments.",
          "answer": "false",
          "bn": "লেখায় আছে 'nonsense syllables' — অর্থহীন শব্দাংশ। তাই False।"},
         {"id": "q2", "type": "tfng",
          "text": "Most forgetting happens shortly after learning.",
          "answer": "true",
          "bn": "প্রথম অনুচ্ছেদ: 'most forgetting happens soon after learning' — True।"},
         {"id": "q3", "type": "mcq",
          "text": "In spaced repetition, the gaps between reviews…",
          "options": ["stay the same.", "become shorter.", "become longer.",
                      "are chosen at random."],
          "answer": "2",
          "bn": "দ্বিতীয় অনুচ্ছেদ: এক দিন, তারপর কয়েক দিন, তারপর এক সপ্তাহ — বিরতি বাড়ে, তৃতীয় বিকল্প।"},
         {"id": "q4", "type": "tfng",
          "text": "Ebbinghaus invented a mobile app for spaced repetition.",
          "answer": "false",
          "bn": "১৮৮০-এর দশকে মোবাইল অ্যাপ ছিল না; লেখায় বলা আছে আধুনিক পদ্ধতি তাঁর ধারণার উপর তৈরি — তিনি অ্যাপ বানাননি। False।"},
         {"id": "q5", "type": "tfng",
          "text": "Trying to recall an answer before checking it helps learning.",
          "answer": "true",
          "bn": "শেষ অনুচ্ছেদ: উত্তর দেখার আগে মনে করার চেষ্টাই পদ্ধতির গুরুত্বপূর্ণ অংশ — True।"},
     ]},
    {"id": "r_mobilemoney", "title": "Money in your pocket",
     "paragraphs": [
         "Not long ago, sending money to a family member in another district usually "
         "meant a bus journey, a long queue or trusting a friend to carry cash. Mobile "
         "financial services changed this in many countries, including Bangladesh. "
         "With a basic phone and a registered account, a person can now send money in "
         "seconds.",
         "These services are especially useful for people who live far from a bank "
         "branch. Agents in local shops let customers put cash into their account or "
         "take it out, so the shop works almost like a small bank counter.",
         "However, the convenience also brings risks. Fraudsters sometimes call users "
         "and pretend to be from the service, asking for a secret PIN or a one-time "
         "code. Providers repeatedly warn customers never to share these numbers with "
         "anyone, because genuine staff will never ask for them.",
     ],
     "questions": [
         {"id": "q1", "type": "tfng",
          "text": "A smartphone is required to use mobile financial services.",
          "answer": "false",
          "bn": "লেখায় আছে 'a basic phone' — সাধারণ ফোনেই চলে, স্মার্টফোন লাগে না। False।"},
         {"id": "q2", "type": "mcq",
          "text": "What role do local shop agents play?",
          "options": ["They lend money.", "They repair phones.",
                      "They let people deposit and withdraw cash.",
                      "They open bank branches."],
          "answer": "2",
          "bn": "দ্বিতীয় অনুচ্ছেদ: এজেন্ট দোকানে টাকা জমা ও তোলা যায় — তৃতীয় বিকল্প।"},
         {"id": "q3", "type": "tfng",
          "text": "Genuine staff may ask customers for their PIN.",
          "answer": "false",
          "bn": "শেষ লাইন: আসল কর্মী কখনো PIN চান না — False। বাস্তবেও কাউকে PIN/OTP বলবেন না।"},
         {"id": "q4", "type": "tfng",
          "text": "Mobile financial services charge lower fees than banks.",
          "answer": "notgiven",
          "bn": "খরচ/ফি নিয়ে লেখায় কিছু নেই — Not Given।"},
         {"id": "q5", "type": "tfng",
          "text": "Before mobile money, sending money could take a long time.",
          "answer": "true",
          "bn": "প্রথম অনুচ্ছেদ: আগে বাসে যাওয়া, লম্বা লাইন — সময় লাগত। True।"},
     ]},
]

# English explanations (strict bn/en: the English screen never shows Bangla).
READING_EN = {
    ("r_floating", "q1"): "Paragraphs 1-2: the gardens are used while the fields stay flooded — True.",
    ("r_floating", "q2"): "The text says water hyacinth is 'fast-growing' — the statement says the opposite, so False.",
    ("r_floating", "q3"): "The passage never compares output with ordinary fields — Not Given. Do not answer from your own knowledge.",
    ("r_floating", "q4"): "Paragraph 3: the old beds break down and are spread on fields as fertiliser — option 2.",
    ("r_floating", "q5"): "The UN's FAO recognised it as an agricultural heritage system — international recognition, True.",
    ("r_forget", "q1"): "He used 'nonsense syllables', not meaningful words — False.",
    ("r_forget", "q2"): "Paragraph 1: 'most forgetting happens soon after learning' — True.",
    ("r_forget", "q3"): "Paragraph 2: one day, then a few days, then a week — the gaps grow, option 3.",
    ("r_forget", "q4"): "There were no phone apps in the 1880s; modern methods were built on his idea — False.",
    ("r_forget", "q5"): "Last paragraph: the effort to recall before checking is an important part of why it works — True.",
    ("r_mobilemoney", "q1"): "The text says 'a basic phone' is enough — False.",
    ("r_mobilemoney", "q2"): "Paragraph 2: agents let customers put cash in and take it out — option 3.",
    ("r_mobilemoney", "q3"): "Last sentence: genuine staff will never ask for a PIN — False. Never share your PIN or code.",
    ("r_mobilemoney", "q4"): "Fees are not mentioned anywhere — Not Given.",
    ("r_mobilemoney", "q5"): "Paragraph 1: it meant a bus journey or a long queue — True.",
}

# ------------------------------------------------------------- vocabulary
# Academic words useful for IELTS, with Bangla meaning + an original example.
VOCAB = [
    ("v_significant", "significant", "উল্লেখযোগ্য, গুরুত্বপূর্ণ", "There was a significant rise in prices."),
    ("v_decline", "decline", "কমে যাওয়া, হ্রাস", "The number of visitors began to decline."),
    ("v_benefit", "benefit", "উপকার, সুবিধা", "Regular exercise has many benefits."),
    ("v_drawback", "drawback", "অসুবিধা, খারাপ দিক", "The main drawback is the high cost."),
    ("v_essential", "essential", "অপরিহার্য", "Clean water is essential for health."),
    ("v_consequence", "consequence", "পরিণতি, ফল", "Poor sleep can have serious consequences."),
    ("v_furthermore", "furthermore", "তাছাড়া, এছাড়াও", "Furthermore, the plan saves time."),
    ("v_however", "however", "তবে, কিন্তু", "The idea is good; however, it is expensive."),
    ("v_whereas", "whereas", "অন্যদিকে, যেখানে", "Cities are crowded, whereas villages are quiet."),
    ("v_therefore", "therefore", "সেই কারণে, তাই", "It rained heavily; therefore, the match was delayed."),
    ("v_approach", "approach", "পদ্ধতি, উপায়", "We need a new approach to this problem."),
    ("v_impact", "impact", "প্রভাব", "Technology has a strong impact on education."),
    ("v_crucial", "crucial", "অত্যন্ত জরুরি", "Early treatment is crucial."),
    ("v_obtain", "obtain", "পাওয়া, অর্জন করা", "You must obtain a visa before you travel."),
    ("v_adequate", "adequate", "যথেষ্ট, পর্যাপ্ত", "The room has adequate light."),
    ("v_rural", "rural", "গ্রামীণ", "Many rural families depend on farming."),
    ("v_urban", "urban", "শহুরে", "Urban traffic is getting worse."),
    ("v_migrate", "migrate", "অন্য জায়গায় চলে যাওয়া", "Many workers migrate to find jobs."),
    ("v_policy", "policy", "নীতি", "The government announced a new policy."),
    ("v_awareness", "awareness", "সচেতনতা", "We need more awareness about road safety."),
    ("v_contribute", "contribute", "অবদান রাখা", "Everyone can contribute to a cleaner city."),
    ("v_tend", "tend to", "সাধারণত করে থাকা", "Young people tend to use social media more."),
    ("v_overall", "overall", "সব মিলিয়ে", "Overall, the results were positive."),
    ("v_moreover", "moreover", "অধিকন্তু", "Moreover, it protects the environment."),
    ("v_rely", "rely on", "নির্ভর করা", "Farmers rely on the monsoon rain."),
    ("v_sustainable", "sustainable", "টেকসই", "We need sustainable ways to use water."),
    ("v_affordable", "affordable", "সাধ্যের মধ্যে, কম দামে", "Housing should be affordable."),
    ("v_evidence", "evidence", "প্রমাণ", "There is little evidence for this claim."),
    ("v_perspective", "perspective", "দৃষ্টিভঙ্গি", "Try to see it from a different perspective."),
    ("v_enhance", "enhance", "উন্নত করা, বাড়ানো", "Reading can enhance your vocabulary."),
]

# ------------------------------------------------------------- pronunciation
# Target sentences aimed at sounds Bangla speakers often find hard, with a tip.
PRON = [
    ("pr_vw", "We visited a very wide valley.",
     "v আর w আলাদা: v-তে উপরের দাঁত নিচের ঠোঁটে ছোঁয়ান; w-তে ঠোঁট গোল করুন, দাঁত ছোঁবে না।"),
    ("pr_th1", "I think three things are worth it.",
     "th (think, three): জিভের ডগা দুই দাঁতের মাঝে রেখে বাতাস ছাড়ুন — 'থ' বা 'ট' নয়।"),
    ("pr_th2", "This is the weather they like.",
     "th (this, the, they): জিভ দাঁতের মাঝে, গলায় কম্পন — 'দ' নয়।"),
    ("pr_school", "Students start school in spring.",
     "s দিয়ে শুরু শব্দের আগে 'ই' যোগ করবেন না: 'ইস্কুল' নয়, সরাসরি school।"),
    ("pr_z", "The zoo is closed on Thursdays.",
     "z-তে মৌমাছির মতো 'জ্‌জ্‌' কম্পন — 'জ' (j) নয়। Thursdays-এর শেষ s-ও z-এর মতো।"),
    ("pr_final_s", "She works and lives in two cities.",
     "শব্দের শেষের s/z (works, lives, cities) বাদ দেবেন না — অর্থ বদলে যায়।"),
    ("pr_f_p", "Five friends found a perfect place.",
     "f আর p আলাদা: f-এ দাঁত-ঠোঁট, p-তে দুই ঠোঁট — 'ফ' দিয়ে দুটোই বলবেন না।"),
    ("pr_short_long", "Please sit on this seat.",
     "sit (ছোট ই) আর seat (লম্বা ঈ) আলাদা শব্দ — দৈর্ঘ্যে পার্থক্য রাখুন।"),
    ("pr_cluster", "The strong street lights were bright.",
     "str, spr-এর মতো একসাথে কয়েকটা ব্যঞ্জন — মাঝে স্বর ঢোকাবেন না ('সট্রং' নয়)।"),
    ("pr_ed", "I walked, talked and waited for an hour.",
     "-ed: walked = 'ওয়াক্ট', talked = 'টক্ট', waited = 'ওয়েটিড' — সবসময় 'এড' নয়।"),
    ("pr_stress", "I need a photograph for my photography class.",
     "স্ট্রেস বদলায়: PHOtograph কিন্তু phoTOGraphy।"),
    ("pr_r", "Rice is ready in the river village.",
     "ইংরেজি r-এ জিভ মুখের ছাদ ছোঁয় না, কাঁপে না — নরম করে বলুন।"),
]

PRON_TIP_EN = {
    "pr_vw": "v and w differ: for v the top teeth touch the lower lip; for w round the lips, no teeth.",
    "pr_th1": "th in think/three: tongue tip between the teeth and blow air — not 't'.",
    "pr_th2": "th in this/the/they: tongue between the teeth with voice — not 'd'.",
    "pr_school": "Do not add a vowel before s-clusters: say 'school', not 'ischool'.",
    "pr_z": "z buzzes like a bee — it is not j. The final s in Thursdays also sounds like z.",
    "pr_final_s": "Keep the final s/z in works, lives, cities — dropping it changes the meaning.",
    "pr_f_p": "f uses teeth and lip; p uses both lips — do not say both as one sound.",
    "pr_short_long": "sit (short i) and seat (long ee) are different words — keep the length difference.",
    "pr_cluster": "In str/spr clusters do not insert a vowel between the consonants.",
    "pr_ed": "-ed: walked = 'walkt', talked = 'talkt', waited = 'wait-id' — not always 'ed'.",
    "pr_stress": "Stress moves: PHOtograph but phoTOGraphy.",
    "pr_r": "English r: the tongue does not touch the roof of the mouth and does not roll.",
}

# ------------------------------------------------------------- text helpers
_WORD_RE = re.compile(r"[a-z0-9']+")
FILLERS_1 = ("um", "uh", "er", "erm", "hmm", "ah")
FILLERS_2 = (("you", "know"), ("i", "mean"), ("kind", "of"), ("sort", "of"))
LINKERS = (
    "however", "therefore", "moreover", "furthermore", "although", "whereas",
    "because", "since", "firstly", "secondly", "finally", "in addition",
    "on the other hand", "for example", "for instance", "as a result",
    "in conclusion", "to sum up", "consequently", "nevertheless", "while",
    "despite", "in contrast", "overall",
)
STOP = frozenset((
    "the a an and or but of to in on at for with is are was were be been it this "
    "that these those i you he she we they my your his her our their me him them "
    "as by from not no do does did have has had will would can could should so "
    "if then than there here which who what when where why how very also more "
    "most some any all one two its it's i'm don't").split())


def words(text):
    """Lowercase word tokens (letters, digits, apostrophes)."""
    return _WORD_RE.findall(str(text or "").lower().replace("’", "'"))


def _sentences(text):
    parts = re.split(r"[.!?]+", str(text or ""))
    return [p for p in parts if words(p)]


def _paragraphs(text):
    parts = re.split(r"\n\s*\n|\n", str(text or "").strip())
    return [p for p in parts if words(p)]


def count_fillers(ws):
    n = sum(1 for w in ws if w in FILLERS_1)
    for i in range(len(ws) - 1):
        if (ws[i], ws[i + 1]) in FILLERS_2:
            n += 1
    return n


def linkers_used(text):
    low = " " + " ".join(words(text)) + " "
    return sorted(l for l in LINKERS if (" " + l + " ") in low)


def diversity(ws):
    """Unique content words / content words, 0..100 (integer)."""
    content = [w for w in ws if w not in STOP]
    if not content:
        return 0
    return round(100 * len(set(content)) / len(content))


def repeated(ws, at_least=4):
    counts = {}
    for w in ws:
        if w in STOP or len(w) < 4:
            continue
        counts[w] = counts.get(w, 0) + 1
    rows = sorted((-n, w) for w, n in counts.items() if n >= at_least)
    return [w for _, w in rows[:5]]


def _item(item_id, ok, en, bn, value=None):
    row = {"id": item_id, "ok": bool(ok), "en": en, "bn": bn}
    if value is not None:
        row["value"] = value
    return row


# ------------------------------------------------------------- writing check
def writing_prompt(task, prompt_id):
    pool = WRITING_T1 if task == "t1" else WRITING_T2 if task == "t2" else []
    for p in pool:
        if p["id"] == prompt_id:
            return p
    return None


def writing_check(task, text):
    """Key-free checklist for Writing Task 1 (letter) / Task 2 (essay)."""
    ws = words(text)
    n = len(ws)
    min_words = 150 if task == "t1" else 250
    paras = _paragraphs(text)
    sents = _sentences(text)
    avg_len = round(n / len(sents), 1) if sents else 0.0
    links = linkers_used(text)
    div = diversity(ws)
    reps = repeated(ws)
    contractions = sum(1 for w in ws if "'" in w and not w.endswith("'s"))
    items = [
        _item("length", n >= min_words,
              f"{n} words — at least {min_words} needed.",
              f"{n}টি শব্দ — কমপক্ষে {min_words}টি লাগবে। কম হলে Task-এর নম্বর কাটা যায়।",
              n),
        _item("paragraphs", len(paras) >= (3 if task == "t1" else 4),
              f"{len(paras)} paragraphs — aim for {'3+' if task == 't1' else '4+'} (intro, body, end).",
              f"{len(paras)}টি অনুচ্ছেদ — {'৩' if task == 't1' else '৪'}টি বা বেশি রাখুন (শুরু, মূল অংশ, শেষ)। এতে Coherence ভালো হয়।",
              len(paras)),
        _item("linkers", len(links) >= 3,
              f"{len(links)} different linking words used.",
              f"{len(links)} রকম linking word (however, therefore…) — অন্তত ৩ রকম ব্যবহার করুন, একই শব্দ বারবার নয়।",
              len(links)),
        _item("variety", 10 <= avg_len <= 25,
              f"Average sentence length {avg_len} words — mix short and longer sentences.",
              f"গড় বাক্য {avg_len} শব্দ — ছোট ও বড় বাক্য মিশিয়ে লিখুন; খুব লম্বা বাক্যে ব্যাকরণ ভুল বাড়ে।",
              avg_len),
        _item("diversity", div >= 55,
              f"Word variety {div}% — use synonyms instead of repeating.",
              f"শব্দের বৈচিত্র্য {div}% — একই শব্দ বারবার না লিখে সমার্থক শব্দ ব্যবহার করুন (Lexical Resource)।",
              div),
        _item("repeats", not reps,
              ("Repeated often: " + ", ".join(reps)) if reps else "No word is over-used.",
              ("বারবার এসেছে: " + ", ".join(reps)) if reps else "কোনো শব্দ অতিরিক্ত ব্যবহার হয়নি।",
              reps),
    ]
    if task == "t2":
        items.append(_item(
            "formal", contractions == 0,
            f"{contractions} contractions (don't, can't) — write them in full in an essay.",
            f"{contractions}টি সংক্ষেপ (don't, can't) — প্রবন্ধে পুরো লিখুন (do not, cannot)।",
            contractions))
    if task == "t1":
        low = str(text or "").strip().lower()
        items.append(_item(
            "greeting", low.startswith("dear"),
            "Letter starts with 'Dear …'.",
            "চিঠি 'Dear …' দিয়ে শুরু করুন, আর শেষে Yours sincerely / Best wishes লিখুন।"))
    passed = sum(1 for i in items if i["ok"])
    return {"kind": "checklist", "task": task, "word_count": n,
            "min_words": min_words, "items": items, "passed": passed,
            "total": len(items), "estimate": True}


# ------------------------------------------------------------- speaking check
def speaking_check(transcript, seconds, confidence=None):
    """Key-free speaking metrics from the speech-to-text transcript.

    `seconds` = time the learner actually spoke (measured by the app).
    `confidence` = the recogniser's own 0..1 confidence when the phone reports
    one (None otherwise) — shown as a pronunciation SIGNAL, never a band."""
    ws = words(transcript)
    n = len(ws)
    secs = max(0, int(seconds or 0))
    wpm = round(n * 60 / secs) if secs >= 5 else 0
    fill = count_fillers(ws)
    div = diversity(ws)
    longw = sum(1 for w in ws if len(w) >= 7)
    items = [
        _item("length", n >= 40,
              f"{n} words spoken — give longer answers with reasons and examples.",
              f"{n}টি শব্দ বলেছেন — কারণ ও উদাহরণ দিয়ে উত্তর লম্বা করুন (Part 2-তে ১–২ মিনিট)।",
              n),
        _item("pace", 100 <= wpm <= 170 if wpm else False,
              f"About {wpm} words per minute (a comfortable range is roughly 100–170)." if wpm
              else "Speak for at least a few seconds to measure your pace.",
              f"মিনিটে প্রায় {wpm} শব্দ (স্বাভাবিক গতি মোটামুটি ১০০–১৭০)। খুব ধীরে বললে Fluency কমে, খুব দ্রুত বললে উচ্চারণ অস্পষ্ট হয়।" if wpm
              else "গতি মাপতে কয়েক সেকেন্ড বলুন।",
              wpm),
        _item("fillers", fill <= max(1, n // 40),
              f"{fill} filler words (um, uh, you know).",
              f"{fill}টি ফিলার (um, uh, you know) — থামতে চাইলে 'Well, let me think' বলুন।",
              fill),
        _item("diversity", div >= 50,
              f"Word variety {div}%.",
              f"শব্দের বৈচিত্র্য {div}% — একই শব্দ বারবার না বলে নতুন শব্দ ব্যবহার করুন।",
              div),
        _item("range", n and longw * 100 // n >= 10,
              f"{longw} longer words used — add topic vocabulary.",
              f"{longw}টি বড়/বিষয়ভিত্তিক শব্দ — বিষয়ের শব্দ (যেমন environment, opportunity) যোগ করুন।",
              longw),
    ]
    conf = None
    if isinstance(confidence, (int, float)) and 0 < float(confidence) <= 1:
        conf = round(float(confidence) * 100)
        items.append(_item(
            "clarity", conf >= 70,
            f"Speech recogniser confidence {conf}% (a clarity signal, not a band).",
            f"ফোনের speech recogniser-এর আস্থা {conf}% — স্পষ্টতার একটা ইঙ্গিত, ব্যান্ড নয়।",
            conf))
    passed = sum(1 for i in items if i["ok"])
    return {"kind": "checklist", "word_count": n, "seconds": secs, "wpm": wpm,
            "fillers": fill, "confidence": conf, "items": items,
            "passed": passed, "total": len(items), "estimate": True}


# ------------------------------------------------------------- pronunciation
def align_words(target, heard):
    """Word-level alignment of target vs heard (Levenshtein, backtrace prefers
    an exact match first, then an extra heard word, then a missed target word, then a substitution). Returns (rows, score 0..100) where rows are
    {"word", "status": ok|sub|miss, "heard"} for each TARGET word in order."""
    t = words(target)
    h = words(heard)
    n, m = len(t), len(h)
    if n == 0:
        return [], 0
    d = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1):
        d[i][0] = i
    for j in range(m + 1):
        d[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            cost = 0 if t[i - 1] == h[j - 1] else 1
            d[i][j] = min(d[i - 1][j - 1] + cost, d[i - 1][j] + 1, d[i][j - 1] + 1)
    rows = []
    i, j = n, m
    while i > 0:
        if j > 0 and t[i - 1] == h[j - 1] and d[i][j] == d[i - 1][j - 1]:
            rows.append({"word": t[i - 1], "status": "ok", "heard": h[j - 1]})
            i -= 1
            j -= 1
        elif j > 0 and d[i][j] == d[i][j - 1] + 1:
            j -= 1  # an extra heard word — not a target word, skipped
        elif d[i][j] == d[i - 1][j] + 1:
            rows.append({"word": t[i - 1], "status": "miss", "heard": ""})
            i -= 1
        else:
            rows.append({"word": t[i - 1], "status": "sub", "heard": h[j - 1]})
            i -= 1
            j -= 1
    rows.reverse()
    ok = sum(1 for r in rows if r["status"] == "ok")
    return rows, round(100 * ok / n)


# ------------------------------------------------------------- streak
def streak(days, today):
    """Current + best run of consecutive practice day-numbers. The current
    run counts if the last practice was today or yesterday."""
    s = sorted(set(int(d) for d in days if isinstance(d, int) or str(d).lstrip("-").isdigit()))
    best = run = 0
    prev = None
    for d in s:
        run = run + 1 if prev is not None and d == prev + 1 else 1
        best = max(best, run)
        prev = d
    current = run if s and s[-1] >= today - 1 else 0
    return {"current": current, "best": best, "today_done": bool(s) and s[-1] == today}


# ------------------------------------------------------------- content
def content():
    """Everything the app renders (JSON-safe)."""
    return {
        "estimate_label": ESTIMATE_LABEL,
        "speaking": {"p1": SPEAKING_P1, "p2": SPEAKING_P2},
        "writing": {"t1": WRITING_T1, "t2": WRITING_T2},
        "reading": [dict(p, questions=[dict(q, en=READING_EN[(p["id"], q["id"])])
                                       for q in p["questions"]]) for p in READING],
        "vocab": [{"id": i, "en": e, "bn": b, "example": x} for i, e, b, x in VOCAB],
        "pron": [{"id": i, "text": s, "tip_bn": tip, "tip_en": PRON_TIP_EN[i]}
                 for i, s, tip in PRON],
        "official_links": OFFICIAL_LINKS,
        "criteria": {"writing": list(WRITING_CRITERIA),
                     "speaking": list(SPEAKING_CRITERIA)},
    }


def grade_reading(passage_id, answers):
    """answers {question_id: answer}. Returns per-question rows with the
    Bangla explanation, plus correct/total."""
    p = next((x for x in READING if x["id"] == passage_id), None)
    if p is None:
        return None
    rows = []
    for q in p["questions"]:
        given = str((answers or {}).get(q["id"], ""))
        rows.append({"id": q["id"], "given": given, "answer": q["answer"],
                     "correct": given == q["answer"], "bn": q["bn"],
                     "en": READING_EN[(p["id"], q["id"])]})
    return {"rows": rows, "correct": sum(r["correct"] for r in rows),
            "total": len(rows)}
