"""cde-chat (order 6 D + E) — shared per-chat THEME + NICKNAMES.

One `ChatDecor` row per chat (1:1 pair or group), shared by every side. The
phones change it through E2E control messages inside the chat (instant, works
for an offline peer); this module is the server copy that

  * enforces Free vs Premium for themes (`FREE_THEMES`; custom photo + AI and
    every other preset need a paid plan),
  * validates + cleans nicknames,
  * stamps the write time every phone uses for "newest wins",
  * lets a reinstall / second phone catch up (GET),
  * feeds the nickname into server-built names (push titles, caller name,
    member payloads, notification pull).

PRIVACY: only a theme id and short nicknames are stored. A custom photo theme
is an E2E media message — the server knows `theme == "custom"`, never the
photo key.
"""
import re

from django.utils import timezone

# The curated catalogue (ids mirror app/lib/messaging/chat_decor/chat_themes.dart).
THEMES = ("classic", "love", "roses", "moonlight", "sunset", "calm",
          "midnight", "forest", "eid", "birthday", "anniversary",
          "custom", "ai")
FREE_THEMES = ("classic", "love", "sunset", "calm")
NICK_MAX = 40

_CTRL = re.compile(r"[\x00-\x1f\x7f  ⁠-⁤﻿‪-‮⁦-⁩]")
_WS = re.compile(r"\s+")


class DecorError(Exception):
    def __init__(self, reason, status=400):
        super().__init__(reason)
        self.reason = reason
        self.status = status


def clean_nick(raw):
    """A display-safe nickname ('' = remove). Control / invisible formatting
    characters are dropped (ZWJ/ZWNJ stay: Bangla needs them), whitespace is
    collapsed, length capped."""
    s = _CTRL.sub("", str(raw or ""))
    s = _WS.sub(" ", s).strip()
    return s[:NICK_MAX].strip()


def is_premium(user):
    try:
        from . import plans
        return plans.effective_plan(user) != "free"
    except Exception:
        return False


def theme_allowed(user, theme_id):
    if theme_id not in THEMES:
        raise DecorError("unknown_theme")
    if theme_id in FREE_THEMES:
        return True
    return is_premium(user)


def pair_key(uid_a, uid_b):
    a, b = sorted([int(uid_a), int(uid_b)])
    return "%d:%d" % (a, b)


def _row(kind, key, create=False):
    from .models import ChatDecor
    if create:
        return ChatDecor.objects.get_or_create(kind=kind, key=key)[0]
    return ChatDecor.objects.filter(kind=kind, key=key).first()


def edge_peer(edge):
    from .e2_keys import edge_peer as _peer
    return _peer(edge)


def member_row(edge, create=False):
    """The shared row of a 1:1 chat, from EITHER side's CircleMember edge."""
    peer = edge_peer(edge)
    if peer is None:
        return None, None
    return _row("member", pair_key(edge.user_id, peer.pk), create), peer


def group_row(group, create=False):
    return _row("group", str(group.pk), create)


def ms(dt):
    return int(dt.timestamp() * 1000) if dt else 0


def nick_of(row, uid):
    if row is None:
        return ""
    v = (row.nicknames or {}).get(str(uid))
    if isinstance(v, dict):
        return str(v.get("n") or "")
    return ""


def nick_at(row, uid):
    if row is None:
        return 0
    v = (row.nicknames or {}).get(str(uid))
    if isinstance(v, dict):
        try:
            return int(v.get("at_ms") or 0)
        except (TypeError, ValueError):
            return 0
    return 0


def set_theme(row, user, theme_id):
    if not theme_allowed(user, theme_id):
        raise DecorError("premium_required", 402)
    now = timezone.now()
    row.theme = "" if theme_id == "classic" else theme_id
    row.theme_by = user.pk
    row.theme_at = now
    row.save(update_fields=["theme", "theme_by", "theme_at", "updated_at"])
    return now


def set_nick(row, user, target_uid, name):
    nick = clean_nick(name)
    now = timezone.now()
    m = dict(row.nicknames or {})
    m[str(int(target_uid))] = {"n": nick, "by": user.pk,
                               "at_ms": ms(now)}
    row.nicknames = m
    row.save(update_fields=["nicknames", "updated_at"])
    return nick, now


def theme_block(row, me):
    if row is None:
        return {"id": "classic", "by_me": False, "at_ms": 0}
    return {"id": row.theme or "classic",
            "by_me": bool(row.theme_by and row.theme_by == me.pk),
            "at_ms": ms(row.theme_at)}


def catalog(user):
    return {"premium": is_premium(user), "free_themes": list(FREE_THEMES),
            "themes": list(THEMES)}


# ---------------------------------------------------------------- name helpers
def nickname_seen_by(viewer, target, group=None):
    """The nickname `viewer` sees for `target` in their 1:1 chat (or in
    `group`), '' when none. Never raises (used inside push / payload code)."""
    try:
        if viewer is None or target is None:
            return ""
        if group is not None:
            return nick_of(group_row(group), target.pk)
        return nick_of(_row("member", pair_key(viewer.pk, target.pk)), target.pk)
    except Exception:
        return ""


def edge_nicknames(edge):
    """(peer nickname, my nickname, theme id) of a 1:1 chat for its owner's
    payloads. Never raises."""
    try:
        row, peer = member_row(edge)
        if row is None or peer is None:
            return "", "", "classic"
        return (nick_of(row, peer.pk), nick_of(row, edge.user_id),
                row.theme or "classic")
    except Exception:
        return "", "", "classic"
