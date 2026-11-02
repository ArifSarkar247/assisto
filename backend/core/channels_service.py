"""channels (2 Nov) — My Circle CHANNELS + COMMUNITIES that other people can
actually find and join (owner phone-test bug: A's channel was invisible to B).

One place for the rules the views share:
  * directory: a channel is LISTED when is_public and content_status is
    visible, the owner is active and not a minor, and the viewer has not
    blocked it. Private channels open ONLY with their invite code.
  * links: https://<site>/ch/<handle>[?k=<code>] (channel) and
    https://<site>/cm/<code> (community) — Android App Links open the app,
    otherwise the web page offers the Play listing.
  * age rule: an account with a guardian (kids watch / school mode / child
    journey — core.guardianship) is a minor: its channels can never be public
    and never appear in the directory.
  * rate limits (cache counters, per user): channel create 5/day, community
    create 3/day, follows 60/hour, community join requests 20/hour, channel
    posts 50/day per channel.
  * push: a new post -> every follower (not muted, not blocked, not the
    author) gets a `channel_post` notification push; a community join request
    -> the community admins get `community_join`; approval -> the requester.
  * communities: every community group is backed by an E2E My Circle group
    (CircleGroup) so members really chat; membership is mirrored on join /
    approve / remove / leave.
Never raises into a view on push; everything else is plain ORM.
"""
from __future__ import annotations

import re
import secrets
import time

from django.core.cache import cache
from django.utils import timezone

CODE_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789"
CODE_LEN = 10

CHANNELS_PER_DAY = 5
COMMUNITIES_PER_DAY = 3
FOLLOWS_PER_HOUR = 60
JOINS_PER_HOUR = 20
POSTS_PER_DAY = 50
PUSH_FANOUT_CAP = 5000
HIDDEN = ("hidden", "removed")


# --------------------------------------------------------------- basics
def is_minor(user):
    """Existing age rule: a user with any guardian link is a child account."""
    if user is None:
        return False
    try:
        from . import guardianship
        return bool(guardianship.guardian_user_ids(user))
    except Exception:  # noqa: BLE001 — never block on the lookup
        return False


def new_code(model):
    for _ in range(12):
        c = "".join(secrets.choice(CODE_ALPHABET) for _ in range(CODE_LEN))
        if not model.objects.filter(invite_code=c).exists():
            return c
    raise RuntimeError("could not allocate an invite code")


def rate_ok(user, key, limit, window_s):
    """Count one action; False once `limit` is passed in this window."""
    k = "chrl:%s:%s:%d" % (key, getattr(user, "id", 0), int(time.time() // window_s))
    cache.add(k, 0, window_s + 30)
    try:
        n = cache.incr(k)
    except ValueError:
        n = 1
    return n <= limit


_ASCII = re.compile(r"[^a-z0-9_]")


def auto_handle(name):
    """A free @handle from the name (Bangla names -> 'channel_xxxx')."""
    from .models import Channel
    base = _ASCII.sub("", (name or "").strip().lower().replace(" ", "_"))[:20]
    if len(base) < 3:
        base = "channel"
    cand = base
    for _ in range(20):
        if not Channel.objects.filter(handle=cand).exists():
            return cand
        cand = "%s_%s" % (base[:20], "".join(
            secrets.choice("0123456789") for _ in range(4)))
    return "ch_%s" % secrets.token_hex(6)


def site_base():
    try:
        from . import invite_join as IJ
        return IJ.base_url().rstrip("/")
    except Exception:  # noqa: BLE001
        return "https://lifeassisto.com"


def play_url():
    try:
        from . import growth
        return ("https://play.google.com/store/apps/details?id=%s"
                % growth.play_package())
    except Exception:  # noqa: BLE001
        return "https://play.google.com/store/apps/details?id=com.lifeassisto.app"


def channel_link(ch):
    url = "%s/ch/%s" % (site_base(), ch.handle)
    if not ch.is_public and ch.invite_code:
        url += "?k=%s" % ch.invite_code
    return url


def community_link(c):
    return "%s/cm/%s" % (site_base(), c.invite_code)


# --------------------------------------------------------------- channels
def admin_ids(ch):
    return set(ch.admins.values_list("user_id", flat=True))


def role(ch, user, admins=None):
    uid = getattr(user, "id", None)
    if uid is None:
        return "viewer"
    if ch.owner_id == uid:
        return "owner"
    if uid in (admins if admins is not None else admin_ids(ch)):
        return "admin"
    return "follower"


def blocked_ids(user):
    from .models import ChannelBlock
    return set(ChannelBlock.objects.filter(user=user)
               .values_list("channel_id", flat=True))


def listed(ch):
    return bool(ch.is_public and ch.content_status not in HIDDEN)


def directory_qs():
    from .models import Channel
    return (Channel.objects.filter(is_public=True, owner__is_active=True)
            .exclude(content_status__in=HIDDEN)
            .exclude(owner__account_status__in=["suspended", "banned"]))


def drop_minor_owned(channels):
    """Remove channels whose owner is (now) a minor — one lookup per owner."""
    seen = {}
    out = []
    for ch in channels:
        if ch.owner_id not in seen:
            seen[ch.owner_id] = is_minor(ch.owner)
        if not seen[ch.owner_id]:
            out.append(ch)
    return out


def can_view(ch, user, code=""):
    """Public + visible -> anyone. Otherwise owner/admin/follower, or the
    right invite code for a private channel."""
    from .models import ChannelFollower
    r = role(ch, user)
    if r in ("owner", "admin"):
        return True
    if ch.content_status == "removed":
        return False
    if listed(ch):
        return True
    if ChannelFollower.objects.filter(channel=ch, user=user).exists():
        return True
    return bool(code) and bool(ch.invite_code) and secrets.compare_digest(
        str(code), ch.invite_code)


def channel_view(ch, user, follower=None, admins=None, blocked=None,
                 with_follow=True):
    """The client shape (messenger_channel_api.dart) + the legacy keys."""
    from .logic import msg_channel as mch
    from .models import ChannelFollower
    admins = admin_ids(ch) if admins is None else admins
    r = role(ch, user, admins)
    if follower is None and with_follow and user is not None:
        follower = ChannelFollower.objects.filter(channel=ch, user=user).first()
    is_admin = r in ("owner", "admin")
    d = {
        "id": ch.id, "channel_id": ch.id, "owner_id": ch.owner_id,
        "name": ch.name, "handle": ch.handle, "description": ch.description,
        "category": ch.category, "language": ch.language,
        "photo_ref": ch.photo_ref, "admin_ids": sorted(admins),
        "list_visibility": ch.list_visibility,
        "is_public": bool(ch.is_public), "listed": listed(ch),
        "content_status": ch.content_status,
        "verified": ch.verified, "verified_by": ch.verified_by_id,
        "verification_state": ch.verification_state,
        "is_verified": mch.is_verified({"verified": ch.verified,
                                        "verified_by": ch.verified_by_id}),
        "follower_count": ch.follower_count,
        "is_owner": r == "owner", "is_admin": is_admin,
        "can_publish": is_admin,
        "my_following": follower is not None,
        "following": follower is not None,
        "my_muted": bool(follower and follower.muted),
        "my_visibility": follower.visibility if follower else None,
        "blocked": bool(blocked and ch.id in blocked),
        "share_url": channel_link(ch) if (ch.is_public or is_admin) else None,
        "created_at": ch.created_at.isoformat() if ch.created_at else None,
    }
    return d


def post_dict(p, me=None):
    return {"id": p.id, "channel_id": p.channel_id, "author_id": p.author_id,
            "kind": p.kind, "e2e": p.e2e, "content_scheme": p.content_scheme,
            "text": p.text, "media_refs": p.media_refs,
            "link_url": p.link_url or None, "reactions": p.reactions or {},
            "views": p.views, "pinned": p.pinned,
            "created_at": p.created_at.isoformat()}


def post_push_texts(ch, post):
    """(title_bn, title_en, body_bn, body_en) for a channel-post push. The
    title is the channel name; the body a short preview (channels are not
    E2E — the text is already plaintext/moderatable on the server)."""
    text = " ".join((post.text or "").split())
    if len(text) > 120:
        text = text[:117] + "…"
    if text:
        body_bn = body_en = text
    elif post.kind == "photo":
        body_bn, body_en = "নতুন ছবি", "New photo"
    elif post.kind == "video":
        body_bn, body_en = "নতুন ভিডিও", "New video"
    elif post.kind == "poll":
        body_bn, body_en = "নতুন জরিপ", "New poll"
    else:
        body_bn, body_en = "নতুন পোস্ট", "New post"
    return ch.name, ch.name, body_bn, body_en


def notify_post(ch, post, author):
    """Push the new post to followers. Muted / blocked / author skipped.
    Returns how many pushes were queued. Never raises."""
    try:
        from . import push
        from .models import ChannelBlock, ChannelFollower
        blocked = set(ChannelBlock.objects.filter(channel=ch)
                      .values_list("user_id", flat=True))
        rows = (ChannelFollower.objects.filter(channel=ch, muted=False)
                .exclude(user_id=author.id).select_related("user")
                .order_by("id")[:PUSH_FANOUT_CAP])
        tb, te, bb, be = post_push_texts(ch, post)
        data = {"route": "channels", "channel_id": str(ch.id),
                "post_id": str(post.id), "handle": ch.handle}
        n = 0
        for f in rows:
            if f.user_id in blocked:
                continue
            if push.safe_push(f.user, "channel_post", tb, te, bb, be, data=data):
                n += 1
        return n
    except Exception:  # noqa: BLE001
        return 0


# --------------------------------------------------------------- communities
def ensure_circle_group(cg):
    """The E2E group chat behind a community group (created once, members
    mirrored). Returns the CircleGroup or None."""
    from .models import CircleGroup, CircleGroupMember, CommunityMember
    try:
        if cg.circle_group_id:
            return cg.circle_group
        g = CircleGroup.objects.create(
            creator=cg.creator, name=("%s · %s" % (cg.community.name, cg.name))[:100],
            description=cg.description or "", size_limit=max(2, cg.size_limit),
            announcements_only=bool(cg.announcements_only))
        cg.circle_group = g
        cg.save(update_fields=["circle_group"])
        for m in CommunityMember.objects.filter(group=cg, status="active"):
            CircleGroupMember.objects.update_or_create(
                group=g, member_id=m.member_id,
                defaults={"role": m.role, "status": "active"})
        return g
    except Exception:  # noqa: BLE001
        return None


def mirror_member(cg, user_id, role_="member", status_="active"):
    from .models import CircleGroupMember
    g = ensure_circle_group(cg)
    if g is None:
        return
    CircleGroupMember.objects.update_or_create(
        group=g, member_id=user_id,
        defaults={"role": role_, "status": status_})


def community_role(community, user):
    from .models import CommunityMember
    roles = set(CommunityMember.objects.filter(
        community=community, member=user, status="active")
        .values_list("role", flat=True))
    if "admin" in roles:
        return "admin"
    return "member" if roles else None


def community_view(c, user, role_=None):
    from .models import CommunityMember
    role_ = role_ if role_ is not None else community_role(c, user)
    members = (CommunityMember.objects.filter(community=c, status="active")
               .values("member_id").distinct().count())
    d = {"id": c.id, "name": c.name, "description": c.description,
         "photo_ref": c.photo_ref, "is_public": c.is_public,
         "viewer_role": role_, "member_count": members,
         "group_count": c.groups.count(),
         "created_at": c.created_at.isoformat() if c.created_at else None}
    if role_ == "admin":
        if not c.invite_code:
            c.invite_code = new_code(type(c))
            c.save(update_fields=["invite_code"])
        d["invite_url"] = community_link(c)
        d["invite_code"] = c.invite_code
    return d


def notify_join_request(group, requester):
    try:
        from . import push
        from .models import CommunityMember
        admins = (CommunityMember.objects.filter(
            community=group.community, role="admin", status="active")
            .select_related("member"))
        who = push.display_name(requester)
        seen = set()
        for m in admins:
            if m.member_id in seen or m.member_id == requester.id:
                continue
            seen.add(m.member_id)
            push.safe_push(
                m.member, "community_join", group.community.name,
                group.community.name,
                "%s যোগ দিতে চান — অনুমতি দিন বা না করুন" % who,
                "%s wants to join — approve or decline" % who,
                data={"route": "communities",
                      "community_id": str(group.community_id)})
    except Exception:  # noqa: BLE001
        pass


def notify_join_approved(group, user):
    try:
        from . import push
        push.safe_push(
            user, "community_join", group.community.name, group.community.name,
            "আপনাকে যোগ করা হয়েছে", "You're in — your request was approved",
            data={"route": "communities", "community_id": str(group.community_id)})
    except Exception:  # noqa: BLE001
        pass


def now():
    return timezone.now()
