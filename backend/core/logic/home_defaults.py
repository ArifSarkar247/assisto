"""
home_defaults.py — PURE engine for the owner's DEFAULT home quick buttons.

The app shows 6 one-tap shortcuts on home (app/lib/widgets/home_quick_buttons.dart).
A user who has never customized them sees the OWNER default, which the owner
edits from /admin/pricing (key `home_quick_defaults`, stored in the
PricingConfig single row — no migration). The app fetches it from
GET /app/home-defaults and uses it only while the user has not customized.

CATALOG mirrors `HomeQuickButtons.catalog` route keys in the Dart file; a test
(core.tests_home_defaults) parses the Dart source and fails if they drift.
Pure: no Django, no DB, no clock.
"""

COUNT = 6

# Mirrors HomeQuickButtons.catalog (Dart) — same keys, same order.
CATALOG = (
    "reminders", "money", "notes", "ai_chat", "family", "documents",
    "emergency", "safety", "budget", "money_voice", "photo_enhance",
    "birthdays", "meetings", "memory", "contacts", "medicine_db",
    "health_tips", "nearby", "journey", "scam", "my_lost_phone",
    "phone_safety", "vehicles", "subscriptions", "tax", "wrapped",
    "business", "crm", "shop_box", "inbox", "jobs", "dictionary",
)

# Mirrors HomeQuickButtons.defaults (Dart).
DEFAULT = ("reminders", "money", "notes", "ai_chat", "family", "documents")


def normalize(raw):
    """Project any stored value onto a clean list of exactly COUNT known,
    unique route keys (order kept; topped up from DEFAULT). Never raises."""
    items = raw if isinstance(raw, (list, tuple)) else []
    out = []
    for r in list(items) + list(DEFAULT):
        if len(out) == COUNT:
            break
        if isinstance(r, str) and r in CATALOG and r not in out:
            out.append(r)
    return out


def validate(raw):
    """Problem codes for an owner edit; empty == OK. Strict (unlike normalize):
    the owner must send exactly COUNT unique known keys."""
    if not isinstance(raw, (list, tuple)):
        return ["home_quick_not_list"]
    problems = []
    if len(raw) != COUNT:
        problems.append("home_quick_count")
    if any(not isinstance(r, str) or r not in CATALOG for r in raw):
        problems.append("home_quick_unknown")
    keys = [r for r in raw if isinstance(r, str)]
    if len(set(keys)) != len(keys):
        problems.append("home_quick_duplicate")
    return problems
