# Assisto migration kit

Move Assisto to a new server in ~one day. The app reaches the backend **only by
domain name** (`assisto.asalify.com` by default, or your own domain) — so a
server move is mostly a **DNS change**, not a new APK.

## Files
| File | What it does |
|---|---|
| `provision.sh` | Fresh Ubuntu → full stack (Python, Postgres, nginx+SSL, gunicorn unit, coturn w/ same hard caps, Redis, backup cron, cert renew, watchdog, ufw). Run as root on the NEW box. |
| `backup.sh` | Encrypted bundle: Postgres dump + media + secrets + keystore + manifest (AES-256, passphrase). Refuses below the 8 GB disk floor. |
| `restore.sh` | Decrypt + restore a bundle. `--into-db NAME` to rehearse into a temp DB; `--dry-run` to only unpack+inspect. |
| `smoke_test.sh` | Verify a server post-migration — every critical endpoint (gated ones must be 401, not 5xx), calls config, telegram inert, web tools, an auth round-trip. |
| `.env.template` | Every secret/key with what it unlocks (boot secrets + per-feature provider keys). |

## Migration day — order
1. New server: point its **public IP**; create the `ubuntu` user.
2. **DNS**: point `assisto.asalify.com` (and `TURN_HOST`) A-record at the new IP.
   (Lower the TTL to 300s a day before, so the cutover is fast.)
3. `sudo DOMAIN=assisto.asalify.com REPO=<git-url> ADMIN_EMAIL=<you> bash provision.sh`
4. On the OLD box: `./backup.sh` → copy the `.enc` bundle (+ its passphrase) to the new box.
5. New box: `./restore.sh <bundle>.enc` → it loads DB + media and brings the OLD
   secrets (so `INTEGRATIONS_FERNET_KEY` matches → the Integrations keys stay readable).
6. `cd backend && ../.venv/bin/python manage.py migrate` (restore.sh reminds you).
7. Open the provider Security-Group ports (`owner_actions/aws_ports.md`).
8. `./smoke_test.sh https://assisto.asalify.com` → expect all pass.
9. Paste any feature keys in the in-app **Integrations admin** (see `.env.template`).

## Verify the cutover
- `smoke_test.sh` green.
- Open the app → it hits the new server by domain with **no update** (because the
  base URL is a domain + the in-app Server-address swap can override in a pinch).
- Place a 1:1 call once the ports are open (TURN relay).

## Rollback (if the new box misbehaves)
- **Fastest:** point the DNS A-record **back** to the old server. Because the
  app is domain-addressed, it returns to the old backend within the DNS TTL —
  no app change. Keep the old box running (don't destroy it) until the new one
  is proven for a few days.
- If data diverged on the new box during the window, take a fresh `backup.sh`
  from the new box before flipping back, so nothing is lost.
- coturn/app are `Restart=on-failure` + a 5-min watchdog cron; a transient crash
  self-heals.

## Critical gotchas
- **`INTEGRATIONS_FERNET_KEY` must stay identical** across the move — it decrypts
  every provider key saved in the Integrations admin. `restore.sh` brings the old
  `secrets.env`; if you let `provision.sh` auto-generate a new one, overwrite it
  with the old value before starting the app.
- **Android upload keystore**: back it up (it's in the bundle if present) and keep
  it on your BUILD host. A different signing key = Play Store refuses the update.
- **Cloud firewall ≠ ufw**: on AWS/GCP you must ALSO open ports in the provider
  Security Group, not just ufw. See `owner_actions/aws_ports.md`.
- **Group-call SFU** is not provisioned (needs a bigger box). TURN handles 1:1 +
  small mesh. Add an SFU only on an instance with real RAM headroom.
