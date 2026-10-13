# BUSINESS MODULE v2 — owner-approved plan (QUEUED)
Priority: AFTER Module-5 integration+APK; BEFORE P14–P16 leftovers and BEFORE P11 iOS. Same rules: premium reviewer, language gate (no Bangla in .dart / bn+en balanced), gallery (bn/en×light/dark), tests, safety, public-window. REPLACE the current basic Business screen (name/price/stock dialog).

Positioning: Assisto Business = pocket business assistant for small businesses (online sellers, small shops, services, food, wholesalers). **Bookkeeping + selling are FREE; AI sales assistant = paid Business plan.** Benchmark: BD digital-khata (e.g. TallyKhata — CAPABILITY ONLY, NEVER copy name/design/text/data) + best global small-business/POS. Win via AI (they lack it).

## 1. Setup: ask business type (online seller / small shop / service / food / wholesaler / B2B); configure per type. MULTIPLE businesses per user, each its own books.

## 2. Digital khata (FREE):
- Two-sided dues: customer receivables (বাকি) + supplier payables (দেনা); partial payments; history.
- Tagada reminders: one-tap + bulk + scheduled; WhatsApp share now, SMS when provider key exists. Optional msg to customer on due add ("আপনার খাতায় ৳৫০০ যোগ হলো").
- Cashbox: opening cash, cash in/out, end-of-day reconciliation.
- Sales/purchases/expenses/stock/notes; calculator that saves to ledger; bill photo on any entry.
- Per-customer statement PDF; offline-first; PIN lock; auto backup.

## 3. Selling:
- Products: photos, variants (size/colour), selling price, cost price (profit), **MINIMUM price** (bargaining), stock, categories, barcode scan, Excel import.
- Quick sell: tap→cart→cash/bKash/Nagad/due→done. Receipt OPTIONAL (image/PDF WhatsApp share).
- Customers: name/phone/address/area/notes/VIP, purchase history, dues; auto-created from incoming chats.
- Reports: daily/weekly/monthly sales, profit, top products, top customers, by payment method, net profit after expenses; PDF/Excel.
- Staff role: can sell, CANNOT see profit/cost.

## 4. Online selling + AI SALES ASSISTANT (paid; live when Meta keys exist — BUILD FULLY NOW WITH MOCKS):
- Official **WhatsApp Business Platform (Cloud API)** + Messenger via Page/Graph API ONLY. **NEVER automate personal WhatsApp or the WhatsApp Business app** (ban risk). Respect 24h window + paid templates.
- 24/7 replies from REAL catalog/stock/delivery-charges/owner-policies (delivery in/out Dhaka, returns, payment methods, hours); screenshot→product match; voice notes; bn/Banglish/en.
- **BARGAINING: minimum price enforced in CODE not AI — can NEVER sell below minimum.** Per-product list/min price, allowed discount steps/bundles/free-delivery rules, negotiation tone. Below-min → "I'll check with the owner" + instant owner notification.
- Orders: new→confirmed→packed→shipped (Pathao/Steadfast/RedX APIs — owner keys)→delivered/returned; COD tracking; "where is my parcel?".
- Human handoff (angry/refund/big/low-confidence); owner takes over any chat; AI says it's the shop's AI assistant if asked.
- Morning summary ("overnight: 34 msgs, 8 orders, 2 need you"); opt-in broadcast only, no spam.

## 5. AI extras (paid): voice entry ("রহিমের খাতায় ৫০০ টাকা বাকি লেখো"); photo of paper khata→digital entries w/ review step; match incoming bKash/Nagad notif to open dues ("রহিম ৳৩০০ পাঠিয়েছে, খাতা থেকে বাদ দেব?"); insights ("tea sales down 20%", "Rahim's due 45 days old"); business report PDF for bank-loan apps (sales history only — WE DO NO LENDING).

## 6. Payments: NEVER hold money / NEVER act as a wallet (needs Bangladesh Bank licence). Show owner's own bKash/Nagad merchant QR; payment links in tagada via a LICENSED payment partner (owner key).

## 7. Asalify bridge (later): same catalog/customers when a business grows — DESIGN API ONLY; do NOT touch Asalify.

## 8. Plans: FREE = khata, selling, tagada-via-WhatsApp, reports. PAID Business = AI sales assistant, auto-reply, bargaining, voice entry, paper-khata digitising, insights (prices TO REVIEW BY OWNER).

## 9. Build order inside module: small shop + online seller FIRST, then service, food, wholesaler. SCENARIO TESTS (must pass): 30-day small-shop month (sales/dues/tagada/cashbox) + 7-day online-seller week (chats, bargaining below/above minimum, orders, courier states). Ship APK when it passes review.

## Reuse: P7 Business backend (catalog/orders state machine, WhatsApp webhook gated) exists — extend, don't duplicate. Partition: backend/core/business* + new app/lib/screens/business/* (replace old business_screen.dart). AI = mock provider now, key-gated live.
