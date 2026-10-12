# Assisto — Human AI Agent

Bangla-first personal AI agent. Android app (Flutter) + Django/PostgreSQL backend.

- `backend/` — Django + DRF API (dev on this server, port 8700; moves to its own server later).
- `app/` — Flutter app (Android first).
- `.github/workflows/` — cloud APK builds (GitHub Actions).

**All URLs come from one setting** (`ASSISTO_BASE_URL` in the backend, `API_BASE` dart-define in the app) so the backend can move to its own server with zero change for users.

This project is fully separate from the Asalify platform running on the same server. See `ASSISTO_REPORT.md` for status and the move plan.
