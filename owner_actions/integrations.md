# Integrations — owner key guide (which key unlocks which feature)

The owner manages every external-service key at **`/owner/integrations`**
(Assisto owner-admin page, superuser-only, rate-limited, audit-logged). Keys are
encrypted at rest with Fernet (`INTEGRATIONS_FERNET_KEY` in
`/home/ubuntu/.assisto_secrets.env`, chmod 600) — never in git, never in logs,
never shown back in full (only `•••• last4`).

A feature turns on **automatically** the moment its integration tests OK
(`integrations.is_enabled(slug)` returns True). No code change, no redeploy.
Keep this file in sync with `core/integrations.py::REGISTRY` — one row per slug.

## How to connect (general)
1. Open `https://assisto.asalify.com/owner/integrations` and log in (owner only).
2. Find the service card (grouped by category; the dashboard at the top shows
   connected / not-working / not-connected counts).
3. Follow the per-card "How to connect" steps, paste the key(s), press **Save**.
4. Press **Test connection** where available — the status pill and "Last checked"
   time update honestly. Cards with no automated test read "active on save" and
   are verified on first real use.

## Key → feature map

### AI
| slug | keys | unlocks |
|------|------|---------|
| `anthropic` | `api_key` | Smart briefing, roleplay, mental support, bill/scan AI, CRM AI (primary LLM). Testable. |
| `gemini` | `api_key` | Backup LLM when Anthropic is down. Testable. |
| `openai` | `api_key` | Second backup LLM. Testable. |
| `ocr` | `provider`, `api_key` | Document scanner: image/receipt → text (bn+en). On-device fallback if no key. |
| `transcription` | `provider`, `api_key` | Voice commands, call/meeting transcription (both parties notified). |
| `voice_clone` | `api_key`, `voice_id` | AI replies/briefing in the owner's self-verified cloned voice (TTS). |

### Messaging
| slug | keys | unlocks |
|------|------|---------|
| `firebase` | `google_services_json`, `service_account_json` | Cross-device push (missed medicine → child, family share). |
| `sms` | `api_key`, `sender_id` | OTP login, family SMS alerts. |
| `ivr` | `api_key`, `caller_id` | Family-care voice-call reminders. |

### Business
| slug | keys | unlocks |
|------|------|---------|
| `whatsapp` | `phone_number_id`, `access_token`, `verify_token` | WhatsApp Cloud sales assistant + CRM lead capture (Business mode). |
| `messenger` | `page_id`, `page_name`, `access_token`, `verify_token` | Facebook Page / Messenger sales assistant; inbox → CRM lead. |
| `instagram` | `ig_user_id`, `access_token` | Instagram DM sales assistant & lead capture. |
| `courier` | `provider`, `api_key` | Order → courier booking & status (Pathao/Steadfast/RedX). |
| `axon_erp` | `base_url`, `token` | CRM deal Won → 1-click Axon ERP onboarding. |

### Payment
| slug | keys | unlocks |
|------|------|---------|
| `bkash` | `app_key`, `app_secret`, `username`, `password` | Bill pay, subscription, credit top-up (bKash). |
| `nagad` | `merchant_id`, `public_key`, `private_key` | Pay / subscribe / top-up (Nagad). |
| `sslcommerz` | `store_id`, `store_pass` | Card / MFS payment gateway. |
| `ekpay` | `merchant_id`, `api_key` | Govt / utility bill payment. |

### Location
| slug | keys | unlocks |
|------|------|---------|
| `google_places` | `api_key` | Nearby restaurants/pharmacy/ATM/hospital; map navigation. Testable. |

### Email
| slug | keys | unlocks |
|------|------|---------|
| `google_oauth` | `client_id`, `client_secret` | AI Inbox, email assistant, job hunter (user's own Gmail). Redirect URI: `https://assisto.asalify.com/oauth/google/callback`. |

### Media
| slug | keys | unlocks |
|------|------|---------|
| `spotify` | `client_id`, `client_secret` | Favourite-artist new releases; play deep-links. Testable. |
| `youtube` | `api_key` | Watch artist channels (also works key-free via RSS). |
| `weather` | `provider`, `api_key` | Weather in the morning briefing. |
| `news` | `provider`, `api_key` | Headlines in the morning briefing (RSS fallback if no key). |

### Monetization
| slug | keys | unlocks |
|------|------|---------|
| `admob` | `app_id`, `banner_unit`, `rewarded_unit` | Non-personalized ads + rewarded ad (1 extra scan). Never on vault/health/family/emergency/payment screens. |
| `play_billing` | `service_account_json` | In-app subscriptions / credit purchase. |

### Health
| slug | keys | unlocks |
|------|------|---------|
| `health_connect` | `enabled` | Health timeline + smartwatch data (Android; in-app permission). |

### Smart home
| slug | keys | unlocks |
|------|------|---------|
| `smart_home` | `provider`, `access_id`, `access_secret` | Voice control of home devices (Tuya / Google Home). |

## Security invariants (must hold)
- Owner-only (`is_superuser`); rate-limited login; every save/test audit-logged
  (the slug is logged, never the secret value).
- Secrets encrypted at rest; masked (`•••• last4`) in the UI; never returned to
  any app client.
- Honest states only: a card is CONNECTED only when its last test did not fail
  (or it is a save-only integration marked active on save and verified on first
  use); otherwise NOT CONNECTED / NOT WORKING.

## price_feed (NEW — #34 Market price radar live prices)
Status: NOT in registry yet (honest — no live feed). The price radar works fully as a MANUAL tracker now. To enable LIVE market prices (#34), the owner picks a market-data provider and a `price_feed` key is added to the Integrations registry; the radar's documented seam then flips to live. Until then, only user-logged prices are shown — never fabricated quotes.
