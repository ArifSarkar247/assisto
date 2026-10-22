BATCH 6 — NATIVE ALWAYS-ON LOST/STOLEN ENGINE (owner's detailed spec; protects the user's OWN phone, opt-in)
- Opt-in, lazy, crash-guarded; NOTHING at app launch; no WorkManager (it crashed the Realme 9i);
  ship only on a real release launch test pass.
- Heartbeat: periodic check-in to the server (battery-aware); server already raises the
  "went dark" alert to family when check-ins stop (check_went_dark cron) — wire it end-to-end.
- Snatch trigger: accelerometer pattern (sudden grab + run) while unlocked → optional instant
  lock + alert to family with last location.
- SIM-change guard: new/removed SIM → alert family with new number info (where Android allows),
  last location, time.
- Airplane-mode / power-off guard: honest — no app can block airplane mode or shutdown; instead
  send last location + "phone went offline at X" the moment it happens (store-and-forward when
  offline, deliver when connectivity returns), and guide users to enable the brand locks
  (Samsung "Lock network and security", Google Theft Detection / Offline Device Lock).
- Intruder photo: front-camera photo (CameraX) after N failed unlocks via the existing device-admin
  receiver; photo encrypted, sent to the owner/family when online.
- Battery/shutdown last location: on low battery and on shutdown broadcast, send last location.
- Store-and-forward queue for every event when offline; dedupe; privacy: only the owner and
  approved family see it.
- Real-device test checklist for realme/ColorOS (autostart, battery optimisation) in Bangla.
