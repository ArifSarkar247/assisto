"""halaladz: create (or refresh) the OFFICIAL HalalAdz community inside Assisto.

    python manage.py halaladz_community --owner <user id | phone> [--public]

Idempotent — run it again any time; nothing is duplicated. It REUSES the
existing engines (no parallel system):
  * Channel "HalalAdz কমিউনিটি" (@halaladz) — the owner posts, followers read
    and react; marked verified (official) by the owner; private invite link
    https://lifeassisto.com/ch/halaladz?k=<code> (or listed in the channel
    directory with --public).
  * Community "HalalAdz কমিউনিটি" — its announcements group (owner admin) +
    a discussion group "HalalAdz কমিউনিটি" (open join, owner admin), each
    backed by the real My Circle group chat. Invite link
    https://lifeassisto.com/cm/<code>; joining asks the owner (admin) first.
  * The QR for both links: open the channel / community in the app as the
    owner -> Invite (the existing invite sheet shows link + QR).
Does NOT need HALALADZ_SHARED_SECRET. Never run by CI against the live DB.
"""
from django.core.management.base import BaseCommand, CommandError
from django.db import transaction

NAME = "HalalAdz কমিউনিটি"
HANDLE = "halaladz"
CHANNEL_DESC = ("HalalAdz-এর অফিসিয়াল ঘোষণা চ্যানেল — নতুন খবর, অফার ও আপডেট। "
                "Official HalalAdz announcements.")
COMMUNITY_DESC = ("HalalAdz ব্যবহারকারীদের অফিসিয়াল কমিউনিটি — প্রশ্ন করুন, অভিজ্ঞতা "
                  "জানান। Official HalalAdz community.")
GROUP_SIZE = 1024   # circle_groups.SIZE_LIMIT_MAX


def find_owner(raw):
    from core.models import User
    raw = str(raw or "").strip()
    if not raw:
        return None
    if raw.isdigit() and len(raw) < 9:
        return User.objects.filter(pk=int(raw)).first()
    from core.phone import canonical_phone
    canon = canonical_phone(raw) or raw
    return (User.objects.filter(phone=canon).first()
            or User.objects.filter(phone=raw).first())


def ensure_official(owner, public=False):
    """Create / refresh everything. Returns (official row, created dict)."""
    from core import channels_service as CS
    from core.models import (Channel, Community, CommunityGroup, CommunityMember,
                             HalalAdzOfficial)
    created = {"channel": False, "community": False, "group": False}
    with transaction.atomic():
        off, _ = HalalAdzOfficial.objects.select_for_update().get_or_create(pk=1)
        # ---- channel
        ch = off.channel
        if ch is None:
            ch = Channel.objects.filter(handle=HANDLE, owner=owner).first()
        if ch is None:
            handle = HANDLE if not Channel.objects.filter(handle=HANDLE).exists() \
                else CS.auto_handle("halaladz_official")
            ch = Channel.objects.create(
                owner=owner, name=NAME, handle=handle, description=CHANNEL_DESC,
                category="community", language="bn", list_visibility="private",
                is_public=bool(public), invite_code=CS.new_code(Channel))
            created["channel"] = True
        fields = []
        for k, v in (("verified", True), ("verification_state", "verified"),
                     ("verified_by_id", owner.id)):
            if getattr(ch, k) != v:
                setattr(ch, k, v)
                fields.append(k.replace("_id", "") if k == "verified_by_id" else k)
        if public and not ch.is_public:
            ch.is_public = True
            fields.append("is_public")
        if not ch.invite_code:
            ch.invite_code = CS.new_code(Channel)
            fields.append("invite_code")
        if fields:
            ch.save(update_fields=sorted(set(fields)))
        # ---- community + announcements group
        c = off.community
        if c is None:
            c = Community.objects.create(
                creator=owner, name=NAME, description=COMMUNITY_DESC,
                is_public=False, invite_code=CS.new_code(Community))
            ann = CommunityGroup.objects.create(
                community=c, creator=owner, kind="announcements", name=NAME,
                join_mode="request", size_limit=GROUP_SIZE, announcements_only=True)
            CommunityMember.objects.create(community=c, group=ann, member=owner,
                                           role="admin", status="active")
            CS.ensure_circle_group(ann)
            created["community"] = True
        elif not c.invite_code:
            c.invite_code = CS.new_code(Community)
            c.save(update_fields=["invite_code"])
        # ---- discussion group
        g = off.group
        if g is None:
            g = CommunityGroup.objects.filter(community=c, kind="topic", name=NAME).first()
        if g is None:
            g = CommunityGroup.objects.create(
                community=c, creator=owner, kind="topic", name=NAME,
                description=COMMUNITY_DESC, join_mode="open", size_limit=GROUP_SIZE)
            created["group"] = True
        CommunityMember.objects.update_or_create(
            group=g, member=owner,
            defaults={"community": c, "role": "admin", "status": "active"})
        CS.mirror_member(g, owner.id, "admin", "active")
        off.owner, off.channel, off.community, off.group = owner, ch, c, g
        off.save()
    return off, created


class Command(BaseCommand):
    help = "Create / refresh the official HalalAdz channel + community (idempotent)."

    def add_arguments(self, parser):
        parser.add_argument("--owner", required=True,
                            help="Owner's Assisto user id or phone number")
        parser.add_argument("--public", action="store_true",
                            help="Also list the channel in the public directory")

    def handle(self, *args, **opts):
        from core import channels_service as CS
        owner = find_owner(opts["owner"])
        if owner is None or not owner.is_active:
            raise CommandError("owner not found (give the user id or phone number)")
        off, created = ensure_official(owner, public=opts["public"])
        self.stdout.write("channel   #%s %s (%s)" % (
            off.channel_id, "created" if created["channel"] else "kept",
            CS.channel_link(off.channel)))
        self.stdout.write("community #%s %s (%s)" % (
            off.community_id, "created" if created["community"] else "kept",
            CS.community_link(off.community)))
        self.stdout.write("group     #%s %s" % (
            off.group_id, "created" if created["group"] else "kept"))
        self.stdout.write("QR: open the channel / community in the app as the owner "
                          "-> Invite (link + QR).")
