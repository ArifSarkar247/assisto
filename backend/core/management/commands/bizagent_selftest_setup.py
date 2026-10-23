"""p1-bizagent — prepare the LIVE-PROOF self-test (tools/p1_webhook_selftest.py)
WITHOUT any owner/Meta key.

Creates (or refreshes) one dedicated TEST business owned by a non-login test
user, with a tiny catalog, delivery charges, AI on, a trial plan, and two
TEST-MODE channels (a fake Page id + a fake WhatsApp phone_number_id). Those
channels verify webhooks with THEIR OWN secret (never the Meta app secret)
and never send anything to Graph. Prints the values the script needs.

    python manage.py bizagent_selftest_setup --secret <random-string>
    python manage.py bizagent_selftest_setup --report     # rows after the run
    python manage.py bizagent_selftest_setup --teardown
"""
import secrets

from django.core.management.base import BaseCommand
from django.utils import timezone

TEST_EMAIL = "bizagent-selftest@example.invalid"   # never a real person
PAGE_ID = "990000000000001"
WA_PNID = "990000000000002"


class Command(BaseCommand):
    help = "Create/refresh the Business AI Agent self-test business (test-mode channels)."

    def add_arguments(self, parser):
        parser.add_argument("--secret", default="")
        parser.add_argument("--teardown", action="store_true")
        parser.add_argument("--report", action="store_true",
                            help="print the self-test business's threads/messages/orders as JSON")

    def handle(self, *args, **opts):
        from core import bizagent_service as S
        from core.models import (BusinessProfile, OwnerPolicy, Product, SellerChannel, User)
        user = User.objects.filter(email=TEST_EMAIL).first()
        if opts["report"]:
            import json
            from core.models import ChatThread, Order
            out = {"threads": [], "orders": []}
            for t in ChatThread.objects.filter(user=user) if user else []:
                out["threads"].append({
                    "id": t.id, "channel": t.channel,
                    "messages": [{"dir": m.direction, "status": m.status, "is_ai": m.is_ai,
                                  "kind": m.kind, "risk": m.risk_reason, "text": m.text[:200]}
                                 for m in t.messages.order_by("id")]})
            for o in Order.objects.filter(user=user) if user else []:
                out["orders"].append({"id": o.id, "status": o.status, "total": str(o.total),
                                      "channel": o.channel, "items": o.items})
            self.stdout.write(json.dumps(out, ensure_ascii=False, indent=1))
            return
        if opts["teardown"]:
            SellerChannel.objects.filter(test_mode=True, external_id__in=(PAGE_ID, WA_PNID)).delete()
            if user:
                user.delete()
            self.stdout.write("selftest business removed")
            return
        secret = opts["secret"] or secrets.token_urlsafe(24)
        if user is None:
            user = User.objects.create_user(email=TEST_EMAIL, name="Selftest Shop",
                                            password=secrets.token_urlsafe(32))
            user.is_active = False      # cannot sign in
            user.save(update_fields=["is_active"])
        biz = BusinessProfile.objects.filter(user=user).first() or \
            BusinessProfile.objects.create(user=user, shop_name="Selftest Shop")
        if not Product.objects.filter(user=user, name="Selftest Panjabi").exists():
            Product.objects.create(user=user, business=biz, name="Selftest Panjabi",
                                   price=1200, min_price=1000, stock=50)
        pol = biz.policies.first() or OwnerPolicy(user=user, business=biz)
        pol.delivery_inside, pol.delivery_outside = 60, 120
        pol.save()
        S.selftest_setup(biz, secret, PAGE_ID, WA_PNID)
        a = S.agent_for(biz)
        a.ai_enabled = True
        a.plan, a.period_start = "trial", timezone.now()
        a.period_end = timezone.now() + timezone.timedelta(days=7)
        a.replies_used = 0
        a.save()
        self.stdout.write("SELFTEST_SECRET=%s" % secret)
        self.stdout.write("SELFTEST_PAGE_ID=%s" % PAGE_ID)
        self.stdout.write("SELFTEST_WA_PNID=%s" % WA_PNID)
        self.stdout.write("SELFTEST_BUSINESS_ID=%s" % biz.id)
