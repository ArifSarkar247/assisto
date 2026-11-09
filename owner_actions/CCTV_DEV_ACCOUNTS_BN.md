# CCTV ডেভেলপার অ্যাকাউন্ট — মালিকের ধাপ (Imou, EZVIZ, Dahua DoLynk, Hikvision)

## IMOU OAUTH NOW (৯ Nov ১৬:৫২, সংশোধিত ১৭:২০) — Imou-র নিজস্ব ডকুমেন্ট দেখে নিশ্চিত

Imou-র পাবলিক ডকুমেন্ট (open.imoulife.com → Concepts → OAuth 2.0) অনুযায়ী "Create an OAuth project" ফর্মে শুধু **তিনটি** ঘর:

| ফর্মের ঘর | যা দেবেন |
|---|---|
| Project logo | Assisto লোগো — ফাইল: `app/assets/branding/new_logo.png` (দরকার হলে আমরা পাঠাব) |
| Project name | `Assisto CCTV` |
| Authorization success notification URL | `https://api.lifeassisto.com/api/v1/cctv/imou/oauth/callback` (শেষে `/` ছাড়া — এটি লাইভ) |

**Scope:** Imou নিজেই "all" দেয় — বাছাই করার কিছু নেই। (আগের লেখায় টিক দেওয়ার তালিকা ছিল — সেটা আর লাগবে না।)

**অনুমোদনের পর** কনসোলে তিনটি মান দেখাবে: **User Authorization H5 Page**, **Project Access Key**, **Project Secret Key**। এগুলো চ্যাটে বা কোথাও লিখবেন না — Owner Admin → Integrations → **Imou** কার্ডের নতুন তিনটি ঘরে পেস্ট করে **Save → Test** চাপুন (ঘরগুলো পরের বিল্ডে আসছে)।
