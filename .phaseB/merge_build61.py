#!/usr/bin/env python3
"""Merge build-61 wave l10n keys into app_en.arb + app_bn.arb.

Sources:
  - .phaseB/m1_chatcore_arb.json      (circle chat-core)
  - .phaseB/m1_calls_privacy_arb.json (circle calls + privacy)
  - .phaseB/referral_arb.json         (referral points)
  - .phaseB/crm_firstrun_arb.json     (CRM first-run + error states)
  - Safe-Journey keys authored inline here (journey*/sos*/duress*/wellness*/fakeCall*)
  - new sidebar header keys

Keys authored as {key: [bn, en]}. Parameterized keys get @-metadata
(placeholders typed as Object, matching the repo convention). Idempotent:
existing keys are left untouched (only ADD missing ones).
"""
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
L10N = os.path.join(HERE, "..", "app", "lib", "l10n")
EN = os.path.join(L10N, "app_en.arb")
BN = os.path.join(L10N, "app_bn.arb")

PLACEHOLDER_RE = re.compile(r"\{(\w+)\}")

# ---- load JSON module ARBs ({key: [bn, en]}) ----
K = {}
for fn in ("m1_chatcore_arb.json", "m1_calls_privacy_arb.json",
           "referral_arb.json", "crm_firstrun_arb.json"):
    with open(os.path.join(HERE, fn), encoding="utf-8") as f:
        K.update(json.load(f))

# ---- Safe Journey (~90 keys) authored here [bn, en] ----
K.update({
    # hub / safety_screen
    "journeyHubTitle": ["নিরাপদ যাত্রা", "Safe Journey"],
    "journeyHubDesc": ["যাত্রা শুরু করুন, প্রিয়জন আপনাকে নিরাপদে পৌঁছাতে দেখবে।", "Start a journey and let loved ones watch you reach safely."],
    "journeySection": ["নিরাপদ যাত্রা", "Safe Journey"],
    # start screen
    "journeyStartTitle": ["যাত্রা শুরু করুন", "Start a journey"],
    "journeyStartButton": ["যাত্রা শুরু করুন", "Start journey"],
    "journeyStartFailed": ["যাত্রা শুরু করা যায়নি", "Couldn't start the journey"],
    "journeyDestSection": ["গন্তব্য", "Destination"],
    "journeyDestLabel": ["কোথায় যাচ্ছেন?", "Where are you going?"],
    "journeyUseCurrent": ["বর্তমান অবস্থান দিন", "Use current location"],
    "journeyDestPinned": ["পিন করা জায়গা", "Pinned location"],
    "journeyNeedDest": ["একটি গন্তব্য দিন।", "Please add a destination."],
    "journeyEtaSection": ["পৌঁছানোর সময়", "Expected arrival"],
    "journeyEtaBy": ["পৌঁছাব {time}-এর মধ্যে", "Arrive by {time}"],
    "journeyWatchersSection": ["যারা দেখবে", "Who's watching"],
    "journeyNoWatchers": ["আপনার সার্কেলে কেউ নেই। আগে কাউকে যুক্ত করুন।", "No one in your circle yet. Add someone first."],
    "journeyNeedWatcher": ["অন্তত একজনকে বেছে নিন।", "Choose at least one watcher."],
    "journeyRideSection": ["যানবাহনের তথ্য (ঐচ্ছিক)", "Ride details (optional)"],
    "journeyModeLabel": ["কীভাবে যাচ্ছেন?", "How are you traveling?"],
    "journeyModeCng": ["সিএনজি", "CNG"],
    "journeyModeRickshaw": ["রিকশা", "Rickshaw"],
    "journeyModeCar": ["গাড়ি", "Car"],
    "journeyModeBus": ["বাস", "Bus"],
    "journeyModeWalk": ["হেঁটে", "Walking"],
    "journeyPlateLabel": ["নম্বর প্লেট বা রাইড তথ্য", "Number plate or ride info"],
    "journeyAdvancedSection": ["আরও সেটিংস", "More settings"],
    "journeyGraceLabel": ["পৌঁছানোর পর {min} মিনিট অপেক্ষা করো", "Wait {min} minutes past arrival time"],
    "journeyRouteDeviation": ["পথ পরিবর্তনে সতর্কতা", "Alert on route deviation"],
    "journeyRouteDeviationDesc": ["নির্ধারিত পথ থেকে অনেক দূরে গেলে প্রিয়জন জানবে।", "Loved ones are notified if you stray far off route."],
    "journeyRetentionLabel": ["যাত্রার তথ্য {h} ঘণ্টা পর মুছে যাবে", "Trip data auto-deletes after {h} hours"],
    "journeyRetentionNote": ["যাত্রার লোকেশন শুধু যাত্রাকালে থাকে; এরপর সার্ভারে কিছু থাকে না।", "Location is kept only during the trip; nothing remains on the server afterward."],
    # live screen
    "journeyLiveTitle": ["যাত্রা চলছে", "Journey in progress"],
    "journeyLiveFooter": ["অ্যাপ খোলা থাকলে লোকেশন আপডেট হয়। যাত্রা শেষ হলে লাইভ লোকেশন বন্ধ হয়ে যাবে।", "Location updates while the app is open. Live location ends when the journey stops."],
    "journeyToward": ["{dest}-এর পথে", "Toward {dest}"],
    "journeyId": ["যাত্রা #{id}", "Journey #{id}"],
    "journeyLastFix": ["সর্বশেষ অবস্থান {at}", "Last location {at}"],
    "journeyWatchingNotif": ["Assisto আপনার যাত্রার দিকে খেয়াল রাখছে", "Assisto is watching your journey"],
    "journeyImSafe": ["আমি নিরাপদে পৌঁছেছি", "I've arrived safely"],
    "journeyImOk": ["আমি ঠিক আছি", "I'm OK"],
    "journeyArrivedSafely": ["নিরাপদে পৌঁছেছেন। যাত্রা শেষ।", "Arrived safely. Journey complete."],
    "journeyShareLink": ["লিঙ্ক শেয়ার করুন", "Share link"],
    "journeyShareLinkText": ["আমার যাত্রা লাইভ দেখুন: {url}", "Follow my journey live: {url}"],
    "journeyStop": ["যাত্রা থামান", "Stop journey"],
    "journeyStopTitle": ["যাত্রা থামাবেন?", "Stop the journey?"],
    "journeyStopBody": ["লাইভ লোকেশন বন্ধ হবে এবং যাত্রা শেষ হবে।", "Live location will stop and the journey will end."],
    "journeyStopConfirm": ["থামান", "Stop"],
    "journeyPrivacySection": ["গোপনীয়তা", "Privacy"],
    "journeyPrivacyStatement": ["আপনিই সব নিয়ন্ত্রণ করেন। যেকোনো সময় থামাতে পারেন। লোকেশন শুধু আপনার বেছে নেওয়া মানুষই দেখে।", "You control everything. Stop any time. Only the people you chose can see your location."],
    # overdue prompt
    "journeyAreYouOkTitle": ["আপনি কি ঠিক আছেন?", "Are you OK?"],
    "journeyAreYouOkBody": ["পৌঁছানোর সময় হয়ে গেছে। ঠিক থাকলে জানান, না হলে আপনার প্রিয়জনকে জানানো হবে।", "Your arrival time has passed. Let us know you're OK, otherwise your watchers will be alerted."],
    "journeyNeedHelp": ["আমার সাহায্য দরকার", "I need help"],
    # settings screen
    "journeySettingsTitle": ["নিরাপত্তা সেটিংস", "Safety settings"],
    # ---- SOS ----
    "sosSection": ["জরুরি সাহায্য (SOS)", "Emergency SOS"],
    "sosSending": ["জরুরি বার্তা পাঠানো হচ্ছে…", "Sending emergency alert…"],
    "sosSentTitle": ["সাহায্যের বার্তা পাঠানো হয়েছে", "Alert sent"],
    "sosSentBody": ["আপনার প্রিয়জনকে আপনার অবস্থান জানানো হয়েছে।", "Your watchers have been sent your location."],
    "sosCallNow": ["এখন ৯৯৯-এ কল করুন", "Call 999 now"],
    "sosCancel": ["বাতিল করুন", "Cancel"],
    "sosCancelNeedsPin": ["বাতিল করতে পিন দিন।", "Enter your PIN to cancel."],
    "sosShareText": ["জরুরি! আমার অবস্থান: {url}", "Emergency! My location: {url}"],
    "sosNearestHelp": ["কাছের সাহায্য", "Nearest help"],
    "sosNearestHelpLoading": ["কাছের থানা ও হাসপাতাল খোঁজা হচ্ছে…", "Finding nearby police and hospitals…"],
    "sosDistanceAway": ["{m} মিটার দূরে", "{m} m away"],
    "sosHelplines": ["হেল্পলাইন", "Helplines"],
    "sosPinTitle": ["পিন দিন", "Enter PIN"],
    "sosPinLabel": ["পিন", "PIN"],
    "sosPinWrong": ["ভুল পিন", "Wrong PIN"],
    "sosSiren": ["সাইরেন বাজান", "Sound siren"],
    "sosSirenDefault": ["ডিফল্ট সাইরেন", "Default siren"],
    "sosSirenDefaultDesc": ["SOS-এ জোরে সাইরেন বাজবে (সেটিংসে চালু/বন্ধ করা যায়)।", "A loud siren plays on SOS (toggle in settings)."],
    # ---- Duress PIN ----
    "duressSection": ["ডুরেস পিন", "Duress PIN"],
    "duressTitle": ["নিরাপত্তা পিন", "Safety PIN"],
    "duressSubtitle": ["যাত্রা থামাতে বা SOS বাতিল করতে পিন লাগে।", "A PIN is needed to stop a journey or cancel an SOS."],
    "duressExplain": ["আলাদা ডুরেস পিন দিলে স্ক্রিন বাতিল দেখাবে, কিন্তু চুপিসারে প্রিয়জনকে জরুরি বার্তা ও লোকেশন যাবে।", "Entering the separate duress PIN makes the screen look cancelled while silently sending an emergency alert and location to your watchers."],
    "duressNormalPin": ["সাধারণ পিন", "Normal PIN"],
    "duressDuressPin": ["ডুরেস পিন", "Duress PIN"],
    "duressMustDiffer": ["ডুরেস পিন সাধারণ পিন থেকে আলাদা হতে হবে।", "The duress PIN must differ from the normal PIN."],
    "duressSetUp": ["পিন সেট করুন", "Set up PIN"],
    "duressSaved": ["পিন সংরক্ষিত হয়েছে", "PIN saved"],
    "duressConfigured": ["পিন সেট করা আছে", "PIN is set"],
    "duressNotSet": ["এখনো পিন সেট করা হয়নি", "No PIN set yet"],
    # ---- Fake call ----
    "fakeCallTitle": ["নকল কল", "Fake call"],
    "fakeCallSetup": ["নকল কল সেট করুন", "Set up a fake call"],
    "fakeCallCaller": ["কলারের নাম", "Caller name"],
    "fakeCallDefaultName": ["মা", "Mom"],
    "fakeCallStart": ["নকল কল শুরু করুন", "Start fake call"],
    "fakeCallArmed": ["{sec} সেকেন্ডে কল আসবে", "Call rings in {sec} seconds"],
    "fakeCallIncoming": ["ইনকামিং কল", "Incoming call"],
    "fakeCallAnswer": ["ধরুন", "Answer"],
    "fakeCallDecline": ["কেটে দিন", "Decline"],
    "fakeCallEnd": ["কল শেষ করুন", "End call"],
    # ---- Wellness check ----
    "wellnessSection": ["সুস্থতা যাচাই", "Wellness check"],
    "wellnessIntro": ["বাবা-মা একা থাকলে দীর্ঘ সময় কোনো সাড়া না পেলে সন্তানদের জানানো হবে।", "If a parent living alone is inactive for a long time, their children are alerted."],
    "wellnessEnable": ["সুস্থতা যাচাই চালু করুন", "Enable wellness check"],
    "wellnessParentOptIn": ["বাবা-মায়ের সম্মতি", "Parent's consent"],
    "wellnessParentOptInDesc": ["শুধু বাবা-মা নিজে সম্মতি দিলেই এটি চালু হবে।", "This only turns on with the parent's own consent."],
    "wellnessPeriod": ["{h} ঘণ্টা নিষ্ক্রিয় থাকলে", "After {h} hours of inactivity"],
    "wellnessQuietHours": ["নীরব সময় (রাতে বিরক্ত করবে না)", "Quiet hours (won't disturb at night)"],
    # ---- SOS native hooks (power-button/shake/tile/widget/service — key-gated) ----
    "sosHooksSection": ["দ্রুত SOS চালু করার উপায়", "Quick SOS triggers"],
    "sosHookPowerTitle": ["পাওয়ার বোতাম ৫ বার", "Press power 5 times"],
    "sosHookPowerDesc": ["পাওয়ার বোতাম দ্রুত ৫ বার চাপলে চুপিসারে SOS যাবে।", "Pressing power quickly 5 times fires a silent SOS."],
    "sosHookShakeTitle": ["ফোন ঝাঁকান", "Shake the phone"],
    "sosHookShakeDesc": ["ফোন জোরে ঝাঁকালে SOS চালু হবে।", "Shaking the phone hard triggers an SOS."],
    "sosHookTileTitle": ["কুইক টাইল", "Quick-settings tile"],
    "sosHookTileDesc": ["লক স্ক্রিন বা কুইক সেটিংস থেকে এক চাপে SOS।", "One tap from the lock screen or quick settings."],
    "sosHookWidgetTitle": ["হোম স্ক্রিন উইজেট", "Home-screen widget"],
    "sosHookWidgetDesc": ["লুকানো উইজেট থেকে চট করে SOS পাঠান।", "Fire a quick SOS from a discreet widget."],
    "sosHookServiceTitle": ["ব্যাকগ্রাউন্ড সেবা", "Background service"],
    "sosHookServiceDesc": ["অ্যাপ বন্ধ থাকলেও যাত্রা ও SOS কাজ করার জন্য দরকার।", "Needed so journeys and SOS keep working when the app is closed."],
    "sosHookGated": ["পরবর্তী আপডেটে চালু হবে।", "Coming in a later update."],
    "safetySosQuickCall": ["দ্রুত কল", "Quick call"],
    # ---- sidebar headers / top / bottom ----
    "sidebarRemindersMemory": ["রিমাইন্ডার ও মেমোরি", "Reminders & Memory"],
    "sidebarSafety": ["নিরাপত্তা", "Safety"],
    "sidebarDaily": ["দৈনন্দিন জীবন", "Daily Life"],
    "sidebarMessages": ["মেসেজ", "Messages"],
    "sidebarPlansPoints": ["প্ল্যান ও পয়েন্ট", "Plans & points"],
    "sidebarProfile": ["প্রোফাইল", "Profile"],
    "sidebarConnectedApps": ["কানেক্টেড অ্যাপ", "Connected apps"],
    "sidebarBatteryGuidance": ["ব্যাটারি গাইড", "Battery guidance"],
})


def arb_meta_for(key, value):
    """Return @-metadata dict if value has {placeholders}, else None."""
    names = PLACEHOLDER_RE.findall(value)
    if not names:
        return None
    return {"placeholders": {n: {"type": "Object"} for n in dict.fromkeys(names)}}


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def main():
    en = load(EN)
    bn = load(BN)
    added = 0
    for key, (bnval, enval) in K.items():
        if key in en and key in bn:
            continue
        en[key] = enval
        bn[key] = bnval
        meta = arb_meta_for(key, enval)
        if meta is not None:
            en["@" + key] = meta
            bn["@" + key] = meta
        added += 1
    with open(EN, "w", encoding="utf-8") as f:
        json.dump(en, f, ensure_ascii=False, indent=2)
        f.write("\n")
    with open(BN, "w", encoding="utf-8") as f:
        json.dump(bn, f, ensure_ascii=False, indent=2)
        f.write("\n")
    enk = {k for k in en if not k.startswith("@")}
    bnk = {k for k in bn if not k.startswith("@")}
    print(f"added {added} keys")
    print(f"en keys={len(enk)} bn keys={len(bnk)} parity={'OK' if enk == bnk else 'MISMATCH'}")
    if enk != bnk:
        print("en-only:", sorted(enk - bnk))
        print("bn-only:", sorted(bnk - enk))


if __name__ == "__main__":
    main()
