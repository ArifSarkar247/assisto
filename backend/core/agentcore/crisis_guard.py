"""AF-3 — crisis / emergency handover (Agentforce parity, owner order 28 Oct).

ONE deterministic, 0-credit guard shared by every place the user talks to
Assisto: Agent Core (runner.start), the home chat (POST /agent), the Assisto
AI chat (views_chat._produce_reply) and My Circle @Assisto. It runs BEFORE any
AI call, so it works with no AI key at all.

  detect(text) -> {"crisis", "category", "score", "categories"}
      categories: self_harm (suicide / self-harm intent), abuse (domestic
      abuse / violence / sexual violence), child (child abuse / a missing
      child), medical (a medical emergency happening now). Bangla, Banglish
      and English. High recall by design (a missed crisis is the worse
      error); benign look-alikes ("হাসতে হাসতে মরে যাচ্ছি", "dying of
      laughter", "suicide squad", "drowning in work", "brush stroke",
      "আত্মহত্যা নিয়ে রচনা", "heart attack symptoms", "last year he had a
      stroke") are guarded and measured (core/agentcore/evals/crisis_goals.py).
  log_detail(r) -> {"score", "category"} — the ONLY thing ever logged: never
      the words, never the matched phrase.
  respond(user, r, lang, surface) -> (reply_text, card)
      a calm, non-judgemental FIXED message (never a diagnosis, never advice
      on medicine), the emergency / helpline numbers, and — for the user's
      own words — an OFFER (never automatic) to tell their trusted family
      via the existing family-alert path (core.family_alerts, kind
      crisis_support). Nothing else happens in that turn.

Helpline numbers come from a server list the owner edits in Owner Admin
(/owner/crisis-helplines; stored in AdminFlagState key "crisis_helplines",
no migration). 999 is the only number shipped as verified and can never be
hidden. Every other entry ships "unverified — owner must confirm" and is NOT
shown to any user until the owner confirms it.

PURE except helplines()/save_helplines()/respond() (DB, lazily imported).
"""
import re
import unicodedata as _ud
import uuid

# ------------------------------------------------------------------ normalise
_ZW = re.compile(r"[​-‍⁠﻿­]")
_BN_DIG = str.maketrans("০১২৩৪৫৬৭৮৯", "0123456789")
_TO_BN = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")


def _nfd(s):
    return _ud.normalize("NFD", s)


def _norm(text):
    t = _ZW.sub("", _nfd(str(text or ""))).lower().replace("’", "'").replace("‘", "'")
    return re.sub(r"\s+", " ", t).strip()


def _c(rx):
    return re.compile(_nfd(rx), re.I)


# small shared pieces (Bangla: no \b — vowel signs are not \w)
_DEB = r"(?:দেব|দেবো|দিব|দিবো|দিমু|দেবই|দিয়ে\s*দেব|দিয়ে\s*দিব|দিতে\s*চাই)"
_FEL = r"(?:ফেলব|ফেলবো|ফেলমু|ফেলেছি|ফেলছি|ফেলি|ফেলতে\s*চাই)"
_KORBO = (r"(?:করব|করবো|করমু|করবই|করে\s*ফেলব|করে\s*ফেলবো|করে\s*ফেলমু|করতে\s*চাই|করতে\s*যাচ্ছি|"
          r"করার\s*কথা\s*ভাবছি|করব\s*ভাবছি|করবো\s*ভাবছি|করার\s*ইচ্ছা|করার\s*ইচ্ছে|করতে\s*ইচ্ছা|"
          r"করতে\s*ইচ্ছে|করার\s*চিন্তা|করার\s*পরিকল্পনা|করার\s*চেষ্টা\s*করেছি|করতে\s*গিয়েছিলাম)")
_WANT = r"(?:চাই|ইচ্ছা\s*করে|ইচ্ছে\s*করে|ইচ্ছা\s*করছে|ইচ্ছে\s*করছে|মন\s*চায়)(?!\s*না)"
_BL_WANT = r"(?:chai|cai|chay|chae|icche|iccha|ichha|ichhe|issa|isse|mon\s+chay)(?!\s*na\b)"
_BL_DIBO = r"(?:dibo|debo|dimu|dite\s+chai)"
_BL_FELBO = r"(?:felbo|felmu|felechi|felsi|feli|felte\s+chai)"
_KIN_BN = (r"(?:স্বামী|জামাই|বর|শ্বশুর|শাশুড়ি|শ্বশুরবাড়ির\s*লোক|দেবর|ভাসুর|সৎ\s*বাবা|সৎ\s*মা|"
           r"প্রেমিক|বয়ফ্রেন্ড|স্ত্রী|বউ|বাবা|ভাই|বস|মালিক|চাচা|মামা|খালু|ফুপা)")
_CHILD_BN = (r"(?:বাচ্চা|বাচ্চাকে|ছেলে|ছেলেকে|মেয়ে|মেয়েকে|শিশু|শিশুকে|সন্তান|সন্তানকে|ভাগ্নে|"
             r"ভাগ্নি|ভাতিজা|ভাতিজি|নাতি|নাতনি|ছাত্রকে|ছাত্রীকে)")
_CHILD_EN = r"(?:child|kid|son|daughter|baby|boy|girl|toddler|nephew|niece|grandson|granddaughter)"
_CHILD_BL = (r"(?:baccha|bacca|bachcha|bacha|chele|meye|bacchake|baccake|bachchake|cheleke|meyeke|"
             r"shishu|sishu|sontan)")

# ------------------------------------------------------------------ patterns
# (category, regex) — STRONG: first-person intent / an emergency happening
_STRONG = {
    "self_harm": [
        # Bangla
        r"(?:আত্মহত্যা|আত্মহনন|সুইসাইড)\s*" + _KORBO,
        r"(?:আত্মহত্যার|আত্মহননের|সুইসাইডের)\s*(?:চেষ্টা|কথা\s*ভাব|ইচ্ছা|ইচ্ছে|চিন্তা|প্ল্যান|পরিকল্পনা)",
        r"(?:মরে\s*যেতে|মরতে|মইরা\s*যাইতে|মরে\s*যাইতে)\s*" + _WANT,
        r"(?:মরে\s*যাওয়াই|মরে\s*গেলেই|মরাই)\s*(?:ভালো|ভাল|উচিত|শ্রেয়)",
        r"(?:বাঁচতে|বেঁচে\s*থাকতে)\s*(?:চাই\s*না|ইচ্ছা\s*করে\s*না|ইচ্ছে\s*করে\s*না|ইচ্ছা\s*নেই|ইচ্ছে\s*নেই|"
        r"মন\s*চায়\s*না|আর\s*ইচ্ছা\s*নেই)",
        r"বেঁচে\s*থাকার\s*(?:কোনো\s*|কোন\s*)?(?:ইচ্ছা|ইচ্ছে|মানে|কারণ|অর্থ)\s*(?:নেই|নাই|পাই\s*না|খুঁজে\s*পাই\s*না)",
        r"বেঁচে\s*থেকে\s*(?:কী|কি)\s*(?:লাভ|হবে)",
        r"আর\s*(?:বাঁচব|বাঁচবো|বাঁচমু)\s*না",
        r"নিজেকে\s*(?:শেষ\s*করে|মেরে|খুন\s*করে|কেটে)\s*(?:" + _DEB[3:-1] + r"|" + _FEL[3:-1] + r")",
        r"নিজের\s*(?:শরীরের\s*)?ক্ষতি\s*(?:করি|করব|করবো|করছি|করে\s*ফেলেছি|করে\s*ফেলব|করতে\s*ইচ্ছা|করতে\s*ইচ্ছে|করতে\s*চাই)",
        r"(?:জীবন|জীবনটা|প্রাণ|নিজের\s*জীবন)\s*শেষ\s*করে\s*(?:" + _DEB[3:-1] + r"|" + _FEL[3:-1] + r")",
        r"গলায়\s*(?:দড়ি|ফাঁস)\s*(?:" + _DEB[3:-1] + r"|দিয়ে\s*মরব)",
        r"ফাঁস\s*(?:দেব|দেবো|দিব|দিবো|দিমু|নেব|নেবো|নিব|নিবো|দিতে\s*চাই)",
        r"(?:ঘুমের\s*(?:ওষুধ|বড়ি|ট্যাবলেট)|বিষ|ইঁদুরের\s*বিষ|ইঁদুর\s*মারার\s*বিষ|কীটনাশক)\s*(?:খেয়ে|খাইয়া)\s*"
        r"(?:মরব|মরবো|মরমু|মরে\s*যাব|মরে\s*যাবো|আত্মহত্যা|শেষ\s*করব|সব\s*শেষ)",
        r"(?:অনেকগুলো|সবগুলো|এক\s*পাতা|পুরো\s*পাতা)\s*(?:ঘুমের\s*)?(?:ওষুধ|বড়ি|ট্যাবলেট)\s*"
        r"(?:খেয়ে\s*ফেলেছি|খেয়েছি|খেয়ে\s*ফেলব|খাব|খেয়ে\s*নেব)",
        r"(?:ছাদ|বিল্ডিং|ব্রিজ|সেতু|বারান্দা)\s*থেকে\s*(?:লাফ|ঝাঁপ)\s*" + _DEB,
        r"(?:ট্রেনের\s*নিচে|নদীতে|গাড়ির\s*নিচে)\s*ঝাঁপ\s*" + _DEB,
        r"(?:হাত|কবজি|রগ)\s*কেটে\s*(?:ফেলেছি|ফেলব|ফেলবো|ফেলি|দেব|দিব)",
        r"ব্লেড\s*দিয়ে\s*(?:হাত\s*)?(?:কাটি|কেটেছি|কাটব|কাটবো|কাটলাম)",
        r"পৃথিবী\s*(?:ছেড়ে|থেকে)\s*চলে\s*যেতে\s*(?:চাই|ইচ্ছা|ইচ্ছে)",
        # Banglish
        r"\b(?:atmo|atto|attho|atma|aatmo|attmo)\s*-?\s*h(?:o|a)t+h?(?:a|o)\s+"
        r"(?:korbo|korte|korar|kore\s+fel|korum|kormu|krbo|krte|korbo\s+bhabchi)",
        r"\b(?:su[iy]?c[iy]de|sui?side|suicyd)\s+(?:korbo|korte|korar|kore\s+fel|korum|kormu|krbo|krte)",
        r"\b(?:more|mora|moira|mor)\s+(?:jete|jaite|jaete|jaite)\s+" + _BL_WANT,
        r"\bmorte\s+" + _BL_WANT,
        r"\b(?:more\s+jaoa(?:i|y)|more\s+jawai|more\s+gelei|morai)\s+(?:bhalo|valo|uchit)",
        r"\b(?:bachte|bacte|baachte|beche\s+thakte|bese\s+thakte|bachar)\s+(?:chai\s*na|chaina|cai\s*na|"
        r"icche\s+kore\s+na|iccha\s+kore\s+na|ichha\s+kore\s+na|isse\s+kore\s+na|mon\s+chay\s+na|"
        r"icche\s+nai|iccha\s+nai|ichha\s+nai|icche\s+nei|iccha\s+nei)",
        r"\bbeche\s+thakar\s+(?:kono\s+)?(?:mane|karon|icche|iccha|ichha|orth)\s+(?:nai|nei|nay)",
        r"\bar\s+(?:bachbo|bachmu)\s+na\b",
        r"\bnijeke\s+(?:shesh|sesh|mere|khun|kete)\s+(?:kore\s+)?(?:" + _BL_DIBO[3:-1] + r"|" + _BL_FELBO[3:-1] + r")",
        r"\b(?:jibon|jibonta|pran)\s+(?:shesh|sesh)\s+kore\s+(?:" + _BL_DIBO[3:-1] + r"|" + _BL_FELBO[3:-1] + r")",
        r"\bgola(?:y|e|i)\s+(?:dori|fash|fas|phash|phas)\s+" + _BL_DIBO,
        r"\b(?:fash|fas|phash|phas)\s+(?:dibo|debo|dimu|nibo|nebo)\b",
        r"\b(?:ghumer\s+(?:oshudh|osudh|osud|oshud|pill|tablet)|bish|bis|poison|rat\s+poison)\s+"
        r"khe(?:y|i)?e\s+(?:morbo|mormu|more\s+jabo|felbo|felechi|felsi|nichi|niyechi)",
        r"\b(?:hat|haat|rog)\s+kete\s+(?:felechi|felbo|feli|felsi|dibo)",
        r"\bblade\s+diye\s+(?:hat\s+)?(?:kati|ketechi|katbo|katlam)",
        r"\b(?:chad|chhad|chaad|roof|bridge|building)\s+theke\s+(?:laf|lafh|jhap|jhanp)\s+" + _BL_DIBO,
        # English
        r"\bkill(?:ing)?\s+my\s*self\b",
        r"\b(?:end|ending|take|taking)\s+my\s+(?:own\s+)?life\b",
        r"\bsuicidal\b",
        r"\bcommit(?:ting)?\s+suicide\b",
        r"\b(?:thinking|thought|thoughts|think)\s+(?:of|about)\s+(?:suicide|killing\s+myself|ending\s+(?:it|my\s+life))\b",
        r"\bsuicide\s+(?:note|plan)\b",
        r"\b(?:attempt(?:ed)?|try|tried|trying)\s+(?:to\s+)?(?:suicide|kill\s+myself|end\s+my\s+life)\b",
        r"(?<!don't )(?<!dont )(?<!do not )(?<!never )\b(?:want|wanna|wish)\s+(?:to\s+)?(?:die|be\s+dead)\b",
        r"\bwish\s+i\s+(?:was|were|could\s+be)\s+dead\b",
        r"\bwish\s+i\s+(?:had\s+)?never\s+(?:been\s+born|woke\s+up|wake\s+up)\b",
        r"\bbetter\s+off\s+dead\b",
        r"\b(?:don'?t|do\s+not)\s+want\s+to\s+(?:live|be\s+alive|exist|wake\s+up)\b",
        r"\bno\s+(?:reason|point)\s+(?:to|in)\s+(?:live|living|go\s+on|going\s+on)\b",
        r"\bnot\s+worth\s+living\b",
        r"\b(?:want|wanna|going|gonna|will|keep|thinking\s+of|thought\s+of|urge\s+to|feel\s+like)\s+(?:to\s+)?"
        r"(?:hurt|harm|cut|cutting|hurting|harming)\s+myself\b",
        r"\bself[\s-]?harm(?:ing)?\b",
        r"\b(?:take|took|swallow|swallowed|taking)\s+(?:all|a\s+lot\s+of|many|too\s+many|the\s+whole\s+(?:bottle|strip)\s+of)\s+"
        r"(?:my\s+|the\s+)?(?:pills|tablets|sleeping\s+pills|medicines?)\b",
        r"\bend\s+it\s+all\b",
        r"\bcan'?t\s+go\s+on\s+(?:living|anymore)\b",
        r"\bjump\s+(?:off|from)\s+(?:a|the|this)\s+(?:bridge|roof|building|balcony)\b",
    ],
    "child": [
        _CHILD_BN + r"(?:টা|টি)?\s*(?:কে\s*)?(?:খুঁজে\s*পাচ্ছি\s*না|খুঁজে\s*পাওয়া\s*যাচ্ছে\s*না|হারিয়ে\s*গেছে|হারিয়ে\s*গিয়েছে|"
        r"নিখোঁজ|পাওয়া\s*যাচ্ছে\s*না|কেউ\s*তুলে\s*নিয়ে\s*গেছে|অপহরণ)",
        _CHILD_BN + r"(?:টা|টি)?(?=\s|$|[,।.!?])[^।.!?\n]{0,35}(?:মারধর|নির্যাতন|যৌন\s*(?:নির্যাতন|হয়রানি)|খারাপ\s*ভাবে\s*ছোঁয়|খারাপভাবে\s*ছোঁয়|গায়ে\s*হাত|"
        r"ধর্ষণ|শ্লীলতাহানি|আটকে\s*রেখেছে|পিটিয়েছে|পেটায়|পিটায়)",
        r"\b" + _CHILD_BL + r"\s+(?:ke\s+)?(?:khuje\s+pacchi\s+na|khuje\s+paccina|khuje\s+pachhi\s+na|khuje\s+pacchi\s+nah|"
        r"hariye\s+geche|harie\s+geche|haray\s+geche|hariye\s+gese|nikhoj|pawa\s+jacche\s+na|tule\s+niye\s+geche|kidnap)",
        r"\b" + _CHILD_BL + r"\b[a-z\s]{0,35}(?:maredhor|marodhor|nirjaton|nirjatan|kharap\s+bhabe\s+chhoy|"
        r"kharap\s+vabe\s+choy|gaye\s+hat|dhorshon|rape|molest|joun\s+(?:nirjaton|hoyrani))",
        r"\b(?:my|our)\s+(?:[\w-]+\s+){0,3}" + _CHILD_EN + r"\s+(?:is\s+missing|went\s+missing|has\s+gone\s+missing|is\s+lost|got\s+lost|"
        r"has\s+been\s+(?:kidnapped|abducted|taken)|was\s+(?:kidnapped|abducted|taken)|has\s+been\s+missing)\b",
        r"\b(?:can'?t|cannot|can\s+not)\s+find\s+my\s+(?:\w+\s+)?(?:child|kid|son|daughter|baby|toddler)\b",
        r"\b(?:someone|somebody|he|she|they|uncle|teacher|tutor|neighbou?r|stepfather|step-father|stepdad|man)\s+"
        r"(?:is\s+|has\s+been\s+|keeps\s+|was\s+)?(?:touching|touched|molesting|molested|abusing|abused|beating|hitting|hurting)\s+"
        r"(?:my|our|a)\s+(?:\w+\s+)?" + _CHILD_EN + r"\b",
        r"\b(?:molest|molested|molesting)\b",
    ],
    "abuse": [
        r"(?:আমাকে|আমায়)\s*(?:প্রতিদিন\s*|রোজ\s*|আবার\s*|খুব\s*|সবসময়\s*)?(?:মারধর|পেটায়|পিটায়|পিটিয়েছে|"
        r"নির্যাতন\s*কর|অত্যাচার\s*কর|গলা\s*টিপে|আটকে\s*রেখেছে|আটকে\s*রাখে|মেরে\s*ফেলবে|মেরে\s*ফেলার\s*হুমকি|"
        r"মেরে\s*ফেলতে\s*চায়|পুড়িয়ে\s*মারতে|এসিড\s*মারবে|ধর্ষণ\s*কর|জোর\s*করে\s*(?:ধর|শারীরিক))",
        _KIN_BN + r"[^।.!?\n]{0,25}(?:আমাকে|আমায়)\s*(?:প্রতিদিন\s*|রোজ\s*|আবার\s*|খুব\s*)?(?:মারে|মারছে|মেরেছে|মারধর)",
        r"(?:আমার\s*)?গায়ে\s*হাত\s*(?:তোলে|তুলেছে|তুলল|তুলছে|তোলেন)",
        r"(?:নির্যাতনের|অত্যাচারের|সহিংসতার)\s*শিকার",
        r"যৌতুকের\s*জন্য[^।.!?\n]{0,20}(?:মারে|মারধর|নির্যাতন|অত্যাচার|চাপ|পেটায়|পিটায়)",
        r"(?:আমাকে|আমায়)\s*(?:ধর্ষণ|যৌন\s*হয়রানি|শ্লীলতাহানি)",
        r"ধর্ষণের\s*শিকার|আমি\s*ধর্ষিত",
        r"(?:কেউ|লোকটা|লোকগুলো|ওরা|সে)\s*(?:আমাকে\s*)?(?:মারতে\s*আসছে|ছুরি\s*নিয়ে\s*(?:আসছে|দাঁড়িয়ে))",
        r"\b(?:amake|amay|amare)\s+(?:protidin\s+|roj\s+|abar\s+|khub\s+)?(?:maredhor|marodhor|petay|pitay|pitiyeche|"
        r"nirjaton\s+kor|nirjatan\s+kor|ottachar\s+kor|otyachar\s+kor|gola\s+tipe|atke\s+rekhe|mere\s+felbe|"
        r"mere\s+felar\s+humki|rape\s+kor|dhorshon)",
        r"\b(?:shami|swami|jamai|bor|shoshur|shashuri|boyfriend|premik|baba|bhai|boss)\b[a-z\s]{0,25}\b(?:amake|amay|amare)\s+"
        r"(?:protidin\s+|roj\s+|abar\s+|khub\s+)?(?:mare|marche|mereche|maredhor|marodhor)\b",
        r"\bgaye\s+hat\s+(?:tole|tule|tulse|tuleche|tolen)\b",
        r"\bjoutuk\w*\s+(?:er\s+)?jonno\s+(?:[a-z]+\s+){0,2}(?:mare|maredhor|marodhor|nirjaton|chap)",
        r"\b(?:husband|wife|partner|boyfriend|girlfriend|father|dad|stepfather|stepdad|brother|in-laws?|mother-in-law|"
        r"father-in-law|uncle|boss|he|she)\s+(?:\w+\s+){0,3}(?:hits|beats|beat|hit|slapped|slaps|kicked|kicks|"
        r"chokes|choked|strangled|strangles|abuses|abused|burned|locked\s+up|locks\s+up)\s+me\b",
        r"\b(?:i\s+am|i'm|im|i\s+was|i've\s+been|i\s+have\s+been)\s+(?:being\s+)?(?:abused|beaten|raped|sexually\s+assaulted|"
        r"assaulted|threatened|stalked|trafficked)\b",
        r"\b(?:raped|sexually\s+assaulted|molested|assaulted)\s+me\b",
        r"\bthreaten(?:s|ed|ing)?\s+to\s+kill\s+me\b",
        r"\btrying\s+to\s+kill\s+me\b",
        r"\b(?:i'm|i\s+am|im)\s+(?:scared|afraid)\s+(?:of|for)\s+my\s+(?:life|husband|partner|father|boyfriend|wife)\b",
    ],
    "medical": [
        r"(?:বুকে|বুকের)\s*(?:প্রচণ্ড\s*|খুব\s*|তীব্র\s*|হঠাৎ\s*)?ব্যথা|বুক\s*ব্যথা",
        r"শ্বাস\s*(?:নিতে\s*)?(?:পারছে\s*না|পারছি\s*না|পারছেন\s*না|নিচ্ছে\s*না|বন্ধ\s*হয়ে)|"
        r"শ্বাসকষ্ট\s*(?:হচ্ছে|শুরু\s*হয়েছে|বেড়ে\s*গেছে|উঠেছে)|দম\s*বন্ধ\s*হয়ে\s*আসছে",
        r"অজ্ঞান\s*হয়ে\s*(?:গেছে|গেছেন|গিয়েছে|পড়েছে|পড়েছেন|যাচ্ছে)|জ্ঞান\s*(?:হারিয়েছে|হারিয়েছেন|নেই|ফিরছে\s*না)|"
        r"সাড়া\s*দিচ্ছে\s*না|সাড়া\s*দিচ্ছেন\s*না",
        r"খিঁচুনি\s*(?:হচ্ছে|হয়েছে|উঠেছে)|স্ট্রোক\s*(?:করেছে|করেছেন|হয়েছে|করছে)|"
        r"হার্ট\s*(?:অ্যাটাক|এটাক|অ্যাটাক)\s*(?:করেছে|করেছেন|হয়েছে|হচ্ছে)?",
        r"রক্ত\s*(?:থামছে\s*না|বন্ধ\s*হচ্ছে\s*না)|প্রচণ্ড\s*রক্তক্ষরণ|অনেক\s*রক্ত\s*(?:পড়ছে|যাচ্ছে)|রক্তবমি|রক্ত\s*বমি",
        r"(?:বিষ|কীটনাশক|ইঁদুরের\s*বিষ)\s*(?:খেয়েছে|খেয়ে\s*ফেলেছে|খাইছে|খেয়েছেন)|বিষপান|বিষ\s*পান",
        r"সাপে\s*(?:কেটেছে|কামড়েছে|কাটছে|কামড়াইছে|কেটেছে)|সাপ\s*(?:কেটেছে|কামড়েছে|কামড়\s*দিয়েছে)",
        r"(?:পানিতে|পুকুরে|নদীতে|ডোবায়)\s*(?:ডুবে|পড়ে)\s*(?:গেছে|যাচ্ছে|গিয়েছে)",
        r"(?:কারেন্টে|বিদ্যুতে|বিদ্যুৎ)\s*(?:শক|স্পৃষ্ট)|বিদ্যুৎস্পৃষ্ট",
        r"(?:আগুনে|গরম\s*পানিতে|গরম\s*তেলে)\s*(?:পুড়ে|ঝলসে)\s*(?:গেছে|গিয়েছে|গেছেন)",
        r"গর্ভবতী[^।.!?\n]{0,30}(?:রক্তপাত|রক্ত\s*যাচ্ছে|খিঁচুনি|অজ্ঞান)|প্রসব\s*ব্যথা[^।.!?\n]{0,20}রক্ত",
        r"অতিরিক্ত\s*(?:ওষুধ|ঘুমের\s*ওষুধ)\s*খেয়ে\s*(?:ফেলেছে|ফেলেছেন)",
        r"(?:এক্সিডেন্ট|অ্যাক্সিডেন্ট|দুর্ঘটনা)\s*(?:হয়েছে|করেছে|করেছেন|ঘটেছে)",
        r"\b(?:buke|buk\s+e|bukey)\s+(?:khub\s+|prochondo\s+|hotat\s+)?(?:betha|batha|bytha|pain)\b",
        r"\b(?:shash|shas|sash|swas|shwash)\s+(?:nite\s+)?(?:parche\s+na|parchi\s+na|parchena|parchina|kosto|bondho)",
        r"\b(?:ojnan|ojnaan|oggan|ogyan)\s+(?:hoye|hoie|hoe)\s*(?:geche|gese|gelo|jacche|porse|poreche)",
        r"\b(?:khichuni|khicuni)\s+(?:hocche|hoise|hoyeche|uthse)",
        r"\bstroke\s+(?:koreche|korse|hoyeche|hoise|korche)",
        r"\bheart\s*attack\s+(?:koreche|korse|hoyeche|hoise|korche)",
        r"\b(?:bish|bis|poison|kitnashok)\s+(?:kheyeche|kheyese|khaise|khaiche|kheye\s+feleche|kheye\s+felse)",
        r"\b(?:shap|sap|saap)\s*(?:e\s+)?(?:kamrieche|kamraise|kamreche|kateche|katse|kamor\s+diyeche|kamrise)",
        r"\b(?:panite|pukure|nodite)\s+(?:dube|pore)\s+(?:geche|gese|jacche)",
        r"\b(?:current|karent)\s*(?:e\s+)?(?:shock|shok)\s+(?:kheyeche|khaise|kheyese|lagse|legeche)",
        r"\b(?:rokto|rakto)\s+(?:thamche\s+na|bondho\s+hocche\s+na|beshi\s+jacche|porche\s+onek)",
        r"\baccident\s+(?:hoyeche|hoise|korse|koreche)",
        r"\bchest\s+pain\b",
        r"\bheart\s+attack\b",
        r"\b(?:can'?t|cannot|can\s+not|unable\s+to|trouble|difficulty|struggling\s+to)\s+breath(?:e|ing)\b",
        r"\b(?:not|stopped)\s+breathing\b",
        r"\bshortness\s+of\s+breath\b",
        r"\bunconscious\b(?!\s+(?:bias|mind))",
        r"\b(?:he|she|my\s+\w+|someone|somebody|i|they|dad|mom|mum)\s+(?:just\s+|has\s+|have\s+|suddenly\s+)?"
        r"(?:collapsed|fainted|passed\s+out)\b",
        r"\bunresponsive\b",
        r"\b(?:having|had|has|is\s+having)\s+(?:a\s+)?seizures?\b|\bconvulsing\b",
        r"\b(?:having|had|has|is\s+having|might\s+be\s+having)\s+a\s+stroke\b",
        r"\bslurred\s+speech\b|\bface\s+droop\w*",
        r"\b(?:heavy|severe|won'?t\s+stop|uncontrolled)\s+bleeding\b|\bbleeding\s+(?:a\s+lot|heavily|won'?t\s+stop)\b",
        r"\b(?:vomiting|coughing)\s+(?:up\s+)?blood\b",
        r"\boverdos(?:e|ed|ing)\b",
        r"\b(?:swallowed|drank|ate)\s+(?:some\s+)?(?:poison|bleach|pesticide|kerosene|rat\s+poison)\b",
        r"\bsnake\s*bite\b|\bbitten\s+by\s+a\s+snake\b|\bsnake\s+bit\b",
        r"\b(?:is|was|almost|nearly|someone|child|kid|boy|girl|son|daughter)\s+(?:is\s+)?drown(?:ing|ed)\b"
        r"(?!\s+in\s+(?:work|debt|emails?|tasks|paperwork|sorrow|love))",
        r"\belectrocuted\b|\belectric\s+shock\b",
        r"\bsevere(?:ly)?\s+burn(?:ed|t|s)?\b",
        r"\b(?:badly\s+)?(?:hurt|injured)\s+in\s+(?:an?\s+)?(?:accident|crash)\b|\b(?:car|road|bike|bus)\s+accident\b",
    ],
}
# WEAK: a crisis word without first-person intent — triggers unless the text
# is plainly about study / media ("আত্মহত্যা নিয়ে রচনা", "suicide prevention day")
_WEAK = {
    "self_harm": r"আত্মহত্যা|আত্মহনন|সুইসাইড|\bsuicid\w*|\b(?:atmo|atto|attho|atma)\s*-?\s*hott?h?a\b",
    "abuse": (r"পারিবারিক\s*(?:নির্যাতন|সহিংসতা)|ধর্ষণ|ধর্ষিত|যৌন\s*হয়রানি|\bdomestic\s+(?:violence|abuse)\b|"
              r"\braped?\b|\bsexual(?:ly)?\s+(?:assault\w*|harass\w*|abuse\w*)|\bdhorshon\b"),
    "child": (r"শিশু\s*(?:নির্যাতন|পাচার|ধর্ষণ|যৌন\s*নির্যাতন)|বাল্যবিবাহ|\bchild\s+(?:abuse|trafficking|marriage)\b|"
              r"\bmissing\s+child\b|\bshishu\s+nirjat\w*|\bbalyo\s*bibah\w*"),
}
_BENIGN_CTX = _c(
    r"রচনা|প্রবন্ধ|অনুচ্ছেদ|সিনেমা|মুভি|নাটক|উপন্যাস|গবেষণা|পরিসংখ্যান|প্রতিরোধ\s*দিবস|সচেতনতা|অ্যাসাইনমেন্ট|"
    r"হোমওয়ার্ক|থিসিস|\bessay|\barticle|\bparagraph|\bmovie|\bfilm\b|\bnovel\b|\bresearch|\bstatistic|"
    r"\bprevention\s+(?:day|week|month)|\bawareness|\bhomework|\bassignment|\bsquad\b|\bbomber|\bdocumentary|"
    r"\bseries\b|\bepisode|\blyrics|\bsong\b|\bthesis|\bpresentation\b|\bquiz\b|\bdebate\b|\brochona\b|\bprobondho\b")

# benign look-alike SPANS removed before matching (idioms, names, objects)
_GUARDS = [_c(x) for x in (
    r"হাসতে\s*হাসতে\s*(?:মরে|মারা|পেট)[^\s।.!?]*(?:\s*(?:যাচ্ছি|গেলাম|যাব|যাবো|গেছি|ফেটে\s*যাচ্ছে|যেতে\s*ইচ্ছে\s*করছে))?",
    r"(?:মরে|মারা)\s*(?:যাচ্ছি|গেলাম|যাব|যেতে\s*ইচ্ছে\s*করছে|যেতে\s*চাই)\s*হাসতে\s*হাসতে",
    r"(?:লজ্জায়|হাসিতে|হাসির\s*চোটে|গরমে|শীতে|ঠান্ডায়|জ্যামে|খিদেয়|ক্ষুধায়)\s*মরে\s*(?:যেতে\s*(?:ইচ্ছে|ইচ্ছা)\s*করছে|যেতে\s*চাই|যাই|যাচ্ছি|গেলাম)",
    r"\b(?:haste|hashte|haste)\s+(?:haste|hashte)\s+(?:more|mora|moira|mara)[a-z\s]{0,20}",
    r"\b(?:lojjay|hasir\s+chote)\s+(?:more|mora|moira)[a-z\s]{0,20}",
    r"\b(?:die|died|dying|dead|kill(?:ing)?\s+myself|wanna\s+die|want\s+to\s+die)\s+(?:of\s+|from\s+|with\s+)?"
    r"(?:laugh\w*|embarrass\w*|shame|boredom|cuteness|excitement)",
    r"\b(?:laughing|laughed)\s+(?:so\s+hard\s+)?(?:to\s+death|i\s+(?:could|almost|nearly)\s+die)",
    r"\bdie\s+(?:my|her|his|the|your)\s+hair\b",
    r"\bsuicide\s+(?:squad|mission|door|doors|burn|lane|king|silence|bomb\w*|attack\w*|drills?|sprints?|run)\b",
    r"\b(?:die|dice)[\s-]?(?:cast|hard)\b",
    r"\b(?:brush|swimming|back|breast|key|pen|master|golf)\s*strokes?\b|\bstroke\s+(?:of\s+(?:luck|genius)|play|order)\b",
    r"\b(?:gave|give|giving|almost\s+gave)\s+me\s+a\s+heart\s+attack\b",
    r"\bheart\s+attack\s+(?:burger|sandwich|pizza|level)\b",
    r"\b(?:beat|beats|beating)\s+me\s+(?:at|in)\s+\w+",
    r"\bbattery\s+(?:is\s+)?(?:dying|dead)\b",
    r"\bcan'?t\s+breathe\s+(?:without|from\s+laughing)\b",
    r"\bdrown(?:ing|ed)\s+in\s+(?:work|debt|emails?|tasks|paperwork|sorrow|love)\b",
    r"\bkill(?:ing)?\s+(?:time|the\s+(?:app|process|task|lights|engine|music|game))\b",
    r"\bend\s+it\s+all\s+(?:for\s+(?:today|the\s+day))\b",
    r"\b(?:i'?m|im|i\s+am)\s+dead\s+(?:tired|serious)\b",
)]
# a medical emergency must be happening now — not past history or a question
_PAST = _c(r"গত\s*(?:বছর|মাসে|সপ্তাহে|বার)|গতকাল|আগে\s*একবার|হয়েছিল|হয়েছিলো|করেছিল|করেছিলেন|"
           r"\blast\s+(?:year|month|week|time)\b|\byesterday\b|\byears?\s+ago\b|\bmonths?\s+ago\b|\bin\s+20\d\d\b|"
           r"\bgoto\s*(?:bochor|mashe)\b|\bhoyechilo\b|\bkorechilo\b|\bused\s+to\b")
_INFO = _c(r"লক্ষণ|উপসর্গ|হলে\s*(?:কী|কি)\s*(?:করব|করতে|করা)|প্রতিরোধ|প্রাথমিক\s*চিকিৎসা|কারণ\s*(?:কী|কি)|"
           r"\bsymptoms?\b|\bsigns?\s+of\b|\bwhat\s+(?:causes|is\s+an?)\b|\bhow\s+to\s+(?:prevent|treat|help)\b|"
           r"\bprevention\b|\bfirst\s+aid\b|\bin\s+case\s+of\b|\bwhat\s+to\s+do\s+(?:if|when)\b|\bmovie\b|\bsong\b|"
           r"\blokkhon\b|\binsurance\b|\bইন্স্যুরেন্স|বীমা|ক্লেইম|\bclaim\b")
_NOW = _c(r"এখন|এইমাত্র|এখনই|\bnow\b|\bright\s+now\b|\bjust\s+now\b|\bekhon\w*|বাঁচাও")

_RX = {cat: [_c(r) for r in rxs] for cat, rxs in _STRONG.items()}
_WRX = {cat: _c(r) for cat, r in _WEAK.items()}
CATEGORIES = ("self_harm", "abuse", "child", "medical")      # priority order
_SCORE = {"self_harm": 0.95, "child": 0.9, "abuse": 0.9, "medical": 0.9}
WEAK_SCORE = 0.7
NONE = {"crisis": False, "category": "", "score": 0.0, "categories": []}


def detect(text):
    """-> {"crisis", "category", "score", "categories"}. PURE, 0 credits."""
    t = _norm(text)
    if not t:
        return dict(NONE)
    for g in _GUARDS:
        t = g.sub(" ", t)
    hits = {}
    for cat in CATEGORIES:
        if any(rx.search(t) for rx in _RX[cat]):
            hits[cat] = _SCORE[cat]
    if "medical" in hits and (_PAST.search(t) or _INFO.search(t)) and not _NOW.search(t):
        hits.pop("medical")
    if not _BENIGN_CTX.search(t):
        for cat, rx in _WRX.items():
            if cat not in hits and rx.search(t):
                hits[cat] = WEAK_SCORE
    if not hits:
        return dict(NONE)
    top = next(c for c in CATEGORIES if c in hits)
    return {"crisis": True, "category": top, "score": hits[top],
            "categories": [c for c in CATEGORIES if c in hits]}


def log_detail(r):
    """What may be logged / audited: the score and category — never words."""
    return {"score": float(r.get("score") or 0.0), "category": r.get("category") or ""}


# ------------------------------------------------------------------ helplines
CONFIG_KEY = "crisis_helplines"
UNVERIFIED_NOTE = "unverified — owner must confirm"
DEFAULT_HELPLINES = (
    {"key": "emergency", "number": "999", "verified": True, "locked": True,
     "bn": "জাতীয় জরুরি সেবা (পুলিশ, অ্যাম্বুলেন্স, ফায়ার সার্ভিস)",
     "en": "National emergency (police, ambulance, fire service)",
     "categories": list(CATEGORIES), "source": "Bangladesh national emergency service 999"},
    {"key": "women_children", "number": "109", "verified": False, "locked": False,
     "bn": "নারী ও শিশু নির্যাতন প্রতিরোধ হেল্পলাইন", "en": "Helpline for violence against women & children",
     "categories": ["abuse", "child"], "source": UNVERIFIED_NOTE},
    {"key": "child_helpline", "number": "1098", "verified": False, "locked": False,
     "bn": "চাইল্ড হেল্পলাইন (শিশু সুরক্ষা)", "en": "Child Helpline (child protection)",
     "categories": ["child"], "source": UNVERIFIED_NOTE},
    {"key": "kaan_pete_roi", "number": "", "verified": False, "locked": False,
     "bn": "কান পেতে রই (মানসিক সহায়তা)", "en": "Kaan Pete Roi (emotional support)",
     "categories": ["self_harm"], "source": UNVERIFIED_NOTE + " (number not filled in yet)"},
)
_NUM_RX = re.compile(r"^\+?[0-9]{3,15}$")


def clean_number(v):
    return re.sub(r"[\s-]", "", str(v or "").translate(_BN_DIG))


def _row():
    from ..models import AdminFlagState
    return AdminFlagState.objects.filter(key=CONFIG_KEY).first()


def all_helplines():
    """Every configured entry (defaults merged with the owner's edits), shown
    in Owner Admin — including the unverified ones."""
    stored = {}
    try:
        row = _row()
        stored = ((row.state or {}).get("items") or {}) if row else {}
    except Exception:  # noqa: BLE001 — a DB problem never hides 999
        stored = {}
    out = []
    for d in DEFAULT_HELPLINES:
        h = dict(d, categories=list(d["categories"]))
        s = stored.get(d["key"]) or {}
        if not d["locked"]:
            for k in ("number", "bn", "en", "source", "verified", "confirmed_at", "confirmed_by"):
                if k in s:
                    h[k] = s[k]
            if isinstance(s.get("categories"), list):
                h["categories"] = [c for c in s["categories"] if c in CATEGORIES]
        h["number"] = clean_number(h.get("number"))
        h["verified"] = bool(h.get("verified")) and bool(_NUM_RX.match(h["number"]))
        out.append(h)
    return out


def helplines(category="", lang="bn"):
    """What a USER sees: 999 always, plus only the owner-CONFIRMED entries
    for this category. Unverified numbers are never shown."""
    out = []
    for h in all_helplines():
        if not h["verified"]:
            continue
        if category and category not in h["categories"] and not h["locked"]:
            continue
        out.append({"key": h["key"], "number": h["number"],
                    "display": h["number"].translate(_TO_BN) if lang == "bn" else h["number"],
                    "label": h["bn"] if lang == "bn" else h["en"]})
    if not any(h["key"] == "emergency" for h in out):          # belt and braces
        out.insert(0, {"key": "emergency", "number": "999",
                       "display": "৯৯৯" if lang == "bn" else "999",
                       "label": DEFAULT_HELPLINES[0]["bn" if lang == "bn" else "en"]})
    return out


def validate_edit(key, data):
    """Owner Admin edit of one entry -> (clean dict, problems)."""
    base = next((d for d in DEFAULT_HELPLINES if d["key"] == key), None)
    if base is None:
        return None, ["unknown"]
    if base["locked"]:
        return None, ["locked"]
    num = clean_number(data.get("number"))
    probs = []
    if num and not _NUM_RX.match(num):
        probs.append("bad_number")
    verified = str(data.get("verified") or "") in ("1", "on", "true", "True")
    source = str(data.get("source") or "").strip()[:200]
    if verified and not num:
        probs.append("no_number")
    if verified and (not source or UNVERIFIED_NOTE in source):
        probs.append("no_source")
    cats = data.getlist("categories") if hasattr(data, "getlist") else (data.get("categories") or [])
    cats = [c for c in cats if c in CATEGORIES] or list(base["categories"])
    clean = {"number": num, "verified": verified, "source": source or UNVERIFIED_NOTE,
             "bn": (str(data.get("bn") or "").strip() or base["bn"])[:120],
             "en": (str(data.get("en") or "").strip() or base["en"])[:120],
             "categories": cats}
    return clean, probs


def save_helpline(key, clean, actor=None, now=None):
    """Persist one owner edit; returns (before, after) for the audit row."""
    from django.utils import timezone
    from ..models import AdminFlagState
    row, _ = AdminFlagState.objects.get_or_create(key=CONFIG_KEY)
    state = dict(row.state or {})
    items = dict(state.get("items") or {})
    before = dict(items.get(key) or {})
    after = dict(before, **clean)
    if clean.get("verified") and not before.get("verified"):
        after["confirmed_at"] = (now or timezone.now()).isoformat()
        after["confirmed_by"] = getattr(actor, "pk", None)
    if not clean.get("verified"):
        after.pop("confirmed_at", None)
        after.pop("confirmed_by", None)
    items[key] = after
    state["items"] = items
    row.state = state
    row.audit = ([{"key": key, "by": getattr(actor, "pk", None),
                   "at": (now or timezone.now()).isoformat(), "verified": after.get("verified")}]
                 + list(row.audit or []))[:100]
    row.save(update_fields=["state", "audit", "updated_at"])
    return before, after


# ------------------------------------------------------------------ responses
_MSG = {
    "self_harm": (
        "আপনি যা বলছেন, তা শুনে আমি সত্যিই চিন্তিত — আর আমাকে বলার জন্য ধন্যবাদ। আপনি একা নন। "
        "এই মুহূর্তে নিজের ক্ষতির ঝুঁকি থাকলে দয়া করে এখনই ৯৯৯-এ ফোন করুন, বা কাছের কাউকে পাশে থাকতে বলুন।",
        "I'm really sorry you're going through this, and thank you for telling me. You are not alone. "
        "If you might hurt yourself or are in danger right now, please call 999 now, or ask someone near you to stay with you."),
    "abuse": (
        "আপনার সাথে যা হচ্ছে, তার জন্য আপনি দায়ী নন — আর আপনি সাহায্য পাওয়ার যোগ্য। "
        "এই মুহূর্তে বিপদে থাকলে সম্ভব হলে নিরাপদ জায়গায় যান এবং এখনই ৯৯৯-এ ফোন করুন।",
        "What is happening to you is not your fault, and you deserve help. "
        "If you are in danger right now, move somewhere safe if you can and call 999 now."),
    "child": (
        "এটা খুব কঠিন সময় — সাহায্য চেয়ে আপনি ঠিক কাজটিই করছেন। "
        "শিশুটি বিপদে থাকলে বা খুঁজে পাওয়া না গেলে দেরি না করে এখনই ৯৯৯-এ ফোন করুন।",
        "This is a very hard moment — you are doing the right thing by asking for help. "
        "If the child is in danger or cannot be found, please call 999 right now; do not wait."),
    "medical": (
        "এটা জরুরি অবস্থা হতে পারে। দয়া করে এখনই ৯৯৯-এ ফোন করুন বা নিকটস্থ হাসপাতালে যান, "
        "আর সাহায্য না আসা পর্যন্ত মানুষটির পাশে থাকুন।",
        "This could be an emergency. Please call 999 now or go to the nearest hospital, "
        "and stay with the person until help arrives."),
}
_OTHERS_MSG = (
    "এই কথাগুলো পড়ে মনে হচ্ছে কেউ বিপদে থাকতে পারেন। সম্ভব হলে এখনই তাঁর সাথে কথা বলুন, তাঁকে একা থাকতে দেবেন না। "
    "কেউ এই মুহূর্তে বিপদে থাকলে ৯৯৯-এ ফোন করুন।",
    "Someone in these messages may be in danger. If you can, talk to them now and don't leave them alone. "
    "If anyone is in danger right now, call 999.")
_FAMILY_LINE = (
    "আপনি চাইলে আমি আপনার পরিবারের বিশ্বস্ত মানুষদের জানাতে পারি, যাতে তাঁরা আপনাকে ফোন করেন — "
    "শুধু আপনি নিচে ‘হ্যাঁ, জানাও’ চাপলে।",
    "If you want, I can let your trusted family know so they call you — only if you tap “Yes, tell them” below.")
_TITLE = ("আপনি একা নন — এখনই সাহায্য নিন", "You are not alone — get help now")
_NUMBERS_HEAD = ("সাহায্যের নম্বর:", "Help numbers:")
FAMILY_SALT = "agentcore.crisis.family"
FAMILY_MAX_AGE_S = 6 * 3600


def _pick(lang, pair):
    return pair[1] if lang == "en" else pair[0]


def family_token(user, event_id, category):
    from django.core import signing
    return signing.dumps({"u": user.pk, "e": str(event_id)[:60], "c": category}, salt=FAMILY_SALT)


def read_family_token(token, user):
    """-> (event_id, category) or None (forged / expired / someone else's)."""
    from django.core import signing
    try:
        d = signing.loads(str(token or ""), salt=FAMILY_SALT, max_age=FAMILY_MAX_AGE_S)
    except (signing.BadSignature, signing.SignatureExpired, TypeError, ValueError):
        return None
    if not isinstance(d, dict) or d.get("u") != getattr(user, "pk", None):
        return None
    return str(d.get("e") or ""), str(d.get("c") or "")


def _family_count(user):
    try:
        from .. import family_alerts as FA
        return len(FA.consenting_members(user))
    except Exception:  # noqa: BLE001
        return 0


def respond(user, r, lang="bn", surface="agent", event_id=None, own_words=True):
    """-> (reply_text, card). own_words=False (My Circle summarize/translate:
    someone ELSE's messages) -> the 'someone may be in danger' text and no
    family offer. Never sends anything by itself."""
    lang = "en" if lang == "en" else "bn"
    cat = r.get("category") or "medical"
    nums = helplines(cat, lang)
    text = _pick(lang, _MSG.get(cat, _MSG["medical"])) if own_words else _pick(lang, _OTHERS_MSG)
    lines = [text, _pick(lang, _NUMBERS_HEAD) + " " + " · ".join(
        "%s (%s)" % (h["display"], h["label"]) for h in nums)]
    n_family = _family_count(user) if (own_words and user is not None) else 0
    family = {"offer": False}
    if n_family:
        eid = event_id or ("%s:%s" % (surface, uuid.uuid4().hex[:16]))
        family = {"offer": True, "count": n_family, "token": family_token(user, eid, cat),
                  "endpoint": "/api/v1/crisis/family-alert",
                  "yes": "হ্যাঁ, জানাও" if lang == "bn" else "Yes, tell them",
                  "no": "না, এখন না" if lang == "bn" else "Not now"}
        lines.append(_pick(lang, _FAMILY_LINE))
    card = {"type": "crisis", "category": cat, "title": _pick(lang, _TITLE),
            "helplines": [{"key": h["key"], "number": h["number"], "label": h["label"],
                           "display": h["display"], "app_action": "dial"} for h in nums],
            "app_action": "dial", "needs_confirm": True, "leaves_app": True,
            "family": family, "ads": False}
    return "\n\n".join(lines), card


FAMILY_TEXTS = {
    "title_bn": "{name} আপনাকে পাশে চান", "title_en": "{name} would like you near",
    "body_bn": "{name} এই মুহূর্তে আপনার সাথে কথা বলতে চান। সম্ভব হলে এখনই একবার ফোন করুন।",
    "body_en": "{name} would like to talk to you right now. Please call them if you can.",
}


def alert_family(user, token, now=None):
    """The user TAPPED 'Yes, tell them': one family alert (kind
    crisis_support) to their consenting circle — no category, no words, no
    location. Idempotent per crisis event. -> stats dict or None (bad token)."""
    got = read_family_token(token, user)
    if got is None:
        return None
    eid, _cat = got
    from .. import family_alerts as FA
    return FA.alert(user, "crisis_support", "crisis:" + eid, payload=dict(FAMILY_TEXTS), now=now)
