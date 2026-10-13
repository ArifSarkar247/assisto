#!/usr/bin/env python3
"""Merge module-5 l10n keys into app_en.arb + app_bn.arb.

Keys are authored here as {key: [bn, en]}. Parameterized keys get @-metadata
(placeholders typed as Object, matching the repo convention). Idempotent:
existing keys are left untouched (we only ADD missing ones) to avoid clobbering
earlier authored values.
"""
import json
import os

L10N = os.path.join(os.path.dirname(__file__), "..", "app", "lib", "l10n")
EN = os.path.join(L10N, "app_en.arb")
BN = os.path.join(L10N, "app_bn.arb")

# key -> [bn, en]
K = {
    # ---------------- Health (health_arb.json, 41) ----------------
    "healthTipsTitle": ["স্বাস্থ্য টিপস", "Health tips"],
    "healthTipsSearchHint": ["টিপস খুঁজুন", "Search tips"],
    "healthTipsAllTopics": ["সব বিষয়", "All topics"],
    "healthTipsNoResults": ["কোনো টিপস পাওয়া যায়নি", "No tips found"],
    "healthTipsLoadError": ["টিপস লোড করা যায়নি", "Couldn't load tips"],
    "healthTipsSourcesLine": ["সূত্র: {sources}", "Sources: {sources}"],
    "healthTipSourceLine": ["সূত্র: {source}", "Source: {source}"],
    "healthEmergencyCheckLabel": ["জরুরি লক্ষণ যাচাই (রোগ নির্ণয় নয়)", "Red-flag check (not a diagnosis)"],
    "healthEmergencyCheckHint": ["উপসর্গ লিখুন, যেমন বুকে ব্যথা", "Type a symptom, e.g. chest pain"],
    "healthEmergencyCheckButton": ["যাচাই করুন", "Check"],
    "healthEmergencyNoRedFlags": ["কোনো জরুরি লক্ষণ পাওয়া যায়নি। সমস্যা থাকলে ডাক্তার দেখান।", "No red-flag signs found. See a doctor if the problem persists."],
    "medicineDbTitle": ["ওষুধের তথ্যভান্ডার", "Medicine database"],
    "medicineDbSearchHint": ["ব্র্যান্ড বা জেনেরিক খুঁজুন", "Search brand or generic"],
    "medicineDbIntroTitle": ["ওষুধ খুঁজুন", "Look up a medicine"],
    "medicineDbIntroBody": ["ব্র্যান্ড বা জেনেরিক নাম লিখে ওষুধের তথ্য ও বিকল্প দেখুন।", "Type a brand or generic name to see details and alternatives."],
    "medicineDbUses": ["ব্যবহার", "Uses"],
    "medicineDbHowToTake": ["সেবনবিধি", "How to take"],
    "medicineDbAlternativesTitle": ["বিকল্প ({count})", "Alternatives ({count})"],
    "medicineDbAlternativesNote": ["ডাক্তার/ফার্মাসিস্টের পরামর্শ ছাড়া ওষুধ বদলাবেন না।", "Do not switch medicines without a doctor's or pharmacist's advice."],
    "medicineDbLoadError": ["তথ্য লোড করা যায়নি", "Couldn't load data"],
    "medicineDbNeedsDataTitle": ["কিছু পাওয়া যায়নি", "Nothing found"],
    "medicineDbNeedsDataBody": ["চালু হবে যখন DGDA ডাটা যুক্ত হবে।", "Available when DGDA data is added."],
    "birthdaysTitle": ["জন্মদিন ও স্মরণীয় দিন", "Birthdays & memorable days"],
    "birthdaysAdd": ["নতুন যোগ করুন", "Add"],
    "birthdaysEmptyTitle": ["কোনো দিন যোগ করা হয়নি", "No days added yet"],
    "birthdaysEmptyBody": ["প্রিয়জনের জন্মদিন বা বিশেষ দিন যোগ করুন—আগে থেকেই মনে করিয়ে দেব।", "Add a loved one's birthday or special day — we'll remind you ahead of time."],
    "birthdaysLoadError": ["লোড করা যায়নি", "Couldn't load"],
    "birthdayNameLabel": ["নাম", "Name"],
    "birthdayPickDate": ["তারিখ বাছুন", "Pick a date"],
    "birthdayDateChosen": ["তারিখ: {date}", "Date: {date}"],
    "birthdayLeadDaysLabel": ["{days} দিন আগে মনে করিয়ে দাও", "Remind {days} day(s) before"],
    "birthdaySaveError": ["সংরক্ষণ করা যায়নি", "Couldn't save"],
    "birthdayToday": ["আজ", "Today"],
    "birthdayTomorrow": ["আগামীকাল", "Tomorrow"],
    "birthdayInDays": ["{days} দিন পর", "In {days} days"],
    "birthdayTurningAge": ["{age} বছর হচ্ছে", "turning {age}"],
    "birthdayWishAction": ["শুভেচ্ছা", "Wish"],
    "birthdayDraftsTitle": ["শুভেচ্ছার খসড়া", "Wish drafts"],
    "birthdayDraftsSubtitle": ["বেছে নিয়ে কপি বা শেয়ার করুন—স্বয়ংক্রিয়ভাবে পাঠানো হবে না।", "Pick one to copy or share — nothing is sent automatically."],
    "birthdayDraftError": ["খসড়া তৈরি করা যায়নি", "Couldn't create a draft"],
    "birthdayShare": ["শেয়ার", "Share"],

    # ---------------- Life: Meetings ----------------
    "meetingsTitle": ["মিটিং ও অ্যাপয়েন্টমেন্ট", "Meetings & appointments"],
    "meetingsAdd": ["নতুন মিটিং", "New meeting"],
    "meetingsEmptyTitle": ["কোনো মিটিং নেই", "No meetings yet"],
    "meetingsEmptyBody": ["মিটিং বা অ্যাপয়েন্টমেন্ট যোগ করুন—আগেভাগে মনে করিয়ে দেব।", "Add a meeting or appointment — we'll remind you ahead of time."],
    "meetingsFieldTitle": ["বিষয়/শিরোনাম", "Title"],
    "meetingsFieldPlace": ["স্থান", "Place"],
    "meetingsFieldDuration": ["সময়কাল", "Duration"],
    "meetingsFieldNote": ["নোট", "Note"],
    "meetingsMinutes": ["{m} মিনিট", "{m} min"],
    "meetingsTitleRequired": ["শিরোনাম লিখুন", "Please enter a title"],
    "meetingsConflict": ["সময় মিলে যাচ্ছে—আরেকটি মিটিংয়ের সাথে সংঘাত", "Overlaps with another meeting"],
    "leaveNowTravelTitle": ["যাত্রার সময়", "Travel time"],
    "leaveNowTravelHint": ["আনুমানিক কত মিনিট লাগবে লিখুন—আমরা নিজে থেকে ট্রাফিক অনুমান করি না।", "Enter your best estimate in minutes — we never invent traffic."],
    "leaveNowTravelLabel": ["মিনিট", "Minutes"],
    "leaveNowAddTravel": ["যাত্রার সময় যোগ করুন", "Add travel time"],
    "leaveNowOpenMaps": ["ম্যাপে দিকনির্দেশ", "Directions in Maps"],
    "leaveNowGo": ["এখনই রওনা দিন", "Leave now"],
    "leaveNowIn": ["{m} মিনিট পর রওনা দিন", "Leave in {m} min"],
    "leaveNowDirections": ["দিকনির্দেশ", "Directions"],

    # ---------------- Life: Dictionary ----------------
    "dictionaryTitle": ["অভিধান", "Dictionary"],
    "dictionarySearchHint": ["শব্দ খুঁজুন", "Search a word"],
    "dictionaryDirAuto": ["স্বয়ংক্রিয়", "Auto"],
    "dictionaryDirBnEn": ["বাংলা → English", "Bangla → English"],
    "dictionaryDirEnBn": ["English → বাংলা", "English → Bangla"],
    "dictionaryIntroTitle": ["শব্দের অর্থ খুঁজুন", "Look up a word"],
    "dictionaryIntroBody": ["বাংলা বা English শব্দ লিখুন—অর্থ ও উদাহরণ দেখুন।", "Type a Bangla or English word to see meaning and examples."],
    "dictionaryNeedsOpenData": ["পূর্ণ অভিধান চালু হবে যখন উন্মুক্ত-লাইসেন্সের ডাটা যুক্ত হবে।", "The full dictionary is available when open-license data is added."],
    "dictionaryNotFound": ["\"{q}\" পাওয়া যায়নি", "No result for \"{q}\""],
    "dictionarySampleNote": ["এটি একটি ছোট নমুনা—সাধারণ কিছু শব্দ শুধু।", "This is a small sample — common words only."],
    "dictionarySourceNote": ["সূত্র: {src}", "Source: {src}"],

    # ---------------- Life: Ride & Food ----------------
    "rideFoodTitle": ["রাইড ও খাবার", "Ride & food"],
    "rideFoodDeepLinkNote": ["আমরা সরাসরি প্রোভাইডারের অ্যাপ খুলি—কোনো নকল দাম বা তথ্য দেখাই না।", "We open the provider's own app — we never show fake prices or info."],
    "rideFoodDestLabel": ["গন্তব্য বা খাবার", "Destination or food"],
    "rideFoodDestHelper": ["রাইডের জন্য গন্তব্য, খাবারের জন্য রেস্টুরেন্ট/খাবার লিখুন।", "Enter a destination for a ride, or a restaurant/food to order."],
    "rideFoodRideSection": ["রাইড", "Ride"],
    "rideFoodFoodSection": ["খাবার", "Food"],
    "rideFoodOpen": ["খুলুন", "Open"],
    "rideFoodOpenInApp": ["প্রোভাইডারের অ্যাপে খুলুন", "Open in the provider's app"],
    "rideFoodInAppComing": ["অ্যাপের ভেতর বুকিং চালু হবে পার্টনার যুক্ত হলে।", "In-app booking is available when a partner is connected."],

    # ---------------- Life: Ramadan ----------------
    "ramadanTitle": ["রমজান মোড", "Ramadan mode"],
    "ramadanRefresh": ["অবস্থান নিয়ে সময় হালনাগাদ করুন", "Refresh times from location"],
    "ramadanLocationNeeded": ["সময় দেখাতে অবস্থানের অনুমতি দরকার।", "Location permission is needed to show times."],
    "ramadanFetchFailed": ["সময় আনা যায়নি। পরে চেষ্টা করুন।", "Couldn't fetch times. Try again later."],
    "ramadanSehri": ["সেহরি শেষ", "Sehri ends"],
    "ramadanIftar": ["ইফতার", "Iftar"],
    "ramadanMethodNote": ["হিসাবের পদ্ধতি: {method} (জ্যোতির্বৈজ্ঞানিক অনুমান—স্থানীয় কমিটির সময় ভিন্ন হতে পারে)।", "Calculation method: {method} (astronomical estimate — local committee times may differ)."],
    "ramadanFajr": ["ফজর", "Fajr"],
    "ramadanDhuhr": ["যোহর", "Dhuhr"],
    "ramadanAsr": ["আসর", "Asr"],
    "ramadanMaghrib": ["মাগরিব", "Maghrib"],
    "ramadanIsha": ["এশা", "Isha"],
    "ramadanAlarmsSection": ["সতর্কতা", "Alarms"],
    "ramadanSehriWake": ["সেহরির জন্য জাগানোর অ্যালার্ম", "Sehri wake-up alarm"],
    "ramadanSehriWakeValue": ["{min} মিনিট আগে ({time})", "{min} min before ({time})"],
    "ramadanIftarAlert": ["ইফতারের আগাম সতর্কতা", "Iftar heads-up"],
    "ramadanIftarAlertValue": ["{min} মিনিট আগে ({time})", "{min} min before ({time})"],
    "ramadanWakeCallComing": ["সেহরির জন্য ফোন-কলে জাগানো চালু হবে টেলিফোনি পার্টনার যুক্ত হলে।", "A wake-up phone call for sehri is available when a telephony partner is connected."],
    "ramadanZakat": ["যাকাত হিসাব", "Zakat calculator"],
    "ramadanZakatSubtitle": ["ফিন্যান্সের যাকাত হিসাব ব্যবহার করুন।", "Uses the Finance zakat calculator."],
    "ramadanZakatOpenFinance": ["ফিন্যান্স থেকে যাকাত হিসাব খুলুন।", "Open the zakat calculator in Finance."],
    "ramadanEidSection": ["ঈদের শুভেচ্ছা ও সালামি", "Eid greeting & salami"],
    "eidGreeting": ["শুভেচ্ছা", "Greeting"],
    "eidSalami": ["সালামি", "Salami"],
    "eidToLabel": ["প্রাপক (কাকে)", "To (recipient)"],
    "eidFromLabel": ["প্রেরক (কার পক্ষ থেকে)", "From (sender)"],
    "eidAmountLabel": ["সালামির পরিমাণ (৳)", "Salami amount (৳)"],
    "eidGenerate": ["খসড়া তৈরি করুন", "Create a draft"],
    "eidDraftLabel": ["খসড়া (সম্পাদনা করা যাবে)", "Draft (editable)"],
    "eidEditableNote": ["সম্পাদনা করে নিজে শেয়ার করুন—স্বয়ংক্রিয়ভাবে পাঠানো হবে না।", "Edit and share it yourself — nothing is sent automatically."],
    "eidShare": ["শেয়ার", "Share"],

    # ---------------- Life: Exam ----------------
    "examTitle": ["পরীক্ষার ফলাফল", "Exam result"],
    "examWatcherSection": ["ফলাফল পর্যবেক্ষণ", "Result watcher"],
    "examLabelField": ["নাম/লেবেল (যেমন SSC ২০২৬)", "Label (e.g. SSC 2026)"],
    "examUrlField": ["সরকারি ফলাফলের ঠিকানা (URL)", "Public result URL"],
    "examUrlHelper": ["শুধু প্রকাশ্য পেজ—আমরা লগইনের পেছনে কিছু দেখি না।", "Public page only — we never look behind a login."],
    "examUrlInvalid": ["সঠিক ঠিকানা দিন (http বা https)", "Enter a valid URL (http or https)"],
    "examUrlOrDateRequired": ["একটি ঠিকানা বা তারিখ দিন", "Enter a URL or a date"],
    "examPickDate": ["সম্ভাব্য তারিখ বাছুন", "Pick an expected date"],
    "examExpectedOn": ["সম্ভাব্য তারিখ: {d}", "Expected on {d}"],
    "examWatch": ["পর্যবেক্ষণ শুরু করুন", "Start watching"],
    "examWatcherSaved": ["পর্যবেক্ষণ সংরক্ষিত হয়েছে", "Watcher saved"],
    "examWatcherSavedLocal": ["এই ডিভাইসে সংরক্ষিত হয়েছে", "Saved on this device"],
    "examWaiting": ["ফলাফলের জন্য অপেক্ষা—আর {days} দিন", "Waiting for the result — {days} day(s) to go"],
    "examTrafficSpikeNote": ["ফলাফলের দিনে সাইটে ভিড় বেশি থাকে—একটু পর আবার চেষ্টা করুন।", "Result sites get very busy on result day — try again shortly."],
    "examCardSection": ["ফলাফল কার্ড", "Result card"],
    "examCardNote": ["শুধু আপনার দেওয়া তথ্য দিয়ে কার্ড তৈরি হয়।", "Built only from the details you enter."],
    "examCardDefaultHeader": ["পরীক্ষার ফলাফল", "Exam result"],
    "examFieldName": ["নাম", "Name"],
    "examFieldRoll": ["রোল", "Roll"],
    "examFieldBoard": ["বোর্ড", "Board"],
    "examFieldGpa": ["জিপিএ/ফলাফল", "GPA/Result"],
    "examShareCard": ["কার্ড শেয়ার করুন", "Share card"],

    # ---------------- Launch gaps: Password reset ----------------
    "resetTitle": ["পাসওয়ার্ড রিসেট", "Reset password"],
    "resetIntro": ["আপনার অ্যাকাউন্টের ইমেইল দিন—রিসেট লিংক পাঠানো হবে।", "Enter your account email — we'll send a reset link."],
    "resetEmailLabel": ["ইমেইল", "Email"],
    "resetSendLink": ["রিসেট লিংক পাঠান", "Send reset link"],
    "resetNeutralSent": ["অ্যাকাউন্ট থাকলে একটি রিসেট লিংক পাঠানো হয়েছে।", "If an account exists, a reset link has been sent."],
    "resetSmsUnavailable": ["SMS দিয়ে রিসেট চালু হবে SMS গেটওয়ে যুক্ত হলে।", "SMS reset is available when an SMS gateway is added."],
    "resetSecurityNote": ["নিরাপত্তার জন্য অ্যাকাউন্ট আছে কি না তা আমরা জানাই না।", "For security, we never reveal whether an account exists."],
    "resetSetNewTitle": ["নতুন পাসওয়ার্ড দিন", "Set a new password"],
    "resetSetNewIntro": ["আপনার নতুন পাসওয়ার্ড লিখুন।", "Enter your new password."],
    "resetNewPassword": ["নতুন পাসওয়ার্ড", "New password"],
    "resetConfirmPassword": ["পাসওয়ার্ড আবার লিখুন", "Confirm password"],
    "resetPasswordHint": ["কমপক্ষে ৮টি অক্ষর ব্যবহার করুন।", "Use at least 8 characters."],
    "resetPasswordTooShort": ["পাসওয়ার্ড কমপক্ষে ৮টি অক্ষরের হতে হবে", "Password must be at least 8 characters"],
    "resetPasswordMismatch": ["দুটি পাসওয়ার্ড মিলছে না", "Passwords don't match"],
    "resetLinkInvalid": ["লিংকটি ভুল বা মেয়াদোত্তীর্ণ।", "This link is invalid or expired."],
    "resetDoneMessage": ["পাসওয়ার্ড পরিবর্তন হয়েছে। এখন লগইন করুন।", "Password changed. You can now sign in."],
    "resetBackToLogin": ["লগইনে ফিরে যান", "Back to login"],
    "resetForgotLink": ["পাসওয়ার্ড ভুলে গেছেন?", "Forgot password?"],

    # ---------------- Launch gaps: Legal ----------------
    "legalTitle": ["আইনি ও নীতিমালা", "Legal & policies"],
    "legalOffline": ["লোড করা যায়নি। সংযোগ দেখে আবার চেষ্টা করুন।", "Couldn't load. Check your connection and retry."],
    "legalLastUpdated": ["সর্বশেষ হালনাগাদ", "Last updated"],

    # ---------------- Launch gaps: Photo enhance ----------------
    "photoTitle": ["ছবি উন্নত করুন", "Enhance photo"],
    "photoNeverDocuments": ["শুধু নিজের সাধারণ ছবি—কোনো আইডি বা দলিল নয়।", "Your own ordinary photos only — never an ID or official document."],
    "photoPickHint": ["শুরু করতে একটি ছবি বাছুন", "Pick a photo to begin"],
    "photoFromGallery": ["গ্যালারি থেকে", "From gallery"],
    "photoFromCamera": ["ক্যামেরা দিয়ে", "From camera"],
    "photoConfirmOwn": ["এটি আমার নিজের ছবি", "This is my own photo"],
    "photoConfirmNotDocument": ["ছবির ধরন", "Photo type"],
    "photoKindPersonal": ["সাধারণ ছবি", "Personal photo"],
    "photoKindDocument": ["আইডি/দলিল", "ID / document"],
    "photoOpsLabel": ["যেসব উন্নতি (বিশ্বস্ত, বানানো নয়)", "Improvements (faithful, nothing fabricated)"],
    "photoOpDenoise": ["নয়েজ কমানো", "Reduce noise"],
    "photoOpSharpen": ["শার্প করা", "Sharpen"],
    "photoOpAutoLevels": ["অটো-লেভেল", "Auto levels"],
    "photoOpContrast": ["কনট্রাস্ট", "Contrast"],
    "photoOpUpscale": ["রেজল্যুশন বাড়ানো", "Upscale"],
    "photoCloudActive": ["ক্লাউডে উন্নত প্রক্রিয়াকরণ চালু।", "Higher-quality cloud processing is active."],
    "photoCloudUnavailable": ["উন্নত ক্লাউড প্রক্রিয়াকরণ চালু হবে প্রোভাইডার যুক্ত হলে—এখন ডিভাইসেই হবে।", "Higher-quality cloud processing is available when a provider is connected — for now it runs on-device."],
    "photoEnhanceButton": ["উন্নত করুন", "Enhance"],
    "photoBlocked": ["এই ছবিতে এটি করা যাবে না।", "This isn't allowed for this photo."],
    "photoOffline": ["এখন করা গেল না। পরে চেষ্টা করুন।", "Couldn't do that now. Try again later."],
    "photoReady": ["প্রস্তুত—উন্নত করা শুরু করা যাবে।", "Ready — enhancement can start."],

    # ---------------- Launch gaps: Unseen World ----------------
    "unseenTitle": ["অদেখা বাংলাদেশ", "Unseen Bangladesh"],
    "unseenOffline": ["লোড করা যায়নি। আবার চেষ্টা করুন।", "Couldn't load. Try again."],
    "unseenDestinations": ["গন্তব্য", "Destinations"],
    "unseenBestSeason": ["সেরা সময়", "Best season"],
    "unseenTip": ["পরামর্শ", "Tip"],
    "unseenSource": ["সূত্র", "Source"],
    "unseenTravelTips": ["ভ্রমণ পরামর্শ", "Travel tips"],

    # ---------------- Connected Circle ----------------
    "circleTitle": ["পরিবার-বন্ধু সার্কেল", "Connected circle"],
    "circleAdd": ["যোগ করুন", "Add"],
    "circleAddTitle": ["সার্কেলে যোগ করুন", "Add to your circle"],
    "circleRelationQuestion": ["সম্পর্ক কী?", "What's the relationship?"],
    "circleCustomRelationHint": ["সম্পর্ক লিখুন", "Type the relationship"],
    "circlePhoneLabel": ["ফোন নম্বর", "Phone number"],
    "circleSendRequest": ["অনুরোধ পাঠান", "Send request"],
    "circleQrInvite": ["QR দিয়ে আমন্ত্রণ", "Invite by QR"],
    "circleNoContactUpload": ["আমরা আপনার কনট্যাক্ট লিস্ট আপলোড করি না।", "We never upload your contact list."],
    "circleInviteUnavailable": ["আমন্ত্রণ লিংক তৈরি করা যায়নি।", "Couldn't create an invite link."],
    "circlePendingRequests": ["অপেক্ষমাণ অনুরোধ", "Pending requests"],
    "circleYourCircle": ["আপনার সার্কেল", "Your circle"],
    "circleEmptyTitle": ["সার্কেল এখনো খালি", "Your circle is empty"],
    "circleEmptyBody": ["প্রিয়জনদের যোগ করুন—সব বার্তা এন্ড-টু-এন্ড এনক্রিপ্টেড থাকবে।", "Add loved ones — every message stays end-to-end encrypted."],
    "circleBackendPending": ["সার্কেল চালু হবে সার্ভার সংযোগ হলে।", "The circle is available once the server is connected."],
    "circleAccept": ["গ্রহণ করুন", "Accept"],
    "circleDecline": ["প্রত্যাখ্যান করুন", "Decline"],
    "circleBlock": ["ব্লক করুন", "Block"],
    "circleReport": ["রিপোর্ট করুন", "Report"],
    "circleReported": ["রিপোর্ট জমা হয়েছে", "Report submitted"],
    "circleReportSpam": ["স্প্যাম", "Spam"],
    "circleReportHarassment": ["হয়রানি", "Harassment"],
    "circleReportScam": ["প্রতারণা", "Scam"],
    "circleReportImpersonation": ["পরিচয় জালিয়াতি", "Impersonation"],
    "circleReportOther": ["অন্যান্য", "Other"],
    "circleSharingTitle": ["কে কী দেখবে", "Who sees what"],
    "circleSharingHint": ["এই সম্পর্কের জন্য কোন তথ্য দেখানো যাবে তা বেছে নিন।", "Choose what this relation is allowed to see."],
    "circleScopeMedicines": ["ওষুধ", "Medicines"],
    "circleScopeLocation": ["অবস্থান", "Location"],
    "circleScopeDocuments": ["দলিলপত্র", "Documents"],
    "circleScopeMoney": ["টাকা-পয়সা", "Money"],
    "circleScopeProfile": ["প্রোফাইল", "Profile"],
    "circleRelFather": ["বাবা", "Father"],
    "circleRelMother": ["মা", "Mother"],
    "circleRelChild": ["সন্তান", "Child"],
    "circleRelHusband": ["স্বামী", "Husband"],
    "circleRelWife": ["স্ত্রী", "Wife"],
    "circleRelBrother": ["ভাই", "Brother"],
    "circleRelSister": ["বোন", "Sister"],
    "circleRelRelative": ["আত্মীয়", "Relative"],
    "circleRelFriend": ["বন্ধু", "Friend"],
    "circleRelColleague": ["সহকর্মী", "Colleague"],
    "circleRelCustom": ["অন্যান্য", "Custom"],
    "circleE2eBanner": ["এই চ্যাট এন্ড-টু-এন্ড এনক্রিপ্টেড—সার্ভার বা এর এআই কিছু পড়তে পারে না।", "This chat is end-to-end encrypted — the server and its AI can't read it."],
    "circleChatEmpty": ["কথা শুরু করুন—সব বার্তা এনক্রিপ্টেড থাকবে।", "Start the conversation — every message stays encrypted."],
    "circleMessageHint": ["বার্তা লিখুন", "Message"],
    "circleDecryptFailed": ["এই বার্তাটি ডিক্রিপ্ট করা যায়নি।", "Couldn't decrypt this message."],
    "circleKeyMissing": ["এই সদস্যের এনক্রিপশন কী এখনো পাওয়া যায়নি।", "This member's encryption key isn't available yet."],
    "circleAttach": ["যুক্ত করুন", "Attach"],
    "circlePhoto": ["ছবি", "Photo"],
    "circleVoiceNote": ["ভয়েস নোট", "Voice note"],
    "circleVideo": ["ভিডিও", "Video"],
    "circleVoiceCall": ["ভয়েস কল", "Voice call"],
    "circleMediaPhotoGated": ["ছবি পাঠানো চালু হবে এনক্রিপ্টেড স্টোরেজ যুক্ত হলে।", "Sending photos is available when encrypted storage is enabled."],
    "circleMediaVoiceGated": ["ভয়েস নোট চালু হবে এনক্রিপ্টেড স্টোরেজ যুক্ত হলে।", "Voice notes are available when encrypted storage is enabled."],
    "circleMediaVideoGated": ["ভিডিও চালু হবে এনক্রিপ্টেড স্টোরেজ যুক্ত হলে।", "Video is available when encrypted storage is enabled."],
    "circleCallGated": ["ভয়েস কল চালু হবে কল সার্ভার যুক্ত হলে।", "Voice calls are available when the call server is enabled."],
    "circleComingSoon": ["শীঘ্রই আসছে।", "Coming soon."],
}

# parameterized keys -> list of placeholder names
PARAMS = {
    "healthTipsSourcesLine": ["sources"],
    "healthTipSourceLine": ["source"],
    "medicineDbAlternativesTitle": ["count"],
    "birthdayDateChosen": ["date"],
    "birthdayLeadDaysLabel": ["days"],
    "birthdayInDays": ["days"],
    "birthdayTurningAge": ["age"],
    "meetingsMinutes": ["m"],
    "leaveNowIn": ["m"],
    "dictionaryNotFound": ["q"],
    "dictionarySourceNote": ["src"],
    "ramadanMethodNote": ["method"],
    "ramadanSehriWakeValue": ["min", "time"],
    "ramadanIftarAlertValue": ["min", "time"],
    "examExpectedOn": ["d"],
    "examWaiting": ["days"],
}


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def merge(path, idx):
    data = load(path)
    added = 0
    for key, pair in K.items():
        if key in data:
            continue
        data[key] = pair[idx]
        if key in PARAMS:
            data["@" + key] = {
                "placeholders": {p: {"type": "Object"} for p in PARAMS[key]}
            }
        added += 1
    # sort keys so @meta sits logically; json preserves insertion, keep as-is
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    return added, len([k for k in data if not k.startswith("@")])


a_bn, n_bn = merge(BN, 0)
a_en, n_en = merge(EN, 1)
print(f"en: added {a_en}, total non-@ keys {n_en}")
print(f"bn: added {a_bn}, total non-@ keys {n_bn}")
assert n_en == n_bn, f"PARITY FAIL en={n_en} bn={n_bn}"
print("parity OK")
