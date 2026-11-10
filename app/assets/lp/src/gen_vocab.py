#!/usr/bin/env python3
"""Builds app/assets/lp/vocab_v1.json (original Assisto word lists)."""
import json, re, sys

T = []

def topic(id, group, icon, en, bn, words):
    items = []
    for w, pos, b, ex in words:
        wid = id + "_" + re.sub(r"[^a-z0-9]+", "_", w.lower()).strip("_")
        items.append({"id": wid, "w": w, "pos": pos, "bn": b, "ex": ex})
    T.append({"id": id, "group": group, "icon": icon, "title_en": en, "title_bn": bn, "words": items})

topic("ielts_education", "ielts", "school", "Education", "শিক্ষা", [
    ("curriculum", "n", "পাঠ্যক্রম", "The school changed its curriculum to include coding."),
    ("compulsory", "adj", "বাধ্যতামূলক", "Primary education is compulsory in many countries."),
    ("tuition", "n", "পড়ার খরচ / টিউশন", "University tuition has risen sharply."),
    ("literacy", "n", "সাক্ষরতা", "Adult literacy rates have improved in rural areas."),
    ("vocational", "adj", "কারিগরি / বৃত্তিমূলক", "Vocational training prepares students for skilled jobs."),
    ("assessment", "n", "মূল্যায়ন", "Continuous assessment reduces exam stress."),
    ("discipline", "n", "শৃঙ্খলা", "Some parents believe schools need stricter discipline."),
    ("graduate", "n/v", "স্নাতক / পাস করে বের হওয়া", "Many graduates struggle to find their first job."),
    ("scholarship", "n", "বৃত্তি", "She won a full scholarship to study abroad."),
    ("rote learning", "n", "মুখস্থ করে শেখা", "Rote learning does not build critical thinking."),
    ("enrol", "v", "ভর্তি হওয়া", "More girls now enrol in secondary school."),
    ("academic", "adj", "শিক্ষাগত / একাডেমিক", "Academic success is not the only goal of school.")])

topic("ielts_environment", "ielts", "eco", "Environment", "পরিবেশ", [
    ("pollution", "n", "দূষণ", "Air pollution is a serious problem in large cities."),
    ("emission", "n", "নির্গমন (ধোঁয়া/গ্যাস বের হওয়া)", "Cars are a major source of carbon emissions."),
    ("renewable", "adj", "নবায়নযোগ্য", "Solar power is a renewable source of energy."),
    ("deforestation", "n", "বন উজাড়", "Deforestation destroys the homes of many animals."),
    ("sustainable", "adj", "টেকসই", "We need sustainable ways to grow food."),
    ("conservation", "n", "সংরক্ষণ", "Water conservation is important during dry seasons."),
    ("flood", "n/v", "বন্যা", "Floods affect millions of people every year."),
    ("climate change", "n", "জলবায়ু পরিবর্তন", "Climate change is raising sea levels."),
    ("waste", "n", "বর্জ্য / আবর্জনা", "Plastic waste blocks city drains."),
    ("recycle", "v", "পুনর্ব্যবহার করা", "Many households now recycle paper and glass."),
    ("habitat", "n", "প্রাণীর বাসস্থান", "The tiger's habitat is shrinking."),
    ("drought", "n", "খরা", "Drought reduced the rice harvest this year.")])

topic("ielts_technology", "ielts", "devices", "Technology", "প্রযুক্তি", [
    ("innovation", "n", "উদ্ভাবন", "Innovation in mobile banking has helped rural families."),
    ("device", "n", "যন্ত্র / ডিভাইস", "Most teenagers own at least one digital device."),
    ("automation", "n", "স্বয়ংক্রিয়করণ", "Automation may replace some factory jobs."),
    ("access", "n/v", "ব্যবহারের সুযোগ / প্রবেশ", "Not everyone has access to fast internet."),
    ("privacy", "n", "গোপনীয়তা", "Social media raises concerns about privacy."),
    ("artificial intelligence", "n", "কৃত্রিম বুদ্ধিমত্তা", "Artificial intelligence can translate languages instantly."),
    ("addictive", "adj", "আসক্তি তৈরি করে এমন", "Some games are designed to be addictive."),
    ("remote", "adj", "দূর থেকে / দূরবর্তী", "Remote work became common after 2020."),
    ("obsolete", "adj", "অচল / পুরনো হয়ে যাওয়া", "Old phones quickly become obsolete."),
    ("breakthrough", "n", "বড় সাফল্য / যুগান্তকারী আবিষ্কার", "The vaccine was a medical breakthrough."),
    ("rely on", "v", "নির্ভর করা", "Many people rely on their phones for directions."),
    ("cyber security", "n", "সাইবার নিরাপত্তা", "Banks invest heavily in cyber security.")])

topic("ielts_health", "ielts", "health_and_safety", "Health", "স্বাস্থ্য", [
    ("obesity", "n", "স্থূলতা", "Childhood obesity is increasing in cities."),
    ("sedentary", "adj", "বসে থাকা / কম নড়াচড়ার", "A sedentary lifestyle harms the heart."),
    ("nutrition", "n", "পুষ্টি", "Good nutrition helps children learn better."),
    ("epidemic", "n", "মহামারি", "Dengue became an epidemic last monsoon."),
    ("life expectancy", "n", "গড় আয়ু", "Life expectancy has risen over the last fifty years."),
    ("preventive", "adj", "প্রতিরোধমূলক", "Preventive care is cheaper than treatment."),
    ("mental health", "n", "মানসিক স্বাস্থ্য", "Schools should support students' mental health."),
    ("vaccinate", "v", "টিকা দেওয়া", "Most children are vaccinated against measles."),
    ("diet", "n", "খাদ্যাভ্যাস", "A balanced diet includes vegetables and protein."),
    ("well-being", "n", "সুস্থতা ও ভালো থাকা", "Exercise improves physical and mental well-being."),
    ("chronic", "adj", "দীর্ঘস্থায়ী (রোগ)", "Diabetes is a chronic disease."),
    ("healthcare", "n", "স্বাস্থ্যসেবা", "Free healthcare is a basic right in some countries.")])

topic("ielts_work", "ielts", "business_center", "Work and economy", "কাজ ও অর্থনীতি", [
    ("employment", "n", "কর্মসংস্থান", "The factory created employment for local people."),
    ("unemployment", "n", "বেকারত্ব", "Youth unemployment is a global concern."),
    ("income", "n", "আয়", "Remittance is a major source of income for many families."),
    ("remittance", "n", "প্রবাসী আয় (রেমিট্যান্স)", "Remittance from workers abroad supports the economy."),
    ("productivity", "n", "উৎপাদনশীলতা", "Flexible hours can increase productivity."),
    ("inflation", "n", "মূল্যস্ফীতি", "Inflation makes daily goods more expensive."),
    ("entrepreneur", "n", "উদ্যোক্তা", "Young entrepreneurs are starting online shops."),
    ("workforce", "n", "কর্মীবাহিনী", "Women now form a large part of the workforce."),
    ("promotion", "n", "পদোন্নতি", "She received a promotion after two years."),
    ("job satisfaction", "n", "কাজে সন্তুষ্টি", "Job satisfaction matters more than salary to some people."),
    ("export", "n/v", "রপ্তানি", "Garments are the country's biggest export."),
    ("invest", "v", "বিনিয়োগ করা", "The government should invest in skills training.")])

topic("ielts_society", "ielts", "groups", "Society and culture", "সমাজ ও সংস্কৃতি", [
    ("urbanisation", "n", "নগরায়ণ", "Rapid urbanisation causes housing shortages."),
    ("migration", "n", "অভিবাসন / স্থানান্তর", "Migration from villages to cities is rising."),
    ("tradition", "n", "ঐতিহ্য / প্রথা", "Many traditions are passed down through families."),
    ("generation", "n", "প্রজন্ম", "The younger generation spends more time online."),
    ("inequality", "n", "বৈষম্য", "Income inequality has grown in many countries."),
    ("community", "n", "সমাজ / জনগোষ্ঠী", "Local communities organise flood relief."),
    ("crime", "n", "অপরাধ", "Street lights help reduce crime at night."),
    ("heritage", "n", "ঐতিহ্য (সাংস্কৃতিক সম্পদ)", "Old buildings are part of our cultural heritage."),
    ("globalisation", "n", "বিশ্বায়ন", "Globalisation has changed what people eat."),
    ("elderly", "adj/n", "বয়স্ক", "Families often care for elderly parents at home."),
    ("volunteer", "n/v", "স্বেচ্ছাসেবক", "Students volunteer at local hospitals."),
    ("diversity", "n", "বৈচিত্র্য", "Big cities are known for cultural diversity.")])

topic("ielts_linking", "ielts", "link", "Linking words (Writing)", "সংযোগ শব্দ (লেখার জন্য)", [
    ("however", "adv", "তবে / তবুও", "Cars are convenient. However, they cause pollution."),
    ("moreover", "adv", "তাছাড়া / অধিকন্তু", "Moreover, public transport saves money."),
    ("therefore", "adv", "সুতরাং / তাই", "Prices rose; therefore, sales fell."),
    ("although", "conj", "যদিও", "Although it was raining, the match continued."),
    ("for instance", "phr", "যেমন / উদাহরণস্বরূপ", "For instance, many students study online."),
    ("in contrast", "phr", "বিপরীতে", "In contrast, rural schools have fewer teachers."),
    ("as a result", "phr", "এর ফলে", "As a result, traffic became worse."),
    ("on the other hand", "phr", "অন্যদিকে", "On the other hand, cities offer more jobs."),
    ("in conclusion", "phr", "শেষ কথা হলো / উপসংহারে", "In conclusion, both views have merit."),
    ("whereas", "conj", "অথচ / যেখানে", "Men preferred football, whereas women chose cricket."),
    ("consequently", "adv", "ফলস্বরূপ", "Consequently, the government raised taxes."),
    ("despite", "prep", "সত্ত্বেও", "Despite the cost, many families buy cars.")])

topic("ielts_graphs", "ielts", "show_chart", "Describing graphs (Task 1)", "গ্রাফ বর্ণনা (টাস্ক ১)", [
    ("increase", "n/v", "বৃদ্ধি / বাড়া", "There was a sharp increase in sales in 2020."),
    ("decline", "n/v", "হ্রাস / কমে যাওয়া", "The number of visitors declined steadily."),
    ("fluctuate", "v", "ওঠানামা করা", "Prices fluctuated throughout the year."),
    ("peak", "n/v", "সর্বোচ্চ বিন্দু / চূড়ায় ওঠা", "Usage peaked at 80 percent in July."),
    ("remain stable", "phr", "স্থির থাকা", "The figure remained stable at around 40."),
    ("proportion", "n", "অনুপাত / অংশ", "A large proportion of students walked to school."),
    ("approximately", "adv", "প্রায় / আনুমানিক", "Approximately half of the workers were women."),
    ("gradually", "adv", "ধীরে ধীরে", "The population gradually rose."),
    ("dramatically", "adv", "নাটকীয়ভাবে / ব্যাপকভাবে", "Costs fell dramatically after 2015."),
    ("overall", "adv", "সামগ্রিকভাবে", "Overall, car ownership increased in all countries."),
    ("respectively", "adv", "যথাক্রমে", "The figures were 20 and 30 percent respectively."),
    ("double", "v", "দ্বিগুণ হওয়া", "The number of users doubled in five years.")])

topic("life_daily", "life", "wb_sunny", "Daily life", "দৈনন্দিন জীবন", [
    ("rent", "n/v", "ভাড়া", "The rent is due on the first of the month."),
    ("neighbour", "n", "প্রতিবেশী", "My neighbour helped me carry the boxes."),
    ("laundry", "n", "কাপড় ধোয়া", "I do my laundry every Friday."),
    ("grocery", "n", "মুদি জিনিস", "I buy groceries after work."),
    ("bill", "n", "বিল", "The electricity bill is high this month."),
    ("appointment", "n", "সাক্ষাতের সময়", "I made an appointment with the dentist."),
    ("borrow", "v", "ধার নেওয়া", "Can I borrow your charger?"),
    ("lend", "v", "ধার দেওয়া", "Could you lend me some money until Friday?"),
    ("queue", "n/v", "লাইন / লাইনে দাঁড়ানো", "Please wait in the queue."),
    ("on time", "phr", "সময়মতো", "The bus arrived on time."),
    ("repair", "v", "মেরামত করা", "The landlord will repair the tap tomorrow."),
    ("recharge", "v", "রিচার্জ করা", "I need to recharge my phone balance.")])

topic("life_food", "life", "restaurant", "Food and eating out", "খাবার ও রেস্টুরেন্ট", [
    ("menu", "n", "মেনু / খাবারের তালিকা", "Could we see the menu, please?"),
    ("order", "v/n", "অর্ডার করা", "I would like to order chicken rice."),
    ("spicy", "adj", "ঝাল", "Is this curry very spicy?"),
    ("vegetarian", "adj/n", "নিরামিষ", "Do you have any vegetarian dishes?"),
    ("halal", "adj", "হালাল", "Is this meat halal?"),
    ("takeaway", "n", "নিয়ে যাওয়ার খাবার", "I will take it as a takeaway."),
    ("bill", "n", "বিল", "Can we have the bill, please?"),
    ("tip", "n", "বকশিশ", "Is a tip included in the bill?"),
    ("allergy", "n", "অ্যালার্জি", "I have a nut allergy."),
    ("fresh", "adj", "তাজা", "The fish is fresh today."),
    ("portion", "n", "পরিমাণ / এক প্লেট", "The portion is big enough for two."),
    ("tap water", "n", "কলের পানি", "Is the tap water safe to drink?")])

topic("life_workplace", "life", "engineering", "Workplace abroad", "বিদেশে কর্মস্থল", [
    ("supervisor", "n", "সুপারভাইজার / তত্ত্বাবধায়ক", "Ask your supervisor before you leave."),
    ("overtime", "n", "ওভারটাইম / অতিরিক্ত কাজের সময়", "Overtime is paid at a higher rate."),
    ("payslip", "n", "বেতনের স্লিপ", "Check your payslip every month."),
    ("safety helmet", "n", "সেফটি হেলমেট", "Always wear a safety helmet on site."),
    ("injury", "n", "আঘাত", "Report any injury to the safety officer."),
    ("day off", "n", "ছুটির দিন", "Friday is my day off."),
    ("contract", "n", "চুক্তিপত্র", "Read the contract before you sign it."),
    ("work permit", "n", "কাজের অনুমতিপত্র", "Keep a copy of your work permit."),
    ("deadline", "n", "শেষ সময়সীমা", "The deadline for this job is Monday."),
    ("complaint", "n", "অভিযোগ", "You can make a complaint to the labour office."),
    ("instruction", "n", "নির্দেশনা", "Follow the instructions on the machine."),
    ("colleague", "n", "সহকর্মী", "My colleague showed me how to use the machine.")])

topic("life_emergency", "life", "emergency", "Emergency and safety", "জরুরি অবস্থা ও নিরাপত্তা", [
    ("help", "n/v", "সাহায্য", "Help! Please call the police."),
    ("police", "n", "পুলিশ", "I need to report a theft to the police."),
    ("ambulance", "n", "অ্যাম্বুলেন্স", "Call an ambulance, he is not breathing well."),
    ("fire exit", "n", "আগুন লাগলে বের হওয়ার পথ", "Where is the nearest fire exit?"),
    ("stolen", "adj", "চুরি হওয়া", "My wallet was stolen on the train."),
    ("lost", "adj", "হারানো / পথ হারানো", "I am lost. Can you help me?"),
    ("embassy", "n", "দূতাবাস", "Please contact the Bangladesh embassy."),
    ("injured", "adj", "আহত", "Two people were injured in the accident."),
    ("urgent", "adj", "জরুরি", "It is urgent, please hurry."),
    ("witness", "n", "সাক্ষী", "Were there any witnesses?"),
    ("insurance", "n", "বিমা", "Does my insurance cover this?"),
    ("first aid", "n", "প্রাথমিক চিকিৎসা", "Is there a first aid kit here?")])

topic("life_money", "life", "payments", "Money and payments", "টাকা-পয়সা ও লেনদেন", [
    ("cash", "n", "নগদ টাকা", "Do you accept cash?"),
    ("card", "n", "কার্ড", "Can I pay by card?"),
    ("cash machine", "n", "এটিএম", "Is there a cash machine near here?"),
    ("exchange", "v/n", "বদলানো / বিনিময়", "Where can I exchange dollars?"),
    ("salary", "n", "বেতন", "My salary is paid on the last day of the month."),
    ("save", "v", "সঞ্চয় করা", "I save some money every month."),
    ("loan", "n", "ঋণ", "I do not want to take a loan."),
    ("receipt", "n", "রসিদ", "Please keep the receipt."),
    ("deduct", "v", "কেটে নেওয়া", "Tax is deducted from my salary."),
    ("PIN", "n", "পিন নম্বর", "Never share your PIN with anyone."),
    ("fraud", "n", "প্রতারণা", "Report card fraud to the bank at once."),
    ("budget", "n", "বাজেট / খরচের হিসাব", "Make a budget for food and rent.")])

out = {"version": 1, "language": "en", "beta": False, "topics": T}
ids = [w["id"] for t in T for w in t["words"]]
assert len(ids) == len(set(ids)), "dup id"
json.dump(out, open(sys.argv[1], "w"), ensure_ascii=False, indent=1)
print("ok", len(T), len(ids))
