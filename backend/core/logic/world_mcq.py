"""
world_mcq.py — BCS-style MCQ practice (Students hub, p4-world).

The question bank below is ORIGINAL: every question, option and explanation
was written for Assisto in our own words. It covers widely known public facts
(Bangladesh general knowledge, Bangla literature/language, English grammar,
basic maths) — no question is taken from a copyrighted question bank, guide
book or past-paper collection.

Pure: no Django, no DB, no clock. Rounds are picked with a caller-given seed.
"""
import random

TOPICS = ("gk", "bangla", "english", "math")
TOPIC_NAMES = {"gk": ("বাংলাদেশ ও সাধারণ জ্ঞান", "Bangladesh & general knowledge"),
               "bangla": ("বাংলা ভাষা ও সাহিত্য", "Bangla language & literature"),
               "english": ("ইংরেজি", "English"),
               "math": ("গণিত", "Maths"),
               "mixed": ("সব বিষয় মিলিয়ে", "All topics mixed")}
ROUND_SIZE = 10

_BN = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")


def bn_digits(s):
    return str(s).translate(_BN)


def _q(id_, topic, q, opts, ans, why):
    """q/why: (bn, en); opts: list of 4 (bn, en) or 4 plain strings (same in both)."""
    o = [x if isinstance(x, tuple) else (x, x) for x in opts]
    assert len(o) == 4 and 0 <= ans < 4
    return {"id": id_, "topic": topic, "q": q, "opts": o, "ans": ans, "why": why}


BANK = [
    # ------------------------------------------------------------ gk (16)
    _q("gk01", "gk", ("বাংলাদেশের রাজধানী কোনটি?", "What is the capital of Bangladesh?"),
       [("চট্টগ্রাম", "Chattogram"), ("ঢাকা", "Dhaka"), ("খুলনা", "Khulna"), ("রাজশাহী", "Rajshahi")], 1,
       ("ঢাকা বাংলাদেশের রাজধানী ও সবচেয়ে বড় শহর।", "Dhaka is the capital and the largest city.")),
    _q("gk02", "gk", ("বাংলাদেশের স্বাধীনতা দিবস কবে?", "When is Bangladesh's Independence Day?"),
       [("২১ ফেব্রুয়ারি", "21 February"), ("১৬ ডিসেম্বর", "16 December"), ("২৬ মার্চ", "26 March"), ("১৪ এপ্রিল", "14 April")], 2,
       ("১৯৭১ সালের ২৬ মার্চ স্বাধীনতা ঘোষণা করা হয়।", "Independence was declared on 26 March 1971.")),
    _q("gk03", "gk", ("বিজয় দিবস কবে পালিত হয়?", "When is Victory Day observed?"),
       [("১৬ ডিসেম্বর", "16 December"), ("২৬ মার্চ", "26 March"), ("৭ মার্চ", "7 March"), ("১ মে", "1 May")], 0,
       ("১৯৭১ সালের ১৬ ডিসেম্বর মুক্তিযুদ্ধে বিজয় অর্জিত হয়।", "The Liberation War was won on 16 December 1971.")),
    _q("gk04", "gk", ("আন্তর্জাতিক মাতৃভাষা দিবস কোন দিন?", "Which day is International Mother Language Day?"),
       [("২১ মার্চ", "21 March"), ("২১ ফেব্রুয়ারি", "21 February"), ("১৬ ডিসেম্বর", "16 December"), ("২৬ মার্চ", "26 March")], 1,
       ("১৯৫২ সালের ভাষা আন্দোলনের স্মরণে ইউনেস্কো দিনটি ঘোষণা করে।", "UNESCO declared it in memory of the 1952 Language Movement.")),
    _q("gk05", "gk", ("পৃথিবীর বৃহত্তম ম্যানগ্রোভ বন কোনটি?", "Which is the world's largest mangrove forest?"),
       [("লাউয়াছড়া", "Lawachara"), ("ভাওয়াল", "Bhawal"), ("সুন্দরবন", "Sundarbans"), ("মধুপুর", "Madhupur")], 2,
       ("সুন্দরবন বাংলাদেশ ও ভারতজুড়ে বিস্তৃত, এটি ইউনেস্কো বিশ্ব ঐতিহ্য।", "The Sundarbans spans Bangladesh and India and is a UNESCO World Heritage site.")),
    _q("gk06", "gk", ("বাংলাদেশের জাতীয় ফুল কোনটি?", "What is the national flower of Bangladesh?"),
       [("গোলাপ", "Rose"), ("শাপলা", "Water lily (shapla)"), ("রজনীগন্ধা", "Tuberose"), ("জবা", "Hibiscus")], 1,
       ("জাতীয় ফুল শাপলা।", "The national flower is the water lily (shapla).")),
    _q("gk07", "gk", ("বাংলাদেশের জাতীয় ফল কোনটি?", "What is the national fruit of Bangladesh?"),
       [("আম", "Mango"), ("লিচু", "Lychee"), ("কাঁঠাল", "Jackfruit"), ("কলা", "Banana")], 2,
       ("জাতীয় ফল কাঁঠাল।", "The national fruit is the jackfruit.")),
    _q("gk08", "gk", ("বাংলাদেশের জাতীয় পশু কোনটি?", "What is the national animal of Bangladesh?"),
       [("রয়েল বেঙ্গল টাইগার", "Royal Bengal Tiger"), ("হাতি", "Elephant"), ("হরিণ", "Deer"), ("দোয়েল", "Magpie robin")], 0,
       ("জাতীয় পশু রয়েল বেঙ্গল টাইগার; দোয়েল জাতীয় পাখি।", "The national animal is the Royal Bengal Tiger; the magpie robin is the national bird.")),
    _q("gk09", "gk", ("বাংলাদেশে বর্তমানে কয়টি বিভাগ?", "How many divisions does Bangladesh have?"),
       [("৬টি", "6"), ("৭টি", "7"), ("৮টি", "8"), ("১০টি", "10")], 2,
       ("৮টি বিভাগ: ঢাকা, চট্টগ্রাম, রাজশাহী, খুলনা, বরিশাল, সিলেট, রংপুর ও ময়মনসিংহ।", "Eight: Dhaka, Chattogram, Rajshahi, Khulna, Barishal, Sylhet, Rangpur and Mymensingh.")),
    _q("gk10", "gk", ("কক্সবাজার কিসের জন্য বিখ্যাত?", "What is Cox's Bazar famous for?"),
       [("চা-বাগান", "Tea gardens"), ("দীর্ঘ প্রাকৃতিক সমুদ্রসৈকত", "A very long natural sea beach"), ("প্রাচীন মসজিদ", "Ancient mosques"), ("জলপ্রপাত", "Waterfalls")], 1,
       ("কক্সবাজারে পৃথিবীর দীর্ঘতম অবিচ্ছিন্ন প্রাকৃতিক বালুকাময় সৈকতগুলোর একটি।", "Cox's Bazar has one of the world's longest unbroken natural sand beaches.")),
    _q("gk11", "gk", ("বাংলাদেশের মুদ্রার নাম কী?", "What is Bangladesh's currency called?"),
       [("রুপি", "Rupee"), ("টাকা", "Taka"), ("দিনার", "Dinar"), ("রিয়াল", "Riyal")], 1,
       ("বাংলাদেশের মুদ্রা টাকা (৳)।", "The currency is the taka (৳).")),
    _q("gk12", "gk", ("পদ্মা সেতু কোন সালে যান চলাচলের জন্য খুলে দেওয়া হয়?", "In which year did the Padma Bridge open to traffic?"),
       [("2018", "2018"), ("2020", "2020"), ("2022", "2022"), ("2024", "2024")], 2,
       ("পদ্মা সেতু ২০২২ সালের জুনে খুলে দেওয়া হয়।", "The Padma Bridge opened in June 2022.")),
    _q("gk13", "gk", ("জাতীয় সংসদ ভবনের স্থপতি কে?", "Who was the architect of the National Parliament House?"),
       [("লুই আই কান", "Louis I. Kahn"), ("ফজলুর রহমান খান", "Fazlur Rahman Khan"), ("লে করবুসিয়ে", "Le Corbusier"), ("জাহা হাদিদ", "Zaha Hadid")], 0,
       ("মার্কিন স্থপতি লুই আই কান সংসদ ভবনের নকশা করেন।", "The American architect Louis I. Kahn designed it.")),
    _q("gk14", "gk", ("বাংলাদেশের জাতীয় কবি কে?", "Who is the national poet of Bangladesh?"),
       [("রবীন্দ্রনাথ ঠাকুর", "Rabindranath Tagore"), ("জসীমউদ্দীন", "Jasimuddin"), ("কাজী নজরুল ইসলাম", "Kazi Nazrul Islam"), ("শামসুর রাহমান", "Shamsur Rahman")], 2,
       ("কাজী নজরুল ইসলাম বাংলাদেশের জাতীয় কবি।", "Kazi Nazrul Islam is the national poet.")),
    _q("gk15", "gk", ("জাতীয় সংগীত 'আমার সোনার বাংলা'-র রচয়িতা কে?", "Who wrote the national anthem 'Amar Shonar Bangla'?"),
       [("কাজী নজরুল ইসলাম", "Kazi Nazrul Islam"), ("রবীন্দ্রনাথ ঠাকুর", "Rabindranath Tagore"), ("দ্বিজেন্দ্রলাল রায়", "Dwijendralal Ray"), ("লালন শাহ", "Lalon Shah")], 1,
       ("রবীন্দ্রনাথ ঠাকুর গানটি লিখেছিলেন।", "Rabindranath Tagore wrote the song.")),
    _q("gk16", "gk", ("বাংলাদেশের একমাত্র প্রবাল দ্বীপ কোনটি?", "Which is Bangladesh's only coral island?"),
       [("ভোলা", "Bhola"), ("হাতিয়া", "Hatiya"), ("সেন্ট মার্টিন", "St. Martin's"), ("মহেশখালী", "Moheshkhali")], 2,
       ("সেন্ট মার্টিন বঙ্গোপসাগরে অবস্থিত প্রবাল দ্বীপ।", "St. Martin's in the Bay of Bengal is a coral island.")),
    # ------------------------------------------------------------ bangla (16)
    _q("bn01", "bangla", ("'পথের পাঁচালী' উপন্যাসের লেখক কে?", "Who wrote the novel 'Pather Panchali'?"),
       [("শরৎচন্দ্র চট্টোপাধ্যায়", "Sarat Chandra Chattopadhyay"), ("বিভূতিভূষণ বন্দ্যোপাধ্যায়", "Bibhutibhushan Bandyopadhyay"), ("মানিক বন্দ্যোপাধ্যায়", "Manik Bandyopadhyay"), ("তারাশঙ্কর বন্দ্যোপাধ্যায়", "Tarashankar Bandyopadhyay")], 1,
       ("উপন্যাসটি বিভূতিভূষণ বন্দ্যোপাধ্যায়ের লেখা।", "It was written by Bibhutibhushan Bandyopadhyay.")),
    _q("bn02", "bangla", ("রবীন্দ্রনাথ ঠাকুর কত সালে নোবেল পুরস্কার পান?", "In which year did Rabindranath Tagore win the Nobel Prize?"),
       [("1905", "1905"), ("1913", "1913"), ("1921", "1921"), ("1941", "1941")], 1,
       ("'গীতাঞ্জলি'-র জন্য ১৯১৩ সালে সাহিত্যে নোবেল পান।", "He won the 1913 Nobel Prize in Literature for 'Gitanjali'.")),
    _q("bn03", "bangla", ("'পল্লীকবি' নামে কে পরিচিত?", "Who is known as the 'Palli Kobi' (poet of rural Bengal)?"),
       [("জসীমউদ্দীন", "Jasimuddin"), ("জীবনানন্দ দাশ", "Jibanananda Das"), ("সুকান্ত ভট্টাচার্য", "Sukanta Bhattacharya"), ("ফররুখ আহমদ", "Farrukh Ahmad")], 0,
       ("গ্রামবাংলার জীবন নিয়ে লেখার জন্য জসীমউদ্দীন পল্লীকবি নামে পরিচিত।", "Jasimuddin is called the Palli Kobi for his poems of village life.")),
    _q("bn04", "bangla", ("'বিদ্রোহী' কবিতাটি কার লেখা?", "Who wrote the poem 'Bidrohi' (The Rebel)?"),
       [("রবীন্দ্রনাথ ঠাকুর", "Rabindranath Tagore"), ("কাজী নজরুল ইসলাম", "Kazi Nazrul Islam"), ("শামসুর রাহমান", "Shamsur Rahman"), ("আল মাহমুদ", "Al Mahmud")], 1,
       ("কাজী নজরুল ইসলাম 'বিদ্রোহী' লেখেন, তাই তাঁকে বিদ্রোহী কবি বলা হয়।", "Kazi Nazrul Islam wrote it — hence 'the rebel poet'.")),
    _q("bn05", "bangla", ("বাংলা বর্ণমালায় স্বরবর্ণ কয়টি?", "How many vowels (swarabarna) are in the Bangla alphabet?"),
       [("৯টি", "9"), ("১০টি", "10"), ("১১টি", "11"), ("১২টি", "12")], 2,
       ("স্বরবর্ণ ১১টি: অ আ ই ঈ উ ঊ ঋ এ ঐ ও ঔ।", "There are 11 vowels.")),
    _q("bn06", "bangla", ("বাংলা বর্ণমালায় ব্যঞ্জনবর্ণ কয়টি?", "How many consonants (byanjanabarna) are in the Bangla alphabet?"),
       [("৩৫টি", "35"), ("৩৭টি", "37"), ("৩৯টি", "39"), ("৪১টি", "41")], 2,
       ("প্রচলিত হিসাবে ব্যঞ্জনবর্ণ ৩৯টি।", "By the standard count there are 39 consonants.")),
    _q("bn07", "bangla", ("'ঘরের শত্রু বিভীষণ' বাগধারার অর্থ কী?", "What does the Bangla saying 'ghorer shotru Bibhishon' mean?"),
       [("অতিথি", "A guest"), ("ঘরের ভেতরের বিশ্বাসঘাতক", "A traitor within one's own side"), ("সাহসী যোদ্ধা", "A brave fighter"), ("দুর্বল প্রতিবেশী", "A weak neighbour")], 1,
       ("নিজের লোক হয়েও যে শত্রুর পক্ষ নেয়।", "Someone of your own who sides with the enemy.")),
    _q("bn08", "bangla", ("'অকালকুষ্মাণ্ড' বাগধারার অর্থ কী?", "What does the Bangla expression 'okalkushmando' mean?"),
       [("অপদার্থ / অকেজো লোক", "A useless person"), ("জ্ঞানী ব্যক্তি", "A wise person"), ("ধনী লোক", "A rich person"), ("পরিশ্রমী লোক", "A hard worker")], 0,
       ("যে কোনো কাজে আসে না, তাকে অকালকুষ্মাণ্ড বলা হয়।", "It describes someone who is of no use.")),
    _q("bn09", "bangla", ("'উন্নতি' শব্দের বিপরীত শব্দ কোনটি?", "Which word is the opposite of the Bangla word 'unnoti' (progress)?"),
       [("প্রসার", "prosar (spread)"), ("উত্থান", "utthan (rise)"), ("অবনতি", "obonoti (decline)"), ("সফলতা", "sofolota (success)")], 2,
       ("উন্নতির বিপরীত অবনতি।", "The opposite of unnoti is obonoti.")),
    _q("bn10", "bangla", ("'বিদ্যালয়' শব্দের সন্ধি বিচ্ছেদ কোনটি?", "How is the Bangla word 'bidyaloy' (school) split by sandhi?"),
       [("বিদ্য + আলয়", "bidy + aloy"), ("বিদ্যা + আলয়", "bidya + aloy"), ("বিদ্যা + লয়", "bidya + loy"), ("বিদ + আলয়", "bid + aloy")], 1,
       ("বিদ্যা + আলয় = বিদ্যালয় (আ + আ = আ)।", "bidya + aloy = bidyaloy (aa + aa = aa).")),
    _q("bn11", "bangla", ("'নকশী কাঁথার মাঠ' কাব্যের রচয়িতা কে?", "Who wrote the poem book 'Nakshi Kanthar Math'?"),
       [("জসীমউদ্দীন", "Jasimuddin"), ("কাজী নজরুল ইসলাম", "Kazi Nazrul Islam"), ("মাইকেল মধুসূদন দত্ত", "Michael Madhusudan Dutt"), ("সুফিয়া কামাল", "Sufia Kamal")], 0,
       ("জসীমউদ্দীনের বিখ্যাত কাহিনিকাব্য।", "It is Jasimuddin's famous narrative poem.")),
    _q("bn12", "bangla", ("'লালসালু' উপন্যাসের লেখক কে?", "Who wrote the novel 'Lalsalu'?"),
       [("সৈয়দ ওয়ালীউল্লাহ", "Syed Waliullah"), ("হুমায়ূন আহমেদ", "Humayun Ahmed"), ("শওকত ওসমান", "Shawkat Osman"), ("আখতারুজ্জামান ইলিয়াস", "Akhtaruzzaman Elias")], 0,
       ("'লালসালু' সৈয়দ ওয়ালীউল্লাহর লেখা।", "'Lalsalu' was written by Syed Waliullah.")),
    _q("bn13", "bangla", ("'শেষের কবিতা' কার লেখা?", "Who wrote 'Shesher Kobita'?"),
       [("রবীন্দ্রনাথ ঠাকুর", "Rabindranath Tagore"), ("বঙ্কিমচন্দ্র চট্টোপাধ্যায়", "Bankim Chandra Chattopadhyay"), ("শরৎচন্দ্র চট্টোপাধ্যায়", "Sarat Chandra Chattopadhyay"), ("জীবনানন্দ দাশ", "Jibanananda Das")], 0,
       ("উপন্যাসটি রবীন্দ্রনাথ ঠাকুরের।", "It is a novel by Rabindranath Tagore.")),
    _q("bn14", "bangla", ("বাংলা সাহিত্যের প্রথম উপন্যাস হিসেবে সাধারণত কোনটিকে ধরা হয়?", "Which work is usually counted as the first Bangla novel?"),
       [("আলালের ঘরের দুলাল", "Alaler Gharer Dulal"), ("দুর্গেশনন্দিনী", "Durgeshnandini"), ("পদ্মানদীর মাঝি", "Padma Nadir Majhi"), ("দেবদাস", "Devdas")], 0,
       ("প্যারীচাঁদ মিত্রের 'আলালের ঘরের দুলাল'-কে সাধারণত প্রথম উপন্যাস বলা হয়।", "Peary Chand Mitra's 'Alaler Gharer Dulal' is usually counted as the first.")),
    _q("bn15", "bangla", ("'দেবদাস' উপন্যাসের লেখক কে?", "Who wrote the novel 'Devdas'?"),
       [("শরৎচন্দ্র চট্টোপাধ্যায়", "Sarat Chandra Chattopadhyay"), ("রবীন্দ্রনাথ ঠাকুর", "Rabindranath Tagore"), ("মীর মশাররফ হোসেন", "Mir Mosharraf Hossain"), ("কায়কোবাদ", "Kaykobad")], 0,
       ("'দেবদাস' শরৎচন্দ্র চট্টোপাধ্যায়ের লেখা।", "'Devdas' was written by Sarat Chandra Chattopadhyay.")),
    _q("bn16", "bangla", ("'সূর্য' শব্দের সমার্থক শব্দ কোনটি?", "Which word means the same as the Bangla word 'surjo' (sun)?"),
       [("শশী", "shoshi (moon)"), ("রবি", "robi (sun)"), ("অনল", "onol (fire)"), ("নীর", "nir (water)")], 1,
       ("রবি, ভানু, দিবাকর — সবই সূর্যের সমার্থক।", "Robi, bhanu and dibakar all mean the sun.")),
    # ------------------------------------------------------------ english (16)
    _q("en01", "english", ("'Abundant' শব্দের সমার্থক কোনটি?", "Which word is a synonym of 'abundant'?"),
       ["scarce", "plentiful", "tiny", "empty"], 1,
       ("Abundant মানে প্রচুর — plentiful।", "Abundant means existing in large amounts — plentiful.")),
    _q("en02", "english", ("'Ancient' শব্দের বিপরীত শব্দ কোনটি?", "Which word is the opposite of 'ancient'?"),
       ["old", "historic", "modern", "aged"], 2,
       ("Ancient (প্রাচীন)-এর বিপরীত modern (আধুনিক)।", "The opposite of ancient is modern.")),
    _q("en03", "english", ("'Go' ক্রিয়ার past tense কোনটি?", "What is the past tense of 'go'?"),
       ["goed", "gone", "went", "going"], 2,
       ("go – went – gone।", "go – went – gone.")),
    _q("en04", "english", ("'Child' শব্দের বহুবচন কোনটি?", "What is the plural of 'child'?"),
       ["childs", "children", "childes", "childrens"], 1,
       ("Child-এর বহুবচন children।", "The plural of child is children.")),
    _q("en05", "english", ("কোন বানানটি সঠিক?", "Which spelling is correct?"),
       ["neccessary", "necesary", "necessary", "neccesary"], 2,
       ("সঠিক বানান necessary — একটি c, দুটি s।", "Correct: necessary — one c, two s.")),
    _q("en06", "english", ("শূন্যস্থান পূরণ করুন: She ___ to school every day.", "Fill in the blank: She ___ to school every day."),
       ["go", "goes", "going", "gone"], 1,
       ("Present indefinite-এ third person singular-এর সাথে verb-এ s/es যোগ হয়।", "Simple present with he/she/it adds -s/-es: goes.")),
    _q("en07", "english", ("সঠিক article বাছুন: He is ___ honest man.", "Choose the right article: He is ___ honest man."),
       ["a", "an", "the", "no article"], 1,
       ("Honest-এর h উচ্চারিত হয় না, স্বরধ্বনি দিয়ে শুরু তাই an।", "The h in honest is silent, so it starts with a vowel sound: an.")),
    _q("en08", "english", ("সঠিক preposition বাছুন: He is good ___ mathematics.", "Choose the right preposition: He is good ___ mathematics."),
       ["in", "on", "at", "with"], 2,
       ("good at — কোনো বিষয়ে দক্ষ।", "We say good at a subject or skill.")),
    _q("en09", "english", ("'Brave' শব্দের সমার্থক কোনটি?", "Which word is a synonym of 'brave'?"),
       ["fearful", "courageous", "lazy", "weak"], 1,
       ("Brave মানে সাহসী — courageous।", "Brave means courageous.")),
    _q("en10", "english", ("'Generous' শব্দের বিপরীত শব্দ কোনটি?", "Which word is the opposite of 'generous'?"),
       ["kind", "stingy", "rich", "gentle"], 1,
       ("Generous (উদার)-এর বিপরীত stingy (কৃপণ)।", "The opposite of generous is stingy.")),
    _q("en11", "english", ("শূন্যস্থান পূরণ করুন: If I ___ a bird, I would fly.", "Fill in the blank: If I ___ a bird, I would fly."),
       ["am", "was being", "were", "be"], 2,
       ("কাল্পনিক শর্তে সব person-এর সাথে were বসে।", "In an imaginary condition we use 'were' for every person.")),
    _q("en12", "english", ("'He writes a letter.' — passive voice কোনটি?", "What is the passive voice of 'He writes a letter.'?"),
       ["A letter was written by him.", "A letter is written by him.", "A letter is being written by him.", "A letter has written by him."], 1,
       ("Present indefinite-এর passive: is/am/are + past participle।", "Simple present passive: is/am/are + past participle.")),
    _q("en13", "english", ("'Look after' কথাটির অর্থ কী?", "What does 'look after' mean?"),
       ["search for", "take care of", "look behind", "admire"], 1,
       ("Look after মানে দেখাশোনা করা — take care of।", "Look after means to take care of.")),
    _q("en14", "english", ("কোন বানানটি সঠিক?", "Which spelling is correct?"),
       ["accomodation", "acommodation", "accommodation", "accommodasion"], 2,
       ("সঠিক বানান accommodation — দুটি c, দুটি m।", "Correct: accommodation — double c, double m.")),
    _q("en15", "english", ("নিচের কোনটি noun?", "Which of these is a noun?"),
       ["happy", "happily", "happiness", "happen"], 2,
       ("Happiness একটি abstract noun।", "Happiness is an abstract noun.")),
    _q("en16", "english", ("শূন্যস্থান পূরণ করুন: Neither of the boys ___ present.", "Fill in the blank: Neither of the boys ___ present."),
       ["were", "was", "are", "have been"], 1,
       ("Neither of + plural noun-এর পরে singular verb বসে: was।", "'Neither of' takes a singular verb: was.")),
    # ------------------------------------------------------------ math (16)
    _q("ma01", "math", ("২০০-এর ১৫% কত?", "What is 15% of 200?"), ["15", "20", "30", "45"], 2,
       ("২০০ × ১৫ ÷ ১০০ = ৩০।", "200 × 15 ÷ 100 = 30.")),
    _q("ma02", "math", ("৩/৪-কে শতকরায় প্রকাশ করলে কত হয়?", "What is 3/4 as a percentage?"), ["34%", "60%", "75%", "80%"], 2,
       ("৩ ÷ ৪ = ০.৭৫ = ৭৫%।", "3 ÷ 4 = 0.75 = 75%.")),
    _q("ma03", "math", ("৫০০০ টাকার ১০% হারে ২ বছরের সরল মুনাফা কত?", "What is the simple interest on Tk 5000 at 10% a year for 2 years?"),
       ["500", "1000", "1050", "1500"], 1,
       ("৫০০০ × ১০ × ২ ÷ ১০০ = ১০০০ টাকা।", "5000 × 10 × 2 ÷ 100 = Tk 1000.")),
    _q("ma04", "math", ("৪, ৮ ও ১২-এর গড় কত?", "What is the average of 4, 8 and 12?"), ["6", "8", "10", "12"], 1,
       ("(৪ + ৮ + ১২) ÷ ৩ = ৮।", "(4 + 8 + 12) ÷ 3 = 8.")),
    _q("ma05", "math", ("১৪৪-এর বর্গমূল কত?", "What is the square root of 144?"), ["11", "12", "13", "14"], 1,
       ("১২ × ১২ = ১৪৪।", "12 × 12 = 144.")),
    _q("ma06", "math", ("৪ ও ৬-এর ল.সা.গু. কত?", "What is the LCM of 4 and 6?"), ["2", "10", "12", "24"], 2,
       ("৪ ও ৬ দুটো দিয়েই বিভাজ্য সবচেয়ে ছোট সংখ্যা ১২।", "12 is the smallest number divisible by both.")),
    _q("ma07", "math", ("১৮ ও ২৪-এর গ.সা.গু. কত?", "What is the HCF of 18 and 24?"), ["3", "4", "6", "8"], 2,
       ("দুটোকেই নিঃশেষে ভাগ করে এমন সবচেয়ে বড় সংখ্যা ৬।", "6 is the largest number that divides both.")),
    _q("ma08", "math", ("৫টি কলমের দাম ৬০ টাকা হলে ৮টি কলমের দাম কত?", "If 5 pens cost Tk 60, how much do 8 pens cost?"),
       ["84", "90", "96", "100"], 2,
       ("১টির দাম ১২ টাকা, ৮টির ৯৬ টাকা।", "One pen costs Tk 12, so 8 cost Tk 96.")),
    _q("ma09", "math", ("ঘণ্টায় ৬০ কিমি বেগে ৩ ঘণ্টায় একটি ট্রেন কত দূর যাবে?", "A train goes 60 km an hour. How far does it go in 3 hours?"),
       [("120 কিমি", "120 km"), ("150 কিমি", "150 km"), ("180 কিমি", "180 km"), ("200 কিমি", "200 km")], 2,
       ("দূরত্ব = বেগ × সময় = ৬০ × ৩ = ১৮০ কিমি।", "Distance = speed × time = 60 × 3 = 180 km.")),
    _q("ma10", "math", ("ত্রিভুজের তিন কোণের সমষ্টি কত?", "What do the three angles of a triangle add up to?"),
       ["90°", "180°", "270°", "360°"], 1,
       ("যেকোনো ত্রিভুজের তিন কোণের সমষ্টি ১৮০°।", "The angles of any triangle add up to 180°.")),
    _q("ma11", "math", ("৮ মিটার লম্বা ও ৫ মিটার চওড়া আয়তক্ষেত্রের ক্ষেত্রফল কত?", "What is the area of a rectangle 8 m long and 5 m wide?"),
       [("13 বর্গমিটার", "13 sq m"), ("26 বর্গমিটার", "26 sq m"), ("40 বর্গমিটার", "40 sq m"), ("45 বর্গমিটার", "45 sq m")], 2,
       ("ক্ষেত্রফল = দৈর্ঘ্য × প্রস্থ = ৮ × ৫ = ৪০ বর্গমিটার।", "Area = length × width = 8 × 5 = 40 sq m.")),
    _q("ma12", "math", ("২⁵ = কত?", "What is 2⁵?"), ["10", "16", "25", "32"], 3,
       ("২ × ২ × ২ × ২ × ২ = ৩২।", "2 × 2 × 2 × 2 × 2 = 32.")),
    _q("ma13", "math", ("৪০০ টাকায় কেনা জিনিস ৫০০ টাকায় বিক্রি করলে লাভ শতকরা কত?", "An item bought for Tk 400 is sold for Tk 500. What is the profit percentage?"),
       ["20%", "25%", "30%", "100%"], 1,
       ("লাভ ১০০ টাকা; ১০০ ÷ ৪০০ × ১০০ = ২৫%।", "Profit Tk 100; 100 ÷ 400 × 100 = 25%.")),
    _q("ma14", "math", ("x + 7 = 15 হলে x = কত?", "If x + 7 = 15, what is x?"), ["7", "8", "9", "22"], 1,
       ("x = ১৫ − ৭ = ৮।", "x = 15 − 7 = 8.")),
    _q("ma15", "math", ("নিচের কোনটি মৌলিক সংখ্যা?", "Which of these is a prime number?"), ["21", "27", "29", "33"], 2,
       ("২৯-কে ১ ও ২৯ ছাড়া আর কিছু দিয়ে ভাগ করা যায় না।", "29 can be divided only by 1 and 29.")),
    _q("ma16", "math", ("৫০-কে ২ : ৩ অনুপাতে ভাগ করলে বড় অংশটি কত?", "If 50 is split in the ratio 2 : 3, what is the larger part?"),
       ["20", "25", "30", "35"], 2,
       ("মোট ৫ ভাগ; বড় অংশ ৫০ × ৩/৫ = ৩০।", "5 parts in all; the larger part is 50 × 3/5 = 30.")),
]
BY_ID = {q["id"]: q for q in BANK}


def _loc_q(q, lang, with_answer=False):
    i = 0 if lang == "bn" else 1
    conv = bn_digits if lang == "bn" else str
    out = {"id": q["id"], "topic": q["topic"], "q": conv(q["q"][i]),
           "options": [conv(o[i]) for o in q["opts"]]}
    if with_answer:
        out["answer"] = q["ans"]
        out["why"] = conv(q["why"][i])
    return out


def topics_public(lang):
    i = 0 if lang == "bn" else 1
    counts = {t: sum(1 for q in BANK if q["topic"] == t) for t in TOPICS}
    out = [{"id": t, "name": TOPIC_NAMES[t][i], "count": counts[t]} for t in TOPICS]
    out.append({"id": "mixed", "name": TOPIC_NAMES["mixed"][i], "count": len(BANK)})
    return out


def pick_round(topic, seed, lang, size=ROUND_SIZE):
    pool = [q for q in BANK if topic in ("mixed", "", None) or q["topic"] == topic]
    rnd = random.Random(seed)
    chosen = rnd.sample(pool, min(size, len(pool)))
    return [_loc_q(q, lang) for q in chosen]


def score(answers, lang):
    """answers: [{id, choice}] -> {total, correct, results:[{id, choice, answer, correct, why, q, options}]}.
    Unknown ids are ignored; a missing/invalid choice counts as wrong."""
    results, correct = [], 0
    seen = set()
    for a in answers or []:
        qid = str((a or {}).get("id") or "")
        q = BY_ID.get(qid)
        if not q or qid in seen:
            continue
        seen.add(qid)
        try:
            choice = int(a.get("choice"))
        except (TypeError, ValueError):
            choice = -1
        ok = choice == q["ans"]
        correct += 1 if ok else 0
        r = _loc_q(q, lang, with_answer=True)
        r.update(choice=choice, correct=ok)
        results.append(r)
    return {"total": len(results), "correct": correct, "results": results}
