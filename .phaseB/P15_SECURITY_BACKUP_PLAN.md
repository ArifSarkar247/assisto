# Assisto — Security Hardening, Pre-Launch Audit & Off-Server Backup Plan (P15)

Status: PLAN — owner must review/approve before launch. No secrets or live infra are changed by this document. Scope: Assisto only (never Asalify). Owner review items are marked **[OWNER]**.

## 1. Security hardening checklist (pre-launch, by area)

### 1.1 Vault & E2E (highest sensitivity)
- [ ] Vault blobs stored encrypted at rest; server holds ciphertext only (verify `validate_envelope` rejects plaintext/keys — already enforced for Circle; apply same assertion to vault upload path).
- [ ] E2E keys (X25519/ChaCha20-Poly1305/HKDF/PBKDF2) never leave device; server stores public keys + ciphertext only. MLS/OpenMLS swap seam documented; never libsignal.
- [ ] Recovery codes/passphrases never transmitted (KeyBackup: wrong code → null; `validate_backup_envelope` rejects secret keys). Add a server-side test asserting no backup field matches a secret-key allowlist.
- [ ] Vault PIN/biometric lock on device; auto-lock on background.

### 1.2 AuthN / AuthZ
- [ ] All API endpoints auth-gated by default (DRF default permission = IsAuthenticated); audit every view for an explicit AllowAny and justify each (only webhook/incoming + public plans).
- [ ] Multi-tenant scoping: every business/CRM/circle object filtered by owner/membership (`resolve_business`, `_OrgScopedViewSet`, circle relationship gate) — add a negative test per resource (user B cannot read user A's row → 403/404).
- [ ] Owner-only surfaces (analytics dashboard, admin) return 403 for non-staff — verified for `/analytics/dashboard`.
- [ ] Password reset tokens single-use, short TTL, rate-limited; email now, SMS when key present.

### 1.3 Transport / platform
- [ ] HTTPS only (HSTS at Caddy — Assisto block only; never edit Asalify's). TLS ≥1.2.
- [ ] Android network security config: no cleartext; certificate pinning **[OWNER]** decision (pin vs. not, given cert rotation).
- [ ] Secrets only in `~/.assisto_secrets.env` (600) / GitHub Actions secrets / Fernet — never in repo, logs, or client. Scan repo + APK for leaked keys before each release.

### 1.4 Rate limiting / abuse
- [ ] DRF throttle on auth, reset, invite, OTP, AI/paid endpoints (per-user + per-IP). Burst + sustained tiers.
- [ ] Idempotency on money/order/checkout/broadcast (client_msg_id / sale marker — due→khata bridge already idempotent).
- [ ] Input size caps (ciphertext length, upload size, import rows) — honest 413/422, not 500.

### 1.5 Mobile (OWASP MASVS-aligned, quick pass)
- MASVS-STORAGE: no sensitive data in logs/SharedPreferences in cleartext; vault encrypted.
- MASVS-CRYPTO: use vetted primitives (done); no homegrown crypto.
- MASVS-AUTH: server-side enforcement of all gates (min-price, plan, owner, circle) — never trust client (verified in M2 + Business v2 waves).
- MASVS-NETWORK: TLS, no cleartext, pinning decision **[OWNER]**.
- MASVS-PLATFORM: minimal exported components; validate deep links (`assisto://reset/confirm`); no secrets in deep links.
- MASVS-CODE: R8/proguard on release; strip debug logging; dependency CVE scan.
- MASVS-RESILIENCE **[OWNER]**: root/tamper detection is optional for v1; document decision.

## 2. Pre-launch audit plan
1. Automated: `flutter analyze` 0 errors + lang gate clean (CI-gated, enforced). Dependency vulnerability scan (pub + pip). Secret scanner over repo + built APK.
2. Backend test suite (388+ + logic + scenarios) green; add the negative-authz tests from §1.2.
3. Manual authz sweep: for each resource type, attempt cross-tenant read/write with a second account → expect denial. Log results.
4. Penetration checklist **[OWNER to commission]**: external review of vault/E2E, auth, rate limits, OWASP MASVS before public launch. This plan is the scope input, not a substitute for the review.
5. Privacy review: confirm analytics store no PII and no 3rd-party trackers (verified: analytics on our backend only).
6. Legal **[OWNER]**: privacy policy, terms, health disclaimer, Play data-safety form — drafts exist, owner must review/approve.

## 3. Off-server encrypted backups (DB + vault)
Goal: survive server loss without ever exposing plaintext, and never touch Asalify's backups (`/home/ubuntu/asalify_backups/` is off-limits).
- **DB**: nightly `pg_dump` of the `assisto` DB (already used before each migration) → encrypt with age/gpg using an owner-held public key → upload to owner-controlled off-server storage **[OWNER: choose destination]** (e.g., owner's object storage; NOT AWS per constraints). Keep N daily + M weekly; verify restore quarterly into a throwaway DB (sqlite settings_test proves schema; a real pg restore drill **[OWNER]**).
- **Vault blobs**: already ciphertext at rest; replicate the encrypted blob store to the same off-server destination. Server never holds the decryption key, so the backup is useless without the user's keys — by design.
- **Keys**: backup encryption key(s) held only by owner, offline. Rotation policy **[OWNER]**.
- **Automation**: a systemd timer on the Assisto box (separate from Asalify units) running an `assisto-backup.sh` that dumps → encrypts → uploads → prunes → logs; alert owner on failure. Disk guard: write to a temp path, upload, delete local — never breach the 8 GB floor.
- **Restore runbook**: documented steps to stand up DB + blob store from an encrypted backup on a fresh box; test before launch.

## 4. Open decisions for the owner
- [OWNER] Certificate pinning on Android (yes/no + rotation story).
- [OWNER] Off-server backup destination (must not be AWS; owner-controlled).
- [OWNER] Commission an external pen-test using §2.4 scope before public launch.
- [OWNER] Approve legal drafts (privacy/terms/health-disclaimer/data-safety).
- [OWNER] Root/tamper detection for v1 (recommended: defer).
- [OWNER] 'Assisto' trademark clearance (the in-app About surface is informational only, not legal clearance).
