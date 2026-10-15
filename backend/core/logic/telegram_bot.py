"""Telegram bot SANDBOX (Step 6) — a pure, deterministic command router +
reply formatter. The actual Telegram transport (webhook/sendMessage) is gated
on the owner's bot token in the Integrations registry (`telegram`): with NO
token the webhook is INERT (does nothing), so this ships safely as a sandbox and
flips live only when the owner pastes a token.

PURE: no Django, no DB, no network. The webhook view supplies the token check
and the actual HTTP send; this module only decides WHAT to reply.
"""

HELP_BN = (
    "Assisto বট কমান্ড:\n"
    "/help — এই সাহায্য\n"
    "/link <code> — আপনার Assisto অ্যাকাউন্টের সাথে যুক্ত করুন\n"
    "/balance — পয়েন্ট ব্যালেন্স\n"
    "/remind <text> — দ্রুত রিমাইন্ডার\n"
    "/stop — বট বন্ধ করুন"
)
HELP_EN = (
    "Assisto bot commands:\n"
    "/help — this help\n"
    "/link <code> — link your Assisto account\n"
    "/balance — your points balance\n"
    "/remind <text> — a quick reminder\n"
    "/stop — stop the bot"
)

KNOWN = ("/start", "/help", "/link", "/balance", "/remind", "/stop")


def parse_command(text):
    """Split an incoming message into (command, argument). Non-commands return
    (None, text). Handles '/cmd@botname' and surrounding whitespace."""
    text = (text or "").strip()
    if not text.startswith("/"):
        return (None, text)
    head, _, rest = text.partition(" ")
    cmd = head.split("@", 1)[0].lower()   # strip @botname suffix
    return (cmd, rest.strip())


def route(text, *, lang="en", is_linked=False):
    """Decide the bot's reply to a message. Deterministic + offline.

    Returns {"reply": str, "action": str|None, "arg": str}:
      action ∈ {None,'link','balance','remind','stop'} — the webhook performs the
      side-effect (only for a LINKED chat); unknown/unlinked get a safe reply.
    """
    bn = (lang == "bn")
    cmd, arg = parse_command(text)

    if cmd in (None, "/start", "/help"):
        return {"reply": HELP_BN if bn else HELP_EN, "action": None, "arg": ""}

    if cmd == "/link":
        if not arg:
            msg = ("লিংক কোড দিন: /link <code>" if bn
                   else "Send your link code: /link <code>")
            return {"reply": msg, "action": None, "arg": ""}
        return {"reply": ("যাচাই করা হচ্ছে…" if bn else "Checking…"),
                "action": "link", "arg": arg}

    # Everything below needs a linked account.
    if not is_linked:
        msg = ("আগে /link <code> দিয়ে অ্যাকাউন্ট যুক্ত করুন।" if bn
               else "Link your account first with /link <code>.")
        return {"reply": msg, "action": None, "arg": ""}

    if cmd == "/balance":
        return {"reply": "", "action": "balance", "arg": ""}
    if cmd == "/remind":
        if not arg:
            msg = ("কীসের রিমাইন্ডার? /remind <text>" if bn
                   else "Remind you of what? /remind <text>")
            return {"reply": msg, "action": None, "arg": ""}
        return {"reply": "", "action": "remind", "arg": arg}
    if cmd == "/stop":
        return {"reply": ("বট বন্ধ করা হলো।" if bn else "Bot stopped."),
                "action": "stop", "arg": ""}

    # Unknown command.
    msg = ("বুঝিনি। /help দেখুন।" if bn else "Didn't get that. Try /help.")
    return {"reply": msg, "action": None, "arg": ""}


def sandbox_status(has_token):
    """Honest status for the owner console: inert until a token is configured."""
    return {
        "live": bool(has_token),
        "state": "live" if has_token else "sandbox_inert",
        "note_en": ("Bot is live." if has_token
                    else "No bot token set — the webhook is inert (sandbox)."),
        "note_bn": ("বট সক্রিয়।" if has_token
                    else "বট টোকেন নেই — ওয়েবহুক নিষ্ক্রিয় (sandbox)।"),
    }
