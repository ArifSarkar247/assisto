# বিল্ড মেশিন বদল: পাবলিক রিপো ↔ প্রাইভেট রিপো

**মূল নিয়ম:** রিপো **পাবলিক** থাকলে কখনো নিজস্ব (self-hosted) রানার চালু রাখা যাবে না — পাবলিক রিপো + self-hosted রানার মানে যেকেউ pull request দিয়ে আমাদের সার্ভারে কোড চালাতে পারে। রিপো **প্রাইভেট** থাকলে GitHub-এর মেশিনে মিনিটের খরচ লাগে — তখন নিজস্ব রানার।

## A. এখন (পাবলিক হওয়ার আগে) যা করা হয়েছে
- সব ওয়ার্কফ্লো `runs-on: ubuntu-latest` (GitHub-এর মেশিন); এমুলেটর লঞ্চ-টেস্ট আবার প্রতিটি বিল্ডে চালু।
- কোনো ওয়ার্কফ্লো `pull_request` বা `pull_request_target`-এ চলে না (fork PR কিছুই চালাতে পারে না)।
- ওয়ার্কফ্লো টোকেনের ডিফল্ট অনুমতি: শুধু read।
- নিজস্ব রানার সার্ভিস **বন্ধ ও disabled** (`actions.runner.ArifSarkar247-assisto.assisto-box`), রানারের ব্যান্ডউইথ-সীমা সার্ভিসও বন্ধ।
- Play আপলোডের চাবি GitHub-এ নেই — সার্ভারের `owner_private`-এ (git-এর বাইরে); সাইনিং কী শুধু GitHub encrypted secrets-এ।

## B. রিপো পাবলিক করার পর (২৫ Oct — সব করা হয়েছে ✅)
1. GitHub Settings → Actions → "Fork pull request workflows from outside collaborators" → **Require approval for all outside collaborators** (API: `gh api -X PUT repos/ArifSarkar247/assisto/actions/permissions/fork-pr-contributor-approval -f approval_policy=all_external_contributors` — প্রাইভেট রিপোতে GitHub এটা সেট করতে দেয় না)।
2. iOS আর Shop Box ওয়ার্কফ্লো আবার চালু (`gh workflow enable ios.yml`, `gh workflow enable shopbox.yml`)।
3. অপেক্ষমাণ বিল্ড আবার চালানো → Internal + Closed testing।

## C. পরে রিপো আবার প্রাইভেট করলে — ঠিক এই ধাপগুলো
1. **আপনি:** GitHub → repo Settings → General → Danger Zone → Change visibility → **Private**।
2. **আপনি:** নতুন রানার রেজিস্ট্রেশন টোকেন বানান: repo Settings → Actions → Runners → **New self-hosted runner** → Linux → পাতায় দেখানো টোকেন কপি করে সার্ভারে `~/owner_private/gh_runner_token`-এ রাখুন (১ ঘণ্টা বৈধ)। **এটা লাগবেই** — পাবলিক করার সময় (২৫ Oct) রানারটি GitHub থেকে পুরোপুরি মুছে (deregister) দেওয়া হয়েছে আর সার্ভিস-ফাইলও সরানো হয়েছে।
3. **আমি:** `sudo -u ghrunner ./config.sh --unattended --url https://github.com/ArifSarkar247/assisto --token <টোকেন> --name assisto-box --labels assisto-box`, তারপর `sudo ./svc.sh install ghrunner`, আগের কম-অগ্রাধিকারের drop-in (Nice 19, CPU-ওজন ২০, ১.৭ CPU, ৫ GB) আবার বসানো, `sudo systemctl enable --now assisto-runner-shape.service`, `.env`-এ job hook দুটো আবার; শেষে টোকেন ফাইল shred করে মুছে ফেলা। রানার প্রোগ্রাম, Android SDK আর hook স্ক্রিপ্ট সার্ভারে রাখা আছে (`/home/ghrunner`)।
4. **আমি:** `android.yml`-এ build-apk আবার `runs-on: [self-hosted, assisto-box]`, আর এমুলেটর লঞ্চ-টেস্ট + x86_64 APK আবার শুধু হাতে চালানো (`if: github.event_name == 'workflow_dispatch'` — এই সার্ভারে `/dev/kvm` নেই)। আগের self-hosted সংস্করণ রাখা আছে: git ইতিহাসে কমিট "CI on self-hosted runner"।
5. **আমি:** GitHub-এর uptime/Reality/iOS/Shop Box ওয়ার্কফ্লো বন্ধ রাখা (প্রাইভেটে মিনিট খায়); uptime সার্ভারের cron-এ চলতেই থাকবে।
6. **আমি:** একটা বিল্ড চালিয়ে যাচাই — রানার সর্বনিম্ন অগ্রাধিকারে (nice 19, CPU-ওজন ২০, ১.৭ CPU, ৫ GB), ৫ GB-র কম খালি থাকলে বিল্ড শুরু হয় না, প্রতিটি বিল্ডের পর পরিষ্কার; তারপর Play-তে আপলোড।

## যাচাইয়ের ফলাফল (পাবলিকের আগে, ২৫ Oct)
- **পুরো ইতিহাসে গোপন তথ্য স্ক্যান (gitleaks 8.30.1, ৫৬৬টি কমিট, সব ব্রাঞ্চ):** ৪টি সন্দেহ — সবই টেস্টের নকল মান (`pw-long-123456`, `tok-SECRET-123456`, `sk-ant-TESTONLY`, একটি সেটিং-নামের স্ট্রিং)। আলাদা খোঁজ: কোনো private key, keystore, google-services.json, service-account JSON, .env ফাইল, Google/OpenAI/AWS/GitHub টোকেন ইতিহাসে নেই; Play reviewer-এর আসল নম্বর/পাসওয়ার্ড/OTP ইতিহাসে নেই; সার্ভারের গোপন মানগুলোর কোনোটিই নেই (শুধু পাবলিক তথ্য: অ্যাপ সার্টিফিকেটের fingerprint, কল সার্ভারের পাবলিক IP, প্রতিষ্ঠানের ঠিকানা)।
- **সতর্কতা:** পুরনো কমিটে আপনার নাম/ব্যক্তিগত ইমেইল/ফোন নম্বর এখনো আছে (আপনি ইতিহাস না বদলানোর সিদ্ধান্ত নিয়েছেন) — পাবলিক হলে সেগুলো আবার দেখা যাবে। বর্তমান ফাইল থেকে সরানো আছে।
- পাবলিক হলে পুরনো Actions লগ আর ৩০ দিনের artifact (APK/AAB) দেখা যাবে — লগে গোপন মান GitHub নিজে ঢেকে রাখে; APK এমনিতেই ওয়েবসাইটে পাবলিক।
