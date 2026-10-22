# Remote support — owner's full spec (22 Oct 2026), saved for a separate session

Not started in this session: the first agent launch was stopped by a safety system before it ran (nothing was written).
The owner's spec is saved here verbatim so a separate session can scope and build it.

- Like AnyDesk/TeamViewer: control or view a PHONE or a LAPTOP/PC from another phone, PC or the web.
- Pairing: each device gets an Assisto ID + one-time code; or "My devices" (same account) for quick connect; family can be granted access explicitly.
- Assisto Desktop helper: Windows first (.exe built in CI like the Shop Box), then macOS/Linux; web client in the browser (view + control).
- Features: live screen view, remote input (mouse/keyboard/touch), file transfer both ways, clipboard sync, chat during the session, multi-monitor switch, auto quality for slow networks, optional session recording (consent), reboot-and-reconnect for own PCs.
- Android side: MediaProjection for the screen; AccessibilityService only for remote input, with Play-policy prominent disclosure + declaration text in PLAY_STORE_PACK.md; honest note that banking/secure apps show black (FLAG_SECURE).
- Consent & safety: per-session approval on the controlled device, always-visible "being controlled" indicator, one-tap Stop, auto-timeout; unattended access ONLY for the user's own devices with strong password + 2FA; full audit log; scam protection (warn when a new contact asks for control, block during calls from unknown numbers, cooling-off for money apps).
- Transport: WebRTC peer-to-peer via our signaling server; TURN fallback (turn.lifeassisto.com) counts credits per minute.
- Plans: Premium + credits/min; Business more devices/hours. Admin-editable.
- Real end-to-end test: phone → PC and PC → phone sessions with screenshots before shipping.
