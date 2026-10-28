"""P3 — My Circle: @Assisto (credits-gated AI over text the USER chose to send),
E2E Stories (per-viewer ciphertext, photo via circle_media_blobs) and profile
Notes. Design + privacy rules: .phaseB/P3_DESIGN.md.

THE SERVER NEVER READS A CHAT. /circle/assisto/run only ever receives text the
user's phone decrypted and the user explicitly chose to send (consent flag
required for chat content); the text is passed to core.ai.generate inside its
<data> fence and never stored or logged (AIUsage keeps token counts only).
"""
from datetime import timedelta

from django.contrib.auth import get_user_model
from django.utils import timezone
from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from . import ai, billing, circle_blobs, e2_keys
from .i18n import req_lang
from .logic import circle_status as S
from .logic import p3_assisto as P3
from .logic import pricing
from .models import (CircleMember, CircleNote, CirclePrivacy, CircleStatus,
                     StatusMute, StatusView)
from .views_m2 import CircleStatusView as _M2StatusView
from .views_m2 import _blocked_either, _can_view

User = get_user_model()


def _err(code, http=status.HTTP_400_BAD_REQUEST, **extra):
    return Response({"ok": False, "error": code, **extra}, status=http)


def _spendable(user):
    billing.ensure_monthly_pool(user)
    bal = int(getattr(user, "ai_credits", 0) or 0)
    try:
        if billing._is_free(user):  # noqa: SLF001 — same rule charge() uses
            bal += billing.ad_wallet_credits(user)
    except Exception:  # noqa: BLE001
        pass
    return bal


# ===========================================================================
# @Assisto — quote + run
# ===========================================================================
class AssistoQuoteView(APIView):
    """GET /circle/assisto/quote -> the credit cost of each AI action BEFORE
    running it (owner-editable pricing), the user's spendable balance and
    whether AI is available at all. Non-AI actions are listed as free."""
    def get(self, request):
        c = billing.cfg()
        acts = {}
        for name, spec in P3.ACTIONS.items():
            action = pricing.TIER_ACTION.get(spec["tier"], "ai_msg_cheap")
            acts[name] = {"credits": pricing.credits_for(action, 1, c),
                          "needs_consent": spec["content"]}
        return Response({
            "actions": acts,
            "free": ["reminder", "split", "list", "arrived", "sos", "med",
                     "lost", "scam_check"],
            "balance": _spendable(request.user),
            "ai_available": ai.available(),
            "max_messages": P3.MAX_MESSAGES,
            "max_chars": P3.MAX_CHARS,
        })


class AssistoRunView(APIView):
    """POST /circle/assisto/run {action, messages?|text?|question?, target?,
    consent} -> {ok, result, charged, balance}. Charged through core.ai.generate
    (atomic pre-charge + refund on provider failure + Profit Guard)."""
    def post(self, request):
        d = request.data or {}
        try:
            req = P3.validate(d.get("action"), messages=d.get("messages"),
                              text=d.get("text", ""),
                              question=d.get("question", ""),
                              target=d.get("target", "en"),
                              consent=d.get("consent") is True)
        except P3.P3Error as e:
            return _err(e.code)
        lang = req_lang(request)
        # AF-3: crisis handover BEFORE any AI call, 0 credits. The user's own
        # question gets the full answer + the "tell my family" offer; someone
        # ELSE's messages (summarize / translate) get the "someone may be in
        # danger" line and the numbers. Nothing is stored or logged but
        # {score, category}; the AI task is not run in this turn.
        from .agentcore import crisis_guard as CG
        crisis = CG.detect("\n".join([req.get("question") or "", req.get("text") or ""]
                                     + list(req.get("lines") or [])))
        if crisis["crisis"]:
            reply, card = CG.respond(request.user, crisis, lang, surface="circle",
                                     own_words=req["action"] == "ask")
            return Response({"ok": True, "action": req["action"], "result": reply,
                             "crisis": card, "charged": 0,
                             "balance": _spendable(request.user)})
        task, data, max_tokens = P3.build_prompt(req, lang=lang)
        before = _spendable(request.user)
        try:
            text, _cost = ai.generate(task, data=data, tier=req["tier"],
                                      max_tokens=max_tokens,
                                      feature="circle_assisto_" + req["action"],
                                      user=request.user, pii=True)   # AF-2
        except ai.AIUnavailable as e:
            code = {"credits": ("credits", status.HTTP_402_PAYMENT_REQUIRED),
                    "budget": ("paused", status.HTTP_429_TOO_MANY_REQUESTS),
                    "user_limit": ("limit", status.HTTP_429_TOO_MANY_REQUESTS),
                    "no_key": ("ai_off", status.HTTP_503_SERVICE_UNAVAILABLE),
                    }.get(e.reason, ("busy", status.HTTP_503_SERVICE_UNAVAILABLE))
            return _err(code[0], code[1], balance=_spendable(request.user))
        if req["action"] == "ask":
            from . import ai_guard     # aieval: same cleanup as the home chat
            text, _flags = ai_guard.clean_assistant_answer(text, lang)
        request.user.refresh_from_db()
        after = _spendable(request.user)
        return Response({"ok": True, "action": req["action"],
                         "result": (text or "").strip(),
                         "charged": max(0, before - after), "balance": after})


# ===========================================================================
# Shared circle helpers (stories + notes)
# ===========================================================================
def _peer_ids(user):
    """User ids of my ACCEPTED, unblocked circle contacts."""
    out = set()
    for e in CircleMember.objects.filter(user=user, state="accepted",
                                         blocked=False):
        pid = e.peer_user_id
        if pid is None:
            p = e2_keys.edge_peer(e)
            pid = p.id if p is not None else None
        if pid:
            out.add(pid)
    out.discard(user.id)
    return out


def _privacy_row(user):
    row, _ = CirclePrivacy.objects.get_or_create(user=user)
    return row


def _defaults(user):
    vis = (_privacy_row(user).visibility or {})
    return {"status": P3.normalize_privacy(vis.get("status_default")),
            "note": P3.normalize_privacy(vis.get("note_default"))}


# ===========================================================================
# Stories (24 h, E2E per viewer)
# ===========================================================================
def _story_visible(st, me, peers):
    """A p3 story is visible to `me` when: not expired, author is my circle
    contact, the author sealed a copy for me, and the server-side audience
    check (block both ways, mute, privacy mode) passes."""
    if st.expires_at <= timezone.now():
        return False
    if st.author_id == me.id:
        return True
    if st.author_id not in peers:
        return False
    if not st.per_recipient or str(me.id) not in st.per_recipient:
        return False
    return _can_view(st.author, me, st)


def _story_payload(st, me, now):
    mine = (st.per_recipient or {}).get(str(me.id)) or {}
    return {
        "id": st.id, "author_id": st.author_id, "kind": st.kind,
        "ciphertext": mine.get("ciphertext", ""),
        "nonce": mine.get("nonce", ""),
        "scheme": st.scheme, "sender_key_id": st.sender_key_id,
        "blob_ref": st.blob_ref,
        "created_at": st.created_at.isoformat(),
        "expires_at": st.expires_at.isoformat(),
        "seconds_remaining": S.seconds_remaining(
            {"expires_at": st.expires_at.isoformat()}, now=now),
        "seen": StatusView.objects.filter(status=st, viewer=me).exists(),
    }


class StoryTrayView(_M2StatusView):
    """GET /circle/status -> {entries:[{author_id, name, count, has_unseen,
    latest_at}], mine:{count, viewer_count}|null, muted:[...]} — only my
    circle contacts' ACTIVE stories sealed for me. POST: a p3 story when
    `per_recipient` is present (else the legacy M2 path)."""
    def get(self, request):
        me = request.user
        now = timezone.now()
        peers = _peer_ids(me)
        muted = set(StatusMute.objects.filter(muter=me).values_list(
            "author_id", flat=True))
        rows = []
        for st in CircleStatus.objects.filter(
                expires_at__gt=now, author_id__in=peers).select_related("author"):
            if st.author_id in muted:
                continue
            if not _story_visible(st, me, peers):
                continue
            seen = StatusView.objects.filter(status=st, viewer=me).exists()
            rows.append({"id": st.id, "author_id": st.author_id,
                         "created_at": st.created_at.isoformat(),
                         "views": [{"viewer": me.id}] if seen else []})
        entries = S.group_by_author(rows, me.id, now=now)
        names = dict(User.objects.filter(
            id__in=[e["author_id"] for e in entries]).values_list("id", "name"))
        for e in entries:
            e["name"] = names.get(e["author_id"], "") or ""
        mine_qs = CircleStatus.objects.filter(author=me, expires_at__gt=now)
        mine = None
        if mine_qs.exists():
            mine = {"count": mine_qs.count(),
                    "viewer_count": StatusView.objects.filter(
                        status__in=mine_qs).values("viewer").distinct().count(),
                    "latest_at": mine_qs.first().created_at.isoformat()}
        muted_rows = [{"author_id": u.id, "name": u.name or ""}
                      for u in User.objects.filter(id__in=muted & peers)]
        return Response({"tray": entries, "entries": entries, "mine": mine,
                         "muted": muted_rows})

    def post(self, request):
        d = request.data or {}
        if not d.get("per_recipient"):
            return super().post(request)
        kind = d.get("kind", "text")
        if kind not in ("text", "photo"):
            return _err("kind_unsupported")
        try:
            per = P3.validate_per_recipient(d.get("per_recipient"))
        except P3.P3Error as e:
            return _err(e.code)
        peers = _peer_ids(request.user)
        # only circle contacts (+ my own copy) may be addressed
        per = {k: v for k, v in per.items()
               if int(k) in peers or int(k) == request.user.id}
        blob_ref = ""
        if kind == "photo":
            blob, why = circle_blobs.attach_check(request.user,
                                                  d.get("blob_ref", ""), "photo")
            if blob is None:
                return _err(why or "blob_missing")
            blob_ref = blob.ref
            circle_blobs.add_recipients(
                blob, [int(k) for k in per if int(k) != request.user.id])
        vis = S.normalize_visibility(
            d.get("visibility") or _defaults(request.user)["status"])
        now = timezone.now()
        st = CircleStatus.objects.create(
            author=request.user, kind=kind, ciphertext="", nonce="",
            scheme=str(d.get("scheme", ""))[:64],
            sender_key_id=str(d.get("sender_key_id", ""))[:64],
            blob_ref=blob_ref, meta={"p3": 1, "kind": kind},
            visibility=vis, per_recipient=per,
            expires_at=now + S.status_ttl())
        return Response({"ok": True, "id": st.id,
                         "expires_at": st.expires_at.isoformat(),
                         "audience": len([k for k in per
                                          if int(k) != request.user.id])},
                        status=status.HTTP_201_CREATED)


class StoryAuthorView(APIView):
    """GET /circle/status/author/<uid> -> that author's ACTIVE stories I may
    see, each carrying ONLY my own ciphertext entry."""
    def get(self, request, uid):
        me = request.user
        now = timezone.now()
        peers = _peer_ids(me)
        out = []
        for st in CircleStatus.objects.filter(
                author_id=uid, expires_at__gt=now).select_related(
                "author").order_by("created_at"):
            if _story_visible(st, me, peers):
                out.append(_story_payload(st, me, now))
        return Response({"results": out, "statuses": out})


class StoryMineView(APIView):
    """GET /circle/status/mine -> my active stories (my self copy) + NAMED
    viewers (read-receipts ON) + anonymous count."""
    def get(self, request):
        me = request.user
        now = timezone.now()
        out = []
        for st in CircleStatus.objects.filter(
                author=me, expires_at__gt=now).order_by("created_at"):
            views = [{"viewer": v.viewer_id, "at": v.at.isoformat(),
                      "anonymous": v.anonymous}
                     for v in StatusView.objects.filter(status=st)]
            named = S.named_viewers(views)
            names = dict(User.objects.filter(
                id__in=[n["viewer"] for n in named]).values_list("id", "name"))
            p = _story_payload(st, me, now)
            total = S.viewer_count(views)
            named_out = [{"viewer_id": n["viewer"],
                          "name": names.get(n["viewer"], "") or "",
                          "at": n.get("at")} for n in named]
            p.update({"viewer_count": total,
                      "anonymous_count": total - len(named_out),
                      "named_viewers": named_out,
                      "visibility": st.visibility or {}})
            out.append(p)
        return Response({"results": out, "statuses": out})


class StoryDeleteView(APIView):
    """POST /circle/status/<id>/delete -> the author removes a story now (its
    views go with it; a photo's blob is released)."""
    def post(self, request, pk):
        st = CircleStatus.objects.filter(pk=pk, author=request.user).first()
        if st is None:
            return Response({"detail": "not found"},
                            status=status.HTTP_404_NOT_FOUND)
        ref = st.blob_ref
        st.delete()
        if ref and not CircleStatus.objects.filter(blob_ref=ref).exists():
            circle_blobs.release(ref)
        return Response({"ok": True})


class CirclePrivacyDefaultsView(APIView):
    """GET/POST /circle/status/privacy -> the default audience for my stories
    and notes: {status:{mode,allow_ids,except_ids}, note:{...}}; modes are
    everyone (My contacts) / except (My contacts except…) / chosen (Only share
    with…). Ids are circle contacts' user ids."""
    def get(self, request):
        return Response(_defaults(request.user))

    def post(self, request):
        d = request.data or {}
        row = _privacy_row(request.user)
        vis = dict(row.visibility or {})
        if "status" in d:
            vis["status_default"] = P3.normalize_privacy(d.get("status"))
        if "note" in d:
            vis["note_default"] = P3.normalize_privacy(d.get("note"))
        row.visibility = vis
        row.save(update_fields=["visibility"])
        return Response(_defaults(request.user))


# ===========================================================================
# Profile Notes (60 chars, 24 h, E2E per viewer)
# ===========================================================================
NOTE_TTL = timedelta(hours=24)
NOTE_CT_MAX = 1024   # a 60-char note sealed + base64 is far below this


def _note_out(n, me):
    mine = (n.per_recipient or {}).get(str(me.id)) or {}
    return {"id": n.id, "author_id": n.author_id,
            "ciphertext": mine.get("ciphertext", ""),
            "nonce": mine.get("nonce", ""), "scheme": n.scheme,
            "sender_key_id": n.sender_key_id,
            "created_at": n.created_at.isoformat(),
            "expires_at": n.expires_at.isoformat()}


class CircleNotesView(APIView):
    """GET  /circle/notes -> {mine, notes:[...]} (contacts' active notes sealed
    for me that their privacy lets me see; block either way hides).
       POST /circle/notes {per_recipient, scheme, sender_key_id, visibility}
    -> replaces my note (24 h)."""
    def get(self, request):
        me = request.user
        now = timezone.now()
        peers = _peer_ids(me)
        notes = []
        for n in CircleNote.objects.filter(
                expires_at__gt=now, author_id__in=peers).select_related(
                "author").order_by("-created_at"):
            if str(me.id) not in (n.per_recipient or {}):
                continue
            if not P3.privacy_allows(n.visibility, me.id):
                continue
            if _blocked_either(n.author, me):
                continue
            o = _note_out(n, me)
            o["name"] = n.author.name or ""
            notes.append(o)
        mine = CircleNote.objects.filter(author=me, expires_at__gt=now).first()
        mo = None
        if mine is not None:
            mo = _note_out(mine, me)
            mo["visibility"] = mine.visibility or {}
        return Response({"mine": mo, "notes": notes})

    def post(self, request):
        d = request.data or {}
        try:
            per = P3.validate_per_recipient(d.get("per_recipient"))
        except P3.P3Error as e:
            return _err(e.code)
        if any(len(v["ciphertext"]) > NOTE_CT_MAX for v in per.values()):
            return _err("note_too_long")
        peers = _peer_ids(request.user)
        per = {k: v for k, v in per.items()
               if int(k) in peers or int(k) == request.user.id}
        vis = P3.normalize_privacy(
            d.get("visibility") or _defaults(request.user)["note"])
        CircleNote.objects.filter(author=request.user).delete()
        n = CircleNote.objects.create(
            author=request.user, per_recipient=per,
            scheme=str(d.get("scheme", ""))[:64],
            sender_key_id=str(d.get("sender_key_id", ""))[:64],
            visibility=vis, expires_at=timezone.now() + NOTE_TTL)
        return Response({"ok": True, "id": n.id,
                         "expires_at": n.expires_at.isoformat()},
                        status=status.HTTP_201_CREATED)


class CircleNoteClearView(APIView):
    """POST /circle/notes/clear -> delete my note now."""
    def post(self, request):
        n, _ = CircleNote.objects.filter(author=request.user).delete()
        return Response({"ok": True, "deleted": n})


# ===========================================================================
# Retention (hourly purge_l1_retention)
# ===========================================================================
def purge_expired(now=None, dry=False):
    """Delete expired stories (+ their views) and notes. A photo story's blob
    is released when nothing else references it. Returns counts."""
    now = now or timezone.now()
    st = CircleStatus.objects.filter(expires_at__lte=now)
    notes = CircleNote.objects.filter(expires_at__lte=now)
    out = {"stories": st.count(), "notes": notes.count()}
    if dry:
        return out
    refs = [r for r in st.exclude(blob_ref="").values_list("blob_ref", flat=True)]
    st.delete()
    notes.delete()
    for ref in refs:
        if not CircleStatus.objects.filter(blob_ref=ref).exists():
            circle_blobs.release(ref)
    return out


def active_story_viewer(user, ref):
    """circle_blobs.can_access hook: may `user` download the blob of an ACTIVE
    story? (author, or a viewer the story is visible to)."""
    now = timezone.now()
    qs = CircleStatus.objects.filter(blob_ref=ref, expires_at__gt=now)
    if not qs.exists():
        return False
    peers = None
    for st in qs.select_related("author"):
        if st.author_id == user.id:
            return True
        if peers is None:
            peers = _peer_ids(user)
        if _story_visible(st, user, peers):
            return True
    return False

