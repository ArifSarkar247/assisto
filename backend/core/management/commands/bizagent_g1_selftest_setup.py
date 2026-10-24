"""g1-bizagent — prepare / inspect the LIVE-PROOF self-test of the advanced
Business AI Agent (tools/g1_selftest.py) WITHOUT any owner / Meta / vision /
courier key.

Creates (or refreshes) one dedicated TEST business owned by a non-login test
user: a small catalog WITH product photos (drawn here with Pillow), delivery
charges, one approved FAQ, a bundle rule, auto courier = steadfast (on a
TEST-MODE channel this is a clearly labelled MOCK booking, never a real
parcel), resume-after-human = 1 minute (short, for the proof), and ONE
test-mode Messenger channel that verifies webhooks with ITS OWN secret and
never sends anything to Graph.

    python manage.py bizagent_g1_selftest_setup --secret <random>
    python manage.py bizagent_g1_selftest_setup --asset screenshot|payment   # data: URL
    python manage.py bizagent_g1_selftest_setup --mode human|ai --psid <id>  # per-chat toggle
    python manage.py bizagent_g1_selftest_setup --sweep    # resume / follow-ups / morning
    python manage.py bizagent_g1_selftest_setup --report   # rows as JSON
    python manage.py bizagent_g1_selftest_setup --teardown
"""
import base64
import io
import json
import secrets

from django.core.management.base import BaseCommand
from django.utils import timezone

TEST_EMAIL = "bizagent-g1-selftest@example.invalid"     # never a real person
PAGE_ID = "990000000000011"


def _png(color, shape="circle", size=400, white_bars=False, text=""):
    from PIL import Image, ImageDraw
    im = Image.new("RGB", (size, size), color)
    d = ImageDraw.Draw(im)
    if shape == "circle":
        d.ellipse((size // 4, size // 4, 3 * size // 4, 3 * size // 4), fill=(20, 40, 200))
    elif shape == "stripes":
        for x in range(0, size, size // 10):
            d.rectangle((x, 0, x + size // 20, size), fill=(250, 250, 30))
    if text:
        d.text((20, 20), text, fill=(0, 0, 0))
    if white_bars:                      # what a phone screenshot of the post looks like
        sc = Image.new("RGB", (360, 640), (255, 255, 255))
        sc.paste(im.resize((360, 360)), (0, 140))
        im = sc
    b = io.BytesIO()
    im.save(b, "PNG")
    return b.getvalue()


class Command(BaseCommand):
    help = "Create/refresh/inspect the G1 Business AI Agent self-test business."

    def add_arguments(self, parser):
        parser.add_argument("--secret", default="")
        parser.add_argument("--teardown", action="store_true")
        parser.add_argument("--report", action="store_true")
        parser.add_argument("--sweep", action="store_true")
        parser.add_argument("--asset", default="")
        parser.add_argument("--mode", default="")
        parser.add_argument("--psid", default="")

    def handle(self, *args, **opts):
        from core import bizagent_g1_service as G1S
        from core import bizagent_service as S
        from core.models import (BizFaq, BusinessProfile, ChatThread, Order, OwnerPolicy,
                                 Product, SellerChannel, User)
        user = User.objects.filter(email=TEST_EMAIL).first()
        if opts["asset"]:
            raw = (_png((200, 30, 30), white_bars=True) if opts["asset"] == "screenshot"
                   else _png((226, 19, 110), "none", size=300, text="bKash  Send Money  TrxID"))
            self.stdout.write("data:image/png;base64," + base64.b64encode(raw).decode())
            return
        if opts["sweep"]:
            self.stdout.write(json.dumps(G1S.run_sweeps()))
            return
        if opts["mode"]:
            t = ChatThread.objects.filter(user=user, external_user_id=opts["psid"]).first()
            if t is None or opts["mode"] not in ("human", "ai"):
                self.stderr.write("no such test chat / mode")
                return
            G1S.set_reply_mode(t, opts["mode"])
            self.stdout.write("reply_mode=%s" % opts["mode"])
            return
        if opts["report"]:
            out = {"threads": [], "orders": [], "agent": {}}
            if user:
                for t in ChatThread.objects.filter(user=user).order_by("id"):
                    out["threads"].append({
                        "id": t.id, "psid": t.external_user_id,
                        "paused_until": t.ai_paused_until.isoformat() if t.ai_paused_until else None,
                        "human_mode": t.owner_takeover,
                        "messages": [{"id": m.id, "dir": m.direction, "status": m.status,
                                      "is_ai": m.is_ai, "kind": m.kind, "source": m.reply_source,
                                      "rule": (m.meta or {}).get("rule", ""),
                                      "credits": m.credits, "risk": m.risk_reason,
                                      "text": m.text[:300]}
                                     for m in t.messages.order_by("id")]})
                for o in Order.objects.filter(user=user).order_by("id"):
                    out["orders"].append({"id": o.id, "status": o.status, "total": str(o.total),
                                          "via_agent": o.via_agent, "payment": o.payment,
                                          "payment_status": o.payment_status,
                                          "courier": o.courier, "tracking": o.tracking,
                                          "courier_live": o.courier_live, "items": o.items})
                biz = BusinessProfile.objects.filter(user=user).first()
                if biz:
                    a = S.agent_for(biz)
                    out["agent"] = {"replies_used": a.replies_used,
                                    "credits": int(user.ai_credits or 0),
                                    "stock": {p.name: p.stock for p in Product.objects.filter(user=user)}}
            self.stdout.write(json.dumps(out, ensure_ascii=False, indent=1))
            return
        if opts["teardown"]:
            SellerChannel.objects.filter(test_mode=True, external_id=PAGE_ID).delete()
            if user:
                user.delete()
            self.stdout.write("g1 selftest business removed")
            return

        from django.core.files.base import ContentFile
        secret = opts["secret"] or secrets.token_urlsafe(24)
        if user is None:
            user = User.objects.create_user(email=TEST_EMAIL, name="G1 Selftest Shop",
                                            password=secrets.token_urlsafe(32))
            user.is_active = False      # cannot sign in
            user.save(update_fields=["is_active"])
        biz = BusinessProfile.objects.filter(user=user).first() or \
            BusinessProfile.objects.create(user=user, shop_name="G1 Selftest Shop")
        for name, price, mn, stock, cat, img in (
                ("Selftest Panjabi", 1200, 1000, 50, "men", _png((200, 30, 30))),
                ("Selftest Pajama", 500, 450, 20, "men", _png((30, 160, 60), "stripes")),
                ("Selftest Saree", 2500, 2200, 0, "women", None)):
            p, _ = Product.objects.update_or_create(user=user, name=name, defaults={
                "business": biz, "price": price, "min_price": mn, "stock": stock,
                "category": cat, "cost_price": int(price * 0.6)})
            if img and not p.photo:
                p.photo.save("g1selftest_%s.png" % p.id, ContentFile(img), save=True)
        pol = biz.policies.first() or OwnerPolicy(user=user, business=biz)
        pol.delivery_inside, pol.delivery_outside = 60, 120
        pol.returns = "Selftest: exchange within 3 days"
        pol.save()
        BizFaq.objects.get_or_create(business=biz, question="dokan kothay | দোকান কোথায়",
                                     defaults={"answer": "Selftest shop: Mirpur 10, Dhaka.",
                                               "status": "approved"})
        ch, _ = SellerChannel.objects.get_or_create(kind="messenger", external_id=PAGE_ID,
                                                    defaults={"business": biz})
        if ch.business_id != biz.pk:
            raise SystemExit("the g1 test page id belongs to another business")
        ch.test_mode, ch.status, ch.display_name = True, "connected", "G1 SELFTEST"
        ch.test_secret_enc = S.enc({"secret": secret})
        ch.connected_at = timezone.now()
        ch.save()
        a = S.agent_for(biz)
        a.ai_enabled, a.rules_enabled, a.ai_mode = True, True, "always"
        a.resume_minutes = 1                         # short pause for the proof
        a.auto_courier, a.default_courier = True, "steadfast"
        a.bundle_rules = [{"min_qty": 2, "off_pct": 5}]
        a.upsell_enabled, a.followups_enabled, a.vision_enabled = True, False, True
        a.quiet_hours = {}
        # a paid-plan state so the free trial's Profit Guard cannot make the
        # proof flaky; no money is involved (test business, no gateway)
        a.plan, a.period_start = "starter", timezone.now()
        a.period_end = timezone.now() + timezone.timedelta(days=7)
        a.replies_used = 0
        a.save()
        self.stdout.write("G1_SELFTEST_SECRET=%s" % secret)
        self.stdout.write("G1_SELFTEST_PAGE_ID=%s" % PAGE_ID)
        self.stdout.write("G1_SELFTEST_BUSINESS_ID=%s" % biz.id)
