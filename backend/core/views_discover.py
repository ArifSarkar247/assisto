"""
views_discover.py — HOME "Discover" cards: app feed, tracking, owner admin
(slot d1-discover). Rules + content safety are pure logic in
core/logic/discover.py; this file only resolves rows and enforces auth.

App:
  GET  /discover/cards?build=N      -> the signed-in user's filtered cards
  POST /discover/track              -> {card_id, event: impression|click}
                                       (or {events:[...]}); deduped per user
                                       per card per local day
Owner admin (superuser — the same gate as /admin/pnl, /admin/pricing):
  GET/POST          /admin/discover/cards
  GET/PATCH/DELETE  /admin/discover/cards/<pk>
  POST/DELETE       /admin/discover/cards/<pk>/image      (multipart "image")
  POST              /admin/discover/reorder               {ids:[...]}
  GET               /admin/discover/meta                  route/icon pickers
  GET               /admin/discover/preview?segment=&build=
  GET               /admin/discover/cards/<pk>/report?days=30
  GET               /admin/discover/cards/<pk>/report.csv|report.pdf
"""
import csv
import io
import secrets
from datetime import timedelta

from django.db import IntegrityError, transaction
from django.db.models import F, Sum
from django.http import HttpResponse
from django.utils import timezone
from django.utils.dateparse import parse_datetime
from django.utils.text import slugify
from rest_framework import status
from rest_framework.parsers import FormParser, MultiPartParser
from rest_framework.response import Response
from rest_framework.views import APIView

from .logic import discover as D

MAX_IMAGE_BYTES = 2 * 1024 * 1024
EDITABLE = ("type", "title_bn", "title_en", "desc_bn", "desc_en", "icon",
            "route", "url", "order", "enabled", "start_at", "end_at",
            "audience", "min_build", "sponsor_name", "sponsor_revenue")


# ------------------------------------------------------------------ helpers
def _segment(user):
    from . import billing
    try:
        return billing._segment_of(user)
    except Exception:
        return "free"


def _build_param(v):
    try:
        b = int(str(v).strip())
        return b if b >= 0 else None
    except (TypeError, ValueError):
        return None


def _rule_row(c):
    return {"id": c.id, "type": c.type, "enabled": c.enabled,
            "start_at": c.start_at, "end_at": c.end_at,
            "audience": c.audience, "min_build": c.min_build,
            "order": c.order, "obj": c}


def _image_url(c):
    try:
        return c.image.url if c.image else ""
    except Exception:
        return ""


def app_payload(c):
    """What the app renders for one card. Labels come from the type only."""
    if c.type == D.ADMOB:
        return {"id": c.id, "key": c.key, "type": c.type, "label": "ad"}
    return {
        "id": c.id, "key": c.key, "type": c.type, "label": D.label_for(c.type),
        "title": {"bn": c.title_bn, "en": c.title_en},
        "description": {"bn": c.desc_bn, "en": c.desc_en},
        "icon": c.icon, "image_url": _image_url(c),
        "route": c.route, "url": c.url,
    }


def cards_for(segment, build, now=None):
    from .models import DiscoverCard
    now = now or timezone.now()
    rows = [_rule_row(c) for c in DiscoverCard.objects.all()]
    return [r["obj"] for r in D.visible_cards(rows, segment, build, now)]


def _admin_payload(c, totals=None):
    p = {k: getattr(c, k) for k in EDITABLE}
    p["sponsor_revenue"] = float(c.sponsor_revenue or 0)
    p["start_at"] = c.start_at.isoformat() if c.start_at else None
    p["end_at"] = c.end_at.isoformat() if c.end_at else None
    p.update({"id": c.id, "key": c.key, "label": D.label_for(c.type),
              "image_url": _image_url(c),
              "created_at": c.created_at.isoformat() if c.created_at else None})
    now = timezone.now()
    p["live"] = bool(c.enabled and (c.start_at is None or c.start_at <= now)
                     and (c.end_at is None or now < c.end_at))
    t = totals or {}
    imp, clk = int(t.get("impressions") or 0), int(t.get("clicks") or 0)
    p["stats"] = {"impressions": imp, "clicks": clk, "ctr": D.ctr(imp, clk)}
    return p


def _totals_by_card():
    from .models import DiscoverDailyStat
    out = {}
    for r in DiscoverDailyStat.objects.values("card_id").annotate(
            impressions=Sum("impressions"), clicks=Sum("clicks")):
        out[r["card_id"]] = r
    return out


def _audit(user, action, detail):
    try:
        from .models import AuditLog
        AuditLog.objects.create(user=user, action=action, detail=detail)
    except Exception:
        pass


def _parse_dt(v):
    if v in (None, ""):
        return None, True
    if hasattr(v, "tzinfo"):
        dt = v
    else:
        dt = parse_datetime(str(v))
        if dt is None:
            return None, False
    if timezone.is_naive(dt):
        dt = timezone.make_aware(dt, timezone.get_current_timezone())
    return dt, True


class _OwnerOnly(APIView):
    """Superuser gate — identical to AdminPnlView / PricingConfigView."""
    def initial(self, request, *args, **kwargs):
        super().initial(request, *args, **kwargs)
        u = request.user
        if not (u and u.is_authenticated and u.is_superuser):
            from rest_framework.exceptions import PermissionDenied
            raise PermissionDenied("owner only")


def _apply(card, data):
    """Merge `data` into `card` (unsaved), validate + safety-check.
    Returns (errors_dict, safety_list)."""
    errors = {}
    fields = {k: getattr(card, k) for k in EDITABLE}
    for k in EDITABLE:
        if k not in data:
            continue
        v = data.get(k)
        if k in ("start_at", "end_at"):
            dt, ok = _parse_dt(v)
            if not ok:
                errors[k] = "invalid"
                continue
            fields[k] = dt
        elif k == "enabled":
            fields[k] = v in (True, "true", "1", 1, "on")
        elif k == "order":
            try:
                fields[k] = int(v)
            except (TypeError, ValueError):
                errors[k] = "invalid"
        elif k == "min_build":
            fields[k] = None if v in (None, "") else v
        elif k == "sponsor_revenue":
            fields[k] = 0 if v in (None, "") else v
        else:
            fields[k] = ("" if v is None else str(v)).strip()
    errors.update(D.validate(fields))
    safety = D.safety_issues(fields)
    if errors or safety:
        return errors, safety
    for k, v in fields.items():
        if k == "min_build":
            v = None if v in (None, "") else int(v)
        if k == "sponsor_revenue":
            v = round(float(v or 0), 2)
        setattr(card, k, v)
    # Non-sponsored cards carry no sponsor money (keeps the P&L honest).
    if card.type != D.SPONSORED:
        card.sponsor_name = ""
        card.sponsor_revenue = 0
    if card.type == D.ADMOB:
        card.route, card.url = "", ""
    return {}, []


def _bad(errors, safety):
    """400 body. The unsafe-content list goes FIRST when present, because the
    app's ApiException surfaces the first body value as its message."""
    body = {"safety": safety, "errors": errors} if safety else \
        {"errors": errors, "safety": []}
    return Response(body, status=status.HTTP_400_BAD_REQUEST)


def _new_key(card):
    base = slugify(card.title_en or card.type.lower())[:40] or "card"
    return "%s-%s" % (base, secrets.token_hex(3))


# ------------------------------------------------------------------ app API
class DiscoverCardsView(APIView):
    """GET /discover/cards?build=N — the cards THIS user may see, already
    filtered server-side (plan, audience, window, build, sponsor/AdMob)."""
    def get(self, request):
        seg = _segment(request.user)
        build = _build_param(request.query_params.get("build"))
        cards = cards_for(seg, build)
        return Response({"cards": [app_payload(c) for c in cards],
                         "segment": seg})


def _trackable(card, user):
    """A tap/impression counts only for a card this user may currently see
    (min_build aside — the client already passed that gate)."""
    row = _rule_row(card)
    row["min_build"] = None
    return bool(D.visible_cards([row], _segment(user), None, timezone.now()))


def record_event(card, user, event, day=None):
    """Count one impression/click, deduped per user per card per day.
    Returns True when it was counted."""
    from .models import DiscoverDailyStat, DiscoverSeen
    kind = "imp" if event == "impression" else "click"
    day = day or timezone.localdate()
    try:
        with transaction.atomic():
            _, created = DiscoverSeen.objects.get_or_create(
                card=card, user=user, date=day, kind=kind)
            if not created:
                return False
            stat, _ = DiscoverDailyStat.objects.get_or_create(card=card, date=day)
            col = "impressions" if kind == "imp" else "clicks"
            DiscoverDailyStat.objects.filter(pk=stat.pk).update(
                **{col: F(col) + 1})
            return True
    except IntegrityError:
        return False


class DiscoverTrackView(APIView):
    """POST /discover/track {card_id, event} | {events:[{card_id, event}]}.
    Fire-and-forget from the app; always 200 with what was counted."""
    def post(self, request):
        from .models import DiscoverCard
        d = request.data or {}
        evs = d.get("events") if isinstance(d.get("events"), list) else [d]
        counted = 0
        for e in evs[:20]:
            if not isinstance(e, dict):
                continue
            ev = e.get("event")
            if ev not in ("impression", "click"):
                continue
            try:
                card = DiscoverCard.objects.get(pk=int(e.get("card_id")))
            except (DiscoverCard.DoesNotExist, TypeError, ValueError):
                continue
            if not _trackable(card, request.user):
                continue
            if record_event(card, request.user, ev):
                counted += 1
        return Response({"ok": True, "counted": counted})


# ---------------------------------------------------------------- owner admin
class AdminDiscoverCardsView(_OwnerOnly):
    def get(self, request):
        from .models import DiscoverCard
        tot = _totals_by_card()
        return Response({"cards": [_admin_payload(c, tot.get(c.id))
                                   for c in DiscoverCard.objects.all()],
                         "can_manage": True})

    def post(self, request):
        from .models import DiscoverCard
        data = request.data or {}
        last = DiscoverCard.objects.order_by("-order").first()
        card = DiscoverCard(type=str(data.get("type") or ""),
                            order=(last.order + 10) if last else 10)
        errors, safety = _apply(card, data)
        if errors or safety:
            return _bad(errors, safety)
        card.key = _new_key(card)
        card.save()
        _audit(request.user, "discover.create", {"id": card.id, "type": card.type})
        return Response(_admin_payload(card), status=status.HTTP_201_CREATED)


class AdminDiscoverCardView(_OwnerOnly):
    def _get(self, pk):
        from .models import DiscoverCard
        return DiscoverCard.objects.filter(pk=pk).first()

    def get(self, request, pk):
        c = self._get(pk)
        if not c:
            return Response({"detail": "not found"}, status=404)
        return Response(_admin_payload(c, _totals_by_card().get(c.id)))

    def patch(self, request, pk):
        c = self._get(pk)
        if not c:
            return Response({"detail": "not found"}, status=404)
        errors, safety = _apply(c, request.data or {})
        if errors or safety:
            return _bad(errors, safety)
        c.save()
        _audit(request.user, "discover.update", {"id": c.id})
        return Response(_admin_payload(c, _totals_by_card().get(c.id)))

    def delete(self, request, pk):
        c = self._get(pk)
        if not c:
            return Response({"detail": "not found"}, status=404)
        if c.image:
            try:
                c.image.delete(save=False)
            except Exception:
                pass
        c.delete()
        _audit(request.user, "discover.delete", {"id": pk})
        return Response({"ok": True})


class AdminDiscoverImageView(_OwnerOnly):
    parser_classes = [MultiPartParser, FormParser]

    def post(self, request, pk):
        from .models import DiscoverCard
        c = DiscoverCard.objects.filter(pk=pk).first()
        if not c:
            return Response({"detail": "not found"}, status=404)
        f = request.FILES.get("image")
        if not f:
            return Response({"errors": {"image": "required"}}, status=400)
        if f.size > MAX_IMAGE_BYTES:
            return Response({"errors": {"image": "too_large"}}, status=400)
        try:
            from PIL import Image
            img = Image.open(f)
            img.verify()
            if (img.format or "").upper() not in ("PNG", "JPEG", "WEBP"):
                raise ValueError("format")
            f.seek(0)
        except Exception:
            return Response({"errors": {"image": "not_an_image"}}, status=400)
        if c.image:
            try:
                c.image.delete(save=False)
            except Exception:
                pass
        c.image.save(f.name or "card.png", f, save=True)
        _audit(request.user, "discover.image", {"id": c.id})
        return Response(_admin_payload(c))

    def delete(self, request, pk):
        from .models import DiscoverCard
        c = DiscoverCard.objects.filter(pk=pk).first()
        if not c:
            return Response({"detail": "not found"}, status=404)
        if c.image:
            c.image.delete(save=True)
        return Response(_admin_payload(c))


class AdminDiscoverReorderView(_OwnerOnly):
    def post(self, request):
        from .models import DiscoverCard
        ids = (request.data or {}).get("ids")
        if not isinstance(ids, list) or not ids:
            return Response({"errors": {"ids": "required"}}, status=400)
        try:
            ids = [int(i) for i in ids]
        except (TypeError, ValueError):
            return Response({"errors": {"ids": "invalid"}}, status=400)
        with transaction.atomic():
            for n, pk in enumerate(ids):
                DiscoverCard.objects.filter(pk=pk).update(order=(n + 1) * 10)
        _audit(request.user, "discover.reorder", {"ids": ids})
        return Response({"ok": True})


class AdminDiscoverMetaView(_OwnerOnly):
    def get(self, request):
        return Response({"routes": list(D.ROUTE_KEYS), "icons": list(D.ICONS),
                         "types": list(D.TYPES), "audiences": list(D.AUDIENCES),
                         "max_image_bytes": MAX_IMAGE_BYTES})


class AdminDiscoverPreviewView(_OwnerOnly):
    """What a user of `segment` on `build` would receive right now."""
    def get(self, request):
        seg = request.query_params.get("segment") or "free"
        if seg not in D.SEGMENTS:
            seg = "free"
        build = _build_param(request.query_params.get("build"))
        return Response({"segment": seg, "build": build,
                         "cards": [app_payload(c) for c in cards_for(seg, build)]})


# -------------------------------------------------------------------- report
def card_report(card, days=30, today=None):
    """Per-day impressions / clicks / CTR for one card over the last `days`
    local days (zero-filled — every day in the window is listed)."""
    from .models import DiscoverDailyStat
    today = today or timezone.localdate()
    days = max(1, min(366, int(days or 30)))
    since = today - timedelta(days=days - 1)
    got = {r.date: r for r in DiscoverDailyStat.objects.filter(
        card=card, date__gte=since, date__lte=today)}
    rows, ti, tc = [], 0, 0
    for i in range(days):
        d = since + timedelta(days=i)
        r = got.get(d)
        imp, clk = (r.impressions, r.clicks) if r else (0, 0)
        ti += imp
        tc += clk
        rows.append({"date": d.isoformat(), "impressions": imp, "clicks": clk,
                     "ctr": D.ctr(imp, clk)})
    return {"card": {"id": card.id, "key": card.key, "type": card.type,
                     "title_en": card.title_en, "title_bn": card.title_bn,
                     "sponsor_name": card.sponsor_name,
                     "sponsor_revenue": float(card.sponsor_revenue or 0)},
            "from": since.isoformat(), "to": today.isoformat(), "rows": rows,
            "totals": {"impressions": ti, "clicks": tc, "ctr": D.ctr(ti, tc)}}


def _days_param(request):
    try:
        return int(request.query_params.get("days", 30))
    except (TypeError, ValueError):
        return 30


class AdminDiscoverReportView(_OwnerOnly):
    def get(self, request, pk):
        from .models import DiscoverCard
        c = DiscoverCard.objects.filter(pk=pk).first()
        if not c:
            return Response({"detail": "not found"}, status=404)
        return Response(card_report(c, _days_param(request)))


def report_csv(rep):
    buf = io.StringIO()
    w = csv.writer(buf)
    card = rep["card"]
    w.writerow(["card", card["title_en"] or card["key"]])
    w.writerow(["sponsor", card["sponsor_name"]])
    w.writerow(["period", rep["from"], rep["to"]])
    w.writerow([])
    w.writerow(["date", "impressions", "clicks", "ctr_percent"])
    for r in rep["rows"]:
        w.writerow([r["date"], r["impressions"], r["clicks"], r["ctr"]])
    t = rep["totals"]
    w.writerow(["total", t["impressions"], t["clicks"], t["ctr"]])
    return buf.getvalue()


def report_pdf(rep):
    from reportlab.lib import colors
    from reportlab.lib.pagesizes import A4
    from reportlab.lib.styles import getSampleStyleSheet
    from reportlab.platypus import (Paragraph, SimpleDocTemplate, Spacer,
                                    Table, TableStyle)
    buf = io.BytesIO()
    doc = SimpleDocTemplate(buf, pagesize=A4, title="Assisto sponsor report")
    st = getSampleStyleSheet()
    card, t = rep["card"], rep["totals"]
    story = [
        Paragraph("Assisto — Discover sponsor report", st["Title"]),
        Paragraph("Card: %s" % _esc(card["title_en"] or card["key"]), st["Normal"]),
        Paragraph("Sponsor: %s" % _esc(card["sponsor_name"] or "-"), st["Normal"]),
        Paragraph("Period: %s to %s" % (rep["from"], rep["to"]), st["Normal"]),
        Paragraph("Impressions are unique per user per day; clicks are unique "
                  "per user per day.", st["Italic"]),
        Spacer(1, 10),
    ]
    data = [["Date", "Impressions", "Clicks", "CTR %"]]
    data += [[r["date"], r["impressions"], r["clicks"], "%.2f" % r["ctr"]]
             for r in rep["rows"]]
    data.append(["Total", t["impressions"], t["clicks"], "%.2f" % t["ctr"]])
    tbl = Table(data, repeatRows=1)
    tbl.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#1e40af")),
        ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
        ("GRID", (0, 0), (-1, -1), 0.25, colors.grey),
        ("FONTNAME", (0, -1), (-1, -1), "Helvetica-Bold"),
        ("ALIGN", (1, 0), (-1, -1), "RIGHT"),
    ]))
    story.append(tbl)
    doc.build(story)
    return buf.getvalue()


def _esc(s):
    return (str(s or "").replace("&", "&amp;").replace("<", "&lt;")
            .replace(">", "&gt;"))


class AdminDiscoverReportExportView(_OwnerOnly):
    def get(self, request, pk, fmt):
        from .models import DiscoverCard
        c = DiscoverCard.objects.filter(pk=pk).first()
        if not c or fmt not in ("csv", "pdf"):
            return Response({"detail": "not found"}, status=404)
        rep = card_report(c, _days_param(request))
        name = "discover-%s-%s" % (c.key, rep["to"])
        if fmt == "csv":
            resp = HttpResponse(report_csv(rep), content_type="text/csv; charset=utf-8")
        else:
            resp = HttpResponse(report_pdf(rep), content_type="application/pdf")
        resp["Content-Disposition"] = 'attachment; filename="%s.%s"' % (name, fmt)
        return resp


# ---------------------------------------------------------- P&L revenue line
def sponsored_revenue_by_day(since, until):
    """{local date: ৳} of booked SPONSORED revenue spread over each card's run
    (see logic.discover.revenue_by_day), restricted to [since, until]. Every
    SPONSORED card counts (a disabled card is still a booked deal; deleting the
    card removes it from the P&L)."""
    from .models import DiscoverCard
    out = {}
    for c in DiscoverCard.objects.filter(type=D.SPONSORED, sponsor_revenue__gt=0):
        row = {"type": c.type, "sponsor_revenue": c.sponsor_revenue,
               "start_at": c.start_at, "end_at": c.end_at,
               "created_at": c.created_at}
        for d, amt in D.revenue_by_day(row, timezone.localdate).items():
            if since <= d <= until:
                out[d] = out.get(d, 0.0) + amt
    return out

