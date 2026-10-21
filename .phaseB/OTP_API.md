# OTP helper API (slot o1-otp) — for other slots (m1-messenger change-number etc.)

Module: `backend/core/otp.py`. All logic, limits and hashing live there; never
re-implement OTP elsewhere.

## Python helpers

```python
from core import otp

# 1) Send a code. Raises otp.OtpError on any refusal.
out = otp.issue(phone, purpose, request=request, user=request.user, lang=req_lang(request))
#   -> {"ok": True, "sms_enabled": True, "purpose", "phone_masked", "expires_in", "resend_in", "code_length": 6}

# 2) Check the code the user typed. Returns the RAW single-use otp_proof (str).
proof = otp.verify(phone, purpose, code)        # raises otp.OtpError

# 3) At the target endpoint: burn the proof. Returns canonical "+8801XXXXXXXXX" or None.
canon = otp.consume_proof(token, purpose, phone=None)   # phone (any BD format) adds a binding check
```

`otp.OtpError` has `.reason`, `.http_status`, `.extra` and `.body(lang)` (a
ready JSON body `{ok:false, reason, message, ...extra}`). Reasons:
`sms_not_configured` (503), `bad_phone`, `bad_purpose` (400), `cooldown`,
`rate_limited` (429, `retry_after`), `locked` (423, `retry_after`),
`send_failed` (502), `invalid_code` (400, `attempts_left`), `expired`,
`no_active_code` (400).

Other helpers: `normalize_bd_phone(raw)` (01…/+8801…/8801…/008801… →
`+8801XXXXXXXXX` or None), `local_form(canon)` (→ `01…`), `phone_variants(canon)`,
`find_user_by_phone(canon)`, `user_phone(user)`, `sms_available()`,
`otp_required_for(user)`, `mark_verified(user, canon)` (writes `PhoneVerification`).

## Purposes

`signup`, `login`, `password_reset`, `delete_account`, `section8`, **`change_number`**
(added for m1). A code/proof for one purpose never works for another (purpose is
inside the HMAC and the lookup).

`AUTHED_PURPOSES = (delete_account, section8, change_number)` — the HTTP
request/verify views require a signed-in user for these. For `delete_account`
and `section8` the phone is forced to the user's own number. For
`change_number` the phone is the NEW number and the request view refuses
(409 `already_registered`) when another account owns it.

## m1: change-number recipe

HTTP (app side, already served by o1):
1. `POST auth/otp/request {phone: <new>, purpose: "change_number"}` (authed)
2. `POST auth/otp/verify  {phone: <new>, purpose: "change_number", code}` → `{otp_proof}`
3. `POST circle/account/change-number/confirm {phone: <new>, otp_proof}` (m1's view)

m1's confirm view:
```python
from core import otp
canon = otp.consume_proof(request.data.get("otp_proof"), "change_number",
                          request.data.get("phone"))
if canon is None:
    return Response({"ok": False, "reason": "bad_otp"}, status=403)
if otp.find_user_by_phone(canon):
    return Response({"ok": False, "reason": "already_registered"}, status=409)
request.user.phone = otp.local_form(canon); request.user.save(update_fields=["phone"])
otp.mark_verified(request.user, canon)
```
If m1 wants its own `change-number/request` route, just call
`otp.issue(new_phone, "change_number", request=request, user=request.user, lang=lang)`
inside `try/except otp.OtpError as e: return Response(e.body(lang), status=e.http_status)`.
When `otp.sms_available()` is False, return the honest 503 `sms_not_configured`.

## HTTP endpoints (o1)

| Method | Path | Body | Result |
|---|---|---|---|
| GET | `auth/otp/status` | – | `{sms_enabled, password_only_signup, code_length, expires_in, resend_in, purposes}` |
| POST | `auth/otp/request` (alias `auth/otp/resend`) | `{phone, purpose, device_id?}` (header `X-Device-Id` also read) | 200 / 4xx / 503 honest |
| POST | `auth/otp/verify` | `{phone, purpose, code}` | `{ok, otp_proof, expires_in}` |
| POST | `auth/otp/login` | `{phone, otp_proof}` | `{token, user}` |
| POST | `auth/otp/reset` | `{phone, otp_proof, password}` | `{ok, message}` (all sessions signed out) |
| POST | `auth/register` | + `otp_proof` (purpose signup) | required when flag `auth_password_only_signup` is OFF |
| POST | `account/delete/request` | + `otp_proof` (purpose delete_account) | required when SMS connected → else 403 `otp_required` |
| POST | `security/action` | + `otp_proof` (purpose section8) | required when SMS connected → else 403 `otp_required` |

Login / password_reset requests for an unknown number return the same neutral
200 and send nothing (no enumeration, no SMS cost).

## Limits (admin-editable, `/admin/pricing` config → `otp` section)

`ttl_seconds` 300, `resend_cooldown_seconds` 60, `max_attempts` 5,
`lockout_minutes` 30, `per_phone_per_hour` 5, `per_ip_per_hour` 20,
`per_device_per_hour` 10, `proof_ttl_seconds` 600. Bounds clamp in
`core/logic/pricing.py::_norm_otp`.

## Storage

`OtpChallenge` (HMAC-SHA256(SECRET_KEY, salt|phone|purpose|code), per-code salt,
attempts, lock, ip, device), `OtpProof` (sha256 of token, single use),
`PhoneVerification` (user ↔ verified phone). Migration `0046_o1_otp_challenge.py`.
The legacy plaintext `OTPCode` model is no longer used by any view.
