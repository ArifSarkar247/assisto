OWNER ORDER — HOME AD HERO + IMAGE IN CHAT (owner-approved home changes):

1. HOME: remove the suggestion questions ("What's on today?", "How much did I spend this month?").

2. HOME AD HERO (free users only): replace the Assisto logo + "Hi, I'm Assisto" block with a large
   AdMob NATIVE ad (image or video) that loads when the app opens. Rules:
   - It REPLACES that block — never overlaps any text, button or input (AdMob policy: no ads over
     app content, no accidental-click placement). Clear "Ad" label.
   - Only ONE AdMob ad visible on home at a time: while the hero ad shows, Discover shows only
     FEATURE / OUR PRODUCT / SPONSORED cards (no AdMob slot).
   - Collapses when the user taps the input or a chat starts; refresh no faster than AdMob allows.
   - Premium/Business: keep the logo + "Hi, I'm Assisto" (no ads). Never on safety screens.
   - No ad loaded (no fill/offline) → show the normal logo block. Admin-editable on/off.

3. AD SOUND: rewarded, interstitial and app-open video ads play WITH sound (normal AdMob
   behaviour). The home hero native video ad starts MUTED with a clear speaker icon to unmute
   (AdMob VideoOptions startMuted=true) — no autoplay with sound on app open. Admin toggle exists,
   default muted.

4. IMAGE IN CHAT (attach a photo and ask about it — medicine box, bill, plant, document, etc.):
   - Free: on-device OCR (Bangla + English text) and basic image labels (ML Kit) → honest, useful
     answer; detailed AI answer = 1 per day after 2–3 rewarded ads (Profit Guard decides).
   - Premium/Business: full cloud AI vision analysis from the monthly pool (credits per image).
   - Key-gated provider (Claude / OpenAI / Gemini vision), honest "needs key X" state.
   - Safety: medicine answers show dose only from the label + "consult a doctor"; no identifying
     real people from their face; documents stay private (not stored beyond the chat).

Real end-to-end test; ship with the 3 Bangla lines.
