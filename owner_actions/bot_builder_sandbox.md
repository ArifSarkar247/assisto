# User Telegram-bot builder — sandbox architecture (⛔ not run on this server)

**Why ⛔:** executing user-generated bots/code on the live Asalify+Assisto host
is unsafe (RCE, resource abuse, data exfiltration). It needs a SEPARATE,
isolated sandbox server. Below is the design to build it later. Assisto will
ship the **UI + control API**; only the execution runtime is deferred.

## Components
1. **Builder UI (in Assisto app):** no-code flow builder (triggers → conditions →
   actions: send message, ask, call an allowed API, store a value). Saves a JSON
   bot definition. (Buildable here.)
2. **Control API (Assisto backend):** CRUD for bot definitions, deploy/stop,
   logs, quotas. Stores the user's Telegram bot token encrypted in the
   Integrations store. (Buildable here.)
3. **Sandbox runtime (SEPARATE server — deferred):**
   - A small VM/container host (e.g. a cheap separate VPS), NOT this box.
   - Each bot runs in its own locked-down container: no host FS, read-only
     rootfs, dropped capabilities, seccomp, non-root user, no outbound network
     except an allow-list, strict CPU/RAM/time quotas (cgroups), per-bot
     network namespace.
   - A tiny, safe interpreter for the JSON bot definition — NOT arbitrary code
     execution. Only whitelisted action nodes run. No eval/exec of user code.
   - Telegram webhooks terminate at the sandbox; it talks back to the Assisto
     control API over an authenticated channel.
   - Hard per-user rate limits + a global kill-switch.

## Safety rules
- Never run user code on the Asalify/Assisto host.
- Interpret a constrained flow definition; do not exec arbitrary code.
- Outbound network allow-list only; no access to other users' data or secrets.
- Everything quota-capped + audit-logged; one-tap stop.

## Build order when ready
UI + control API (here) → provision the separate sandbox VPS → container runtime
+ JSON-flow interpreter → wire Telegram webhooks → beta with one test bot.
