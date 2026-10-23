# LiveKit SFU for Assisto group calls (B3) — install / check / roll back

**বাংলা সারাংশ নিচে।** Nothing here is installed by the b3-group agent. The integrator runs these
steps on the lifeassisto box (api.lifeassisto.com, AWS t3.large, Mumbai) **after** the branch is
merged, migration `0074_b3_group_calls` (re-chained) is applied and the backend is deployed.
Until LiveKit is installed the app hides every group-call entry (server says `available: false`).

## What gets installed

| Piece | Where | Notes |
|---|---|---|
| `livekit-server` **v1.13.7** (Apache-2.0) | `/opt/livekit/1.13.7/` → `/opt/livekit/current` | pinned: `deploy/livekit/VERSION` (URL + sha256 `6634aeeb…90e2`, checked before install) |
| config | `/etc/livekit/livekit.yaml` (0640 root:livekit) | rendered from `livekit.yaml.template`; TURN secret taken from the backend `.env` |
| API key + secret | `/etc/livekit/livekit.env` (0640) | generated once by `install.sh` (`LIVEKIT_KEYS="ASxxxx: <secret>"`), never printed, never in git |
| systemd | `/etc/systemd/system/livekit.service` | user `livekit`, MemoryMax 1200M, CPUQuota 120 %, CPUWeight 50, Nice 5, hardened |
| nginx | `/etc/nginx/snippets/assisto-livekit.conf` + 1 `include` line in the 443 block of `sites-available/assisto` | `wss://api.lifeassisto.com/livekit` → `127.0.0.1:7880` (WebSocket upgrade, 1 h timeouts) |
| backend env | `LIVEKIT_URL`, `LIVEKIT_HTTP_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`, `TURN_RELAY_PORT_MAX=63999` | appended only when missing |

### Ports (security group already opens UDP 49152–65535)

| Port | Use | Open to the internet? |
|---|---|---|
| 7880/tcp | LiveKit HTTP + WebSocket signalling | **No** — only through nginx `/livekit/` (TLS on 443) |
| 7881/tcp | ICE over TCP (UDP-blocked networks) | optional SG rule; without it those phones relay through our coturn (TURN/TLS 5349) |
| **64000–65535/udp** | WebRTC media | already open (inside 49152–65535) |
| coturn relay | **49152–63999/udp** | `install.sh` lowers coturn `max-port` 65535 → 63999 so the two never compete for a port (coturn keeps 10 848 ports ≈ 2 700 relayed calls) |

LiveKit uses **our coturn** (`turn.lifeassisto.com`, same `static-auth-secret`, udp/tcp 3478 + tls
5349) for phones behind strict NATs; LiveKit's own TURN stays off.

### Resource limits (t3.large, shared with API + Postgres + coturn)
`MemoryMax=1200M`, `MemoryHigh=1000M`, `CPUQuota=120%`, `CPUWeight=50` (the API wins under
contention), `limit.bytes_per_sec: 25000000` (≈200 Mbit/s: LiveKit stops admitting new tracks
beyond it), `limit.num_tracks: 400`, `room.max_participants: 16` (hard ceiling; the per-call
limit is the owner's "Max people", default 8, Owner Admin → Call relay).
Rough capacity at those limits: ~10 simultaneous 4-person **video** calls or ~60 4-person
**voice** calls (egress ≈ N×(N−1)×bitrate).

## Install (integrator)

```bash
# 0. after merge + migrate + backend deploy (DB backup first, as always)
cd /home/ubuntu/assisto
sudo bash deploy/livekit/install.sh          # asks "yes" before restarting coturn
#   or: sudo bash deploy/livekit/install.sh --yes
#   or: sudo bash deploy/livekit/install.sh --skip-coturn   (keep coturn untouched)
```

It is idempotent (safe to re-run) and backs up nginx site, `turnserver.conf`, backend `.env`
and `/etc/livekit` to `/var/backups/assisto-livekit/<timestamp>/` first. It restarts coturn
(only when the port range must change — run it at a quiet hour: relayed 1:1 calls redial),
reloads nginx (after `nginx -t`), starts `livekit`, and restarts `assisto` so the API reads
the new env.

### Check
```bash
systemctl status livekit --no-pager
curl -s http://127.0.0.1:7880/            # -> OK
curl -s https://api.lifeassisto.com/livekit/   # -> OK (through nginx/TLS)
journalctl -u livekit -n 50 --no-pager    # "starting LiveKit server" + the external IP
# the API now advertises group calls:
curl -s -H "Authorization: Token <token>" https://api.lifeassisto.com/api/v1/circle/calls/group/config
# -> {"available": true, "max_participants": 8, ...}
```
Owner Admin → **Call relay** shows "LiveKit configured on the server" + the group-call cost row.

Optional (better for UDP-blocking networks): AWS security group inbound **TCP 7881** from
0.0.0.0/0 (owner action).

### Webhook (cost metering)
LiveKit posts join/leave/track events to `https://api.lifeassisto.com/api/v1/livekit/webhook`,
signed with the API secret (the backend verifies the JWT + body sha256). The app also reports
joined/left itself, so metering works even if the webhook is blocked.

## Roll back

```bash
sudo bash deploy/livekit/rollback.sh            # stop LiveKit, hide group calls (LIVEKIT_* commented)
sudo bash deploy/livekit/rollback.sh --coturn   # also put coturn back to 65535 (restarts coturn)
```
1:1 calls are not affected by either. The keys in `/etc/livekit` are kept, so `install.sh`
brings it back with the same key. To hide group calls without stopping anything: Owner Admin →
Call relay → untick "Group calls on".

## Upgrade LiveKit later
Edit `VERSION` (new version, URL, sha256 from the release's `checksums.txt`), commit, re-run
`install.sh` (it installs side by side in `/opt/livekit/<ver>` and flips `current`).

---

# বাংলা — LiveKit (গ্রুপ কল সার্ভার) বসানো

**কী:** ৩ বা তার বেশি জনের কল (গ্রুপ কল) আমাদের নিজের সার্ভারে LiveKit দিয়ে চলবে। ১:১ কল আগের মতোই
সরাসরি (বা TURN দিয়ে) চলবে — তাতে কিছু বদলায় না। LiveKit বসানোর আগ পর্যন্ত অ্যাপে গ্রুপ কলের কোনো বোতাম
দেখা যাবে না।

**ধাপ (ইন্টিগ্রেটর):**
১. ব্রাঞ্চ মার্জ, ডাটাবেস ব্যাকআপ, মাইগ্রেশন `0074_b3_group_calls`, ব্যাকএন্ড ডিপ্লয় — আগের মতো।
২. শান্ত সময়ে (রাতে) চালান: `sudo bash deploy/livekit/install.sh` — coturn রিস্টার্টের আগে "yes" লিখতে বলবে
   (রিলে হওয়া চলমান ১:১ কল একবার কেটে আবার লাগবে)।
৩. যাচাই: `curl -s https://api.lifeassisto.com/livekit/` → `OK`। Owner Admin → **কল রিলে** পাতায়
   "সার্ভারে LiveKit চালু আছে" দেখাবে।
৪. (ঐচ্ছিক, মালিক) AWS Security Group-এ TCP 7881 খুলুন — UDP-বন্ধ নেটওয়ার্কে ভালো চলবে।

**পোর্ট:** মিডিয়া UDP 64000–65535 (আগে থেকেই খোলা)। coturn এখন 49152–63999 ব্যবহার করবে, দুটো একে অপরের
পোর্ট নেবে না। 7880 বাইরে খোলা নয় — শুধু nginx (`/livekit/`, HTTPS) দিয়ে।

**সীমা:** LiveKit সর্বোচ্চ ~১.২ CPU আর ১.২ GB RAM পাবে; চাপে API আগে পায়। প্রতি কলে সর্বোচ্চ কতজন — Owner
Admin থেকে বদলানো যায় (ডিফল্ট ৮)।

**খরচ:** সার্ভার প্রত্যেক বক্তার কণ্ঠ/ভিডিও বাকি প্রত্যেককে একবার করে পাঠায়। হিসাব (আনুমানিক): ৩ জনের ভয়েস কলে
প্রতি জন-মিনিট ≈ ৳০.০০৭, ৩ জনের ভিডিও কলে ≈ ৳০.১২ (AWS USD 0.1093/GB × ৳১২০)। আসল সংখ্যা Owner Admin →
লাভ-ক্ষতি ও কল রিলে পাতায় "গ্রুপ কল (SFU)" সারিতে। "ফ্রি কল (টেস্টিং)" চালু থাকলে খরচ আলাদা দেখায়।

**ফিরিয়ে নেওয়া:** `sudo bash deploy/livekit/rollback.sh` — গ্রুপ কল লুকিয়ে যায়, LiveKit বন্ধ হয়। ১:১ কল
চলতে থাকে। শুধু লুকাতে চাইলে Owner Admin → কল রিলে → "গ্রুপ কল চালু" টিক তুলে দিন।
