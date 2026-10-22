# Google Play App Signing — Assisto-র সাইনিং কী পরিকল্পনা

> লিখেছে: l1-launch (২২ অক্টোবর ২০২৬)। এখানে কোনো পাসওয়ার্ড বা কী নেই — রিপো পাবলিক।
> কোনো ধাপে সন্দেহ হলে থামুন; ভুল কী আপলোড করলে পরে বদলানো কঠিন।

## ১. দুই ধরনের কী — সহজ ভাষায়

| | কী কাজ | কার কাছে থাকে | হারালে কী হয় |
|---|---|---|---|
| **App signing key (অ্যাপ সাইনিং কী)** | ব্যবহারকারীর ফোনে যে অ্যাপ যায়, সেটি এই কী দিয়ে সাইন হয়। Android এই সই দেখে বোঝে "এটা একই অ্যাপের আপডেট"। | Play App Signing চালু হলে **Google নিরাপদে রাখে**। | Google-এর কাছে থাকলে হারানোর ভয় নেই। |
| **Upload key (আপলোড কী)** | আমরা Play Console-এ যে AAB আপলোড করি, শুধু সেটিতে সই। Google দেখে নেয় আপলোডটা সত্যিই আমাদের। | আমাদের কাছে (CI-এর GitHub secret + আপনার অফলাইন কপি)। | Play Console থেকে **রিসেট করা যায়** (§৬)। |

নতুন অ্যাপের জন্য Google Play **বাধ্যতামূলকভাবে** Play App Signing ব্যবহার করে এবং AAB (.aab) ফাইল চায় — APK নয়।

## ২. আমাদের কাছে এখন কোন কী আছে (সত্যি কথা)

- CI-এর "Sign APK with permanent release key" ধাপ প্রতিটি APK একটি **স্থায়ী release key** দিয়ে সাইন করে।
- এই কী রাখা আছে GitHub Actions secret-এ: `ANDROID_KEYSTORE_B64` (PKCS12 / `.p12` ফাইল, base64), `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`। ফাইলের ধরন **PKCS12** (`--ks-type PKCS12`), `.jks` নয়।
- **lifeassisto.com থেকে যত APK মানুষ ইনস্টল করেছেন (বিল্ড ১০৩, ১৪৬ … ১৫০ ইত্যাদি), সবই এই একই কী দিয়ে সাইন করা।** তাই এই কী-ই আমাদের অ্যাপের "পরিচয়"।
- এর SHA-256 ফিঙ্গারপ্রিন্ট (পাবলিক, গোপন নয়) প্রতিটি CI রানের লগে আছে — "Sign APK" ধাপে `apksigner verify --print-certs` লাইনের `SHA-256 digest`। এটিই `ANDROID_CERT_SHA256` (App Links / assetlinks.json) এবং Firebase-এ লাগে।
- সতর্কতা: সার্ভারের `migration/backup.sh` শুধু `*.jks` ফাইল খোঁজে — আমাদের `.p12` কী সেখানে ধরা পড়ে না। **কী-এর একটি অফলাইন কপি আপনার কাছে আছে কিনা নিশ্চিত করুন** (§৫)। GitHub secret থেকে ফাইলটি আর পড়ে বের করা যায় না।

## ৩. আমাদের পরামর্শ (Plan A) — পুরনো কী Google-কে দিন, নতুন upload key বানান

কেন: যাঁরা ওয়েবসাইট থেকে APK বসিয়েছেন, Play-এর অ্যাপ যদি **একই কী** দিয়ে সাইন হয়, তাহলে তাঁরা আনইনস্টল না করেই Play থেকে আপডেট পাবেন (ফোনের লোকাল ডেটা থাকবে)। অন্য কী হলে Android বলবে "সই মেলে না" — তাঁদের আনইনস্টল করে আবার বসাতে হবে।

1. Play Console → **Create app** → অ্যাপ তৈরি করুন (প্যাকেজ নাম হবে `com.assisto.assisto`, প্রথম আপলোডে ঠিক হয়ে যায়, পরে বদলানো যায় না)।
2. **Test and release → Setup → App signing** (বা প্রথম রিলিজ তৈরির সময় "App integrity") → **Choose signing key** → **Use a different key / Export and upload a key from Java keystore**।
3. সেখানে দেখানো **PEPK tool** (`pepk.jar`) এবং **encryption public key** (`encryption_public_key.pem`) নামান।
4. আপনার নিজের কম্পিউটারে (সার্ভারে নয়, রিপোতে নয়) যেখানে `.p12` কী আছে:
   ```
   java -jar pepk.jar --keystore=assisto-release.p12 --alias=<ANDROID_KEY_ALIAS> \
        --output=assisto-signing-key.zip --include-cert --rsa-aes-encryption \
        --encryption-key-path=encryption_public_key.pem
   ```
   পাসওয়ার্ড চাইলে keystore ও key পাসওয়ার্ড দিন। তৈরি হওয়া `assisto-signing-key.zip` Play Console-এ আপলোড করুন।
5. **নতুন upload key** বানান (একই কম্পিউটারে):
   ```
   keytool -genkeypair -v -storetype PKCS12 -keystore upload-keystore.p12 \
           -alias upload -keyalg RSA -keysize 4096 -validity 10000
   keytool -export -rfc -keystore upload-keystore.p12 -alias upload -file upload_certificate.pem
   ```
   একই পাতায় "upload key certificate" হিসেবে `upload_certificate.pem` আপলোড করুন।
6. GitHub রিপো → Settings → Secrets and variables → Actions-এ চারটি নতুন secret যোগ করুন (নাম হুবহু):
   `PLAY_UPLOAD_KEYSTORE_B64` (`base64 -w0 upload-keystore.p12`-এর আউটপুট), `PLAY_UPLOAD_KEYSTORE_PASSWORD`, `PLAY_UPLOAD_KEY_ALIAS` (= `upload`), `PLAY_UPLOAD_KEY_PASSWORD`।
   পুরনো `ANDROID_KEYSTORE_*` secret **মুছবেন না** — ওয়েবসাইটের APK সেগুলো দিয়েই সাইন হতে থাকবে।
7. CI-তে AAB ধাপ যোগ হলে (`.phaseB/proposals/l1-launch.md`, অংশ A) প্রতিটি রানে `assisto-aab` আর্টিফ্যাক্ট আসবে, upload key দিয়ে সাইন করা। লগে "signed with: play-upload-key" দেখবেন।
8. App signing পাতায় Google দুটি সার্টিফিকেট দেখাবে। **App signing key certificate**-এর SHA-256 এখনকার release key-এর SHA-256-এর সাথে হুবহু মিলবে — মিলিয়ে নিন।

## ৪. বিকল্প (Plan B) — এখনকার কী-ই upload key, Google নতুন app signing key বানাবে

সহজ (PEPK লাগে না): Play Console-এ "Use Google-generated key" রাখুন, CI-এর AAB এখনকার release key দিয়েই সাইন হবে (নতুন secret না দিলে প্রস্তাবিত ধাপ নিজেই তাই করে)।
খারাপ দিক: Play-এর অ্যাপের সই আলাদা হবে — ওয়েবসাইট-APK ব্যবহারকারীদের **আনইনস্টল করে Play থেকে আবার বসাতে হবে** (সার্ভারের ডেটা থাকবে, ফোনের লোকাল ডেটা যাবে)। আর App Links-এর জন্য `ANDROID_CERT_SHA256`-এ Google-এর নতুন app signing SHA-256 **কমা দিয়ে যোগ** করতে হবে, Firebase প্রজেক্টেও।
→ আমাদের পরামর্শ Plan A, কারণ বিদ্যমান ব্যবহারকারী আছেন।

## ৫. কী নিরাপদ রাখা (দুই প্ল্যানেই)

- `.p12` ফাইল + পাসওয়ার্ড অন্তত **দুই জায়গায় অফলাইনে** রাখুন (যেমন এনক্রিপ্টেড USB + পাসওয়ার্ড ম্যানেজার)। কখনো রিপোতে, ইমেইলে বা চ্যাটে নয়।
- Plan A-তে release key Google-এর কাছেও থাকবে, কিন্তু **ওয়েবসাইটের APK সাইন করতে এটি আমাদেরও লাগবে** — তাই হারানো চলবে না।
- কোনো কী ফাঁস হয়েছে মনে হলে: upload key → §৬ অনুযায়ী রিসেট; app signing key → Play Console-এর "Request key upgrade" (শুধু Android 13+ ফোনে নতুন কী কার্যকর হয়)।

## ৬. upload key হারালে বা ফাঁস হলে

1. Play Console → **Setup → App signing → Request upload key reset**।
2. কারণ লিখুন, §৩-এর ধাপ ৫ অনুযায়ী নতুন upload key বানিয়ে তার `upload_certificate.pem` দিন।
3. Google সাধারণত কয়েক দিনের মধ্যে অনুমোদন দেয়; তখন থেকে নতুন কী গ্রহণ করে। এর মধ্যে নতুন রিলিজ আপলোড করা যায় না।
4. GitHub-এর চারটি `PLAY_UPLOAD_*` secret নতুন ফাইল দিয়ে বদলান।
অ্যাপ সাইনিং কী Google-এর কাছে থাকে বলে **upload key হারালেও ব্যবহারকারীরা আপডেট পেতে থাকেন** — Play App Signing-এর এটাই বড় সুবিধা।

## ৭. যা আমি যাচাই করতে পারিনি

- কী-টি RSA না EC, কত বিটের, মেয়াদ কতদিন — secret পড়া নিষেধ, তাই জানি না। CI লগের `apksigner verify --print-certs` বা আপনার কম্পিউটারে `keytool -list -v -keystore assisto-release.p12` দেখে নিশ্চিত হন। Google Play-র নিয়ম: সাইনিং কী-এর মেয়াদ ২২ অক্টোবর ২০৩৩-এর পরে শেষ হতে হবে।
- AAB এখনো CI-তে একবারও তৈরি হয়নি (প্রস্তাব প্রয়োগের পর প্রথম রানে দেখা যাবে)।
