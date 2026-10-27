# আলাদা কাজের সার্ভার (Work Server) — শুধু পরিকল্পনা, কোনো খরচ হয়নি

মালিকের আদেশ ২৭ Oct রাত, অংশ B। **আমি AWS Console-এ কিছু করিনি, কিছু কিনিনি।** দাম Mumbai (ap-south-1), Linux, অক্টোবর ২০২৬-এর প্রকাশিত হার (উৎস নিচে); টাকা = ডলার × ১২০ (আনুমানিক — আজকের রেট দেখে নেবেন)।

## ১. এখনকার লাইভ সার্ভার — আসল তথ্য
- **t3.large** (২ vCPU, ৮ GB RAM), ap-south-1b, on-demand, Ubuntu 24.04, ৯৬ GB ডিস্ক (৬৬% ভরা — এর ২৭ GB এজেন্টদের কাজের ফোল্ডার)।
- **t3 হলো "burstable"** — বেসলাইন প্রতি vCPU-এ মাত্র ৩০%; তার বেশি চললে CPU ক্রেডিট খরচ হয়। আজ লোড ৪–৮ (মানে দুটো CPU-ই প্রায় সারাক্ষণ পুরো ব্যস্ত) — ক্রেডিট শেষ হলে **"unlimited" মোডে AWS বাড়তি টাকা নেয়** (~$০.০৫ প্রতি vCPU-ঘণ্টা; আজকের মতো লোডে আনুমানিক দিনে ~$১–১.৫), আর **"standard" মোডে সার্ভার ধীর হয়ে যায়** — দুটোই আসল ব্যবহারকারীর জন্য খারাপ। p95 আজ ৪৫৭ ms-এর একটা বড় কারণ এটাই।
- **আপনি দেখে নিন (২ মিনিট):** EC2 → Instances → লাইভ সার্ভার → Actions → Instance settings → **Change credit specification** (unlimited না standard?); আর Monitoring ট্যাবে **CPUCreditBalance** ও **CPUSurplusCreditsCharged** গ্রাফ।

## ২. প্রস্তাব: কাজের সার্ভার
| বিষয় | প্রস্তাব |
|---|---|
| ধরন ও আকার | **c7i.2xlarge** — ৮ vCPU, ১৬ GB RAM, burstable নয় (সারাক্ষণ পুরো গতি) |
| অঞ্চল | **ap-south-1 (Mumbai), একই AZ ap-south-1b** (লাইভের সাথে একই নেটওয়ার্কে, ভেতরের ট্রাফিক ফ্রি/সস্তা) |
| ডিস্ক | **gp3 ১৫০ GB** (এজেন্টদের ফোল্ডার + Flutter + Android টুল) — আনুমানিক ~$১৪/মাস |
| OS | Ubuntu 24.04 LTS (লাইভের মতো) |
| দাম — on-demand | **$০.৩৫৭/ঘণ্টা ≈ $২৬১/মাস** + ডিস্ক ≈ **$২৭৫/মাস ≈ ৳৩৩,০০০** |
| দাম — ১ বছরের Savings Plan (no upfront) | **$০.২৩৬৪/ঘণ্টা ≈ $১৭৩/মাস** + ডিস্ক ≈ **$১৮৭/মাস ≈ ৳২২,৪০০** (১ বছরের প্রতিশ্রুতি) |
| দাম — Spot | ~$০.১৪/ঘণ্টা ≈ $১০৩/মাস + ডিস্ক ≈ $১১৭ ≈ ৳১৪,০০০ — **কিন্তু AWS ২ মিনিটের নোটিসে বন্ধ করে দিতে পারে** |

**কোনটা সস্তা ও ঠিক:** Spot সবচেয়ে সস্তা, কিন্তু এজেন্টদের লম্বা কাজ (ঘণ্টার পর ঘণ্টা) মাঝপথে মরে যাবে — এই কাজে **Spot না**। **আমার পরামর্শ:** প্রথম মাস **on-demand** (কোনো বাঁধন নেই, দরকার না হলে বন্ধ করা যায়); কাজে লাগলে তারপর **১ বছরের EC2 Savings Plan** নিলে প্রায় ৩৪% কম। ছোট বিকল্প: c7i.xlarge (৪ vCPU, ৮ GB) ≈ $১৩০/মাস — কিন্তু ১৫ এজেন্ট + Flutter টেস্টে ৮ GB টানাটানি হবে, তাই সুপারিশ নয়।

## ৩. AWS Console-এ হুবহু ধাপ (আপনি করবেন)
1. **EC2 → Launch instance**। Name: `assisto-work`।
2. **AMI:** Ubuntu Server 24.04 LTS (64-bit x86)।
3. **Instance type:** `c7i.2xlarge`।
4. **Key pair:** "Create new key pair" → নাম `assisto-work-key`, ধরন **ED25519**, ফরম্যাট .pem → ডাউনলোড করে নিরাপদে রাখুন (কাউকে দেবেন না, git-এ নয়)। (লাইভের key আলাদা থাকুক — এক key দুই সার্ভারে নয়।)
5. **Network settings → Edit:** VPC = লাইভের VPC `vpc-04a07ca886683299f`; Subnet = **ap-south-1b**-এর subnet; Auto-assign public IP = Enable।
6. **Security group → Create security group:** নাম `assisto-work-sg`। Inbound: শুধু **SSH (22) — Source: My IP** (আপনার এখনকার IP)। আর কিছু খোলা নয় (কোনো ওয়েব পোর্ট নয়)। Outbound: সব (ডিফল্ট)।
7. **Storage:** 150 GiB, **gp3**, Encrypted = Yes।
8. **Advanced → IAM instance profile:** কিছু দরকার নেই (এই সার্ভার AWS-এর কোনো সেবায় হাত দেবে না)।
9. **Launch** → Instance-এর **Private IPv4** আমাকে জানান (পাবলিক IP-ও)।
10. **লাইভের security group `assisto-sg`-এ একটা Inbound rule যোগ:** SSH (22), Source = **`assisto-work-sg`** (security group বেছে নিন, IP নয়) — যাতে কাজের সার্ভার থেকে শুধু ডিপ্লয় করা যায়।
11. তারপর কাজের সার্ভারে একবার ঢুকে (`ssh -i assisto-work-key.pem ubuntu@<public-ip>`) Claude Code চালু করে লগইন করবেন — বাকি সেটআপ আমি করব।

## ৪. কাজের সার্ভারে যা সরবে / লাইভে যা থাকবে
**সরবে:** Claude Code সেশন ও সব এজেন্ট, এজেন্টদের worktree (২৭ GB), Flutter SDK + Android টুল, সব লোকাল টেস্ট (heavy.sh), স্ক্রিনশট বানানো, gitleaks, লোড-টেস্টের ড্রাইভার (লোড টেস্ট লাইভে কখনো নয় — CI বা কাজের সার্ভারের নিজের টেস্ট-ব্যাকএন্ডে)।
**লাইভে থাকবে (শুধু ব্যবহারকারীর জন্য):** gunicorn/Django, PostgreSQL, nginx/Caddy, coturn, ট্র্যাকার সার্ভিস, cron, ব্যাকআপ, `owner_private` (Play key ইত্যাদি — **কাজের সার্ভারে কোনো গোপন চাবি যাবে না**)। ডিপ্লয় ও Play আপলোড চলবে লাইভে, কাজের সার্ভার থেকে SSH দিয়ে শুরু করা হবে (আলাদা ডিপ্লয়-key, শুধু ডিপ্লয় স্ক্রিপ্ট চালাতে পারে)।
**কাজের সার্ভার থেকে লাইভ DB-তে কোনো সরাসরি সংযোগ নয়।**

## ৫. লাইভ সার্ভার কি ৮ Nov-এর আগে বাড়ানো উচিত?
**হ্যাঁ, সুপারিশ।** কাজ সরিয়ে নেওয়ার পর ২–৩ দিন p95 ও লোড মাপব; তবু লঞ্চে burstable t3 ঝুঁকিপূর্ণ (ভিড় হলে ক্রেডিট শেষ → ধীর বা বাড়তি বিল)। প্রস্তাব: **m7i.xlarge** (৪ vCPU, ১৬ GB, burstable নয়) — **$০.২১২১/ঘণ্টা ≈ $১৫৫/মাস ≈ ৳১৮,৬০০** (১ বছরের Savings Plan-এ ≈ $১০২/মাস); এখন t3.large ≈ $৬৫/মাস। পরিবর্তনে ~৫ মিনিট সার্ভিস বন্ধ থাকে (Stop → Change instance type → Start; Elastic IP থাকলে IP বদলায় না — আপনি নিশ্চিত করবেন) — রাতে কম ভিড়ের সময়, DB ব্যাকআপের পরে; আমি আগে-পরে চেক-লিস্ট দেব। সিদ্ধান্ত ও খরচ আপনার।

## উৎস
- c7i.2xlarge Mumbai: https://trucost.cloud/instances/ec2/ap-south-1/c7i.2xlarge
- t3.large Mumbai: https://trucost.cloud/instances/ec2/ap-south-1/t3.large
- m7i.xlarge Mumbai: https://trucost.cloud/instances/ec2/ap-south-1/m7i.xlarge
- (gp3 ডিস্কের দাম ও t3 unlimited-এর বাড়তি হার আনুমানিক — AWS Pricing পাতায় ap-south-1 বেছে মিলিয়ে নিন: https://aws.amazon.com/ec2/pricing/on-demand/)
