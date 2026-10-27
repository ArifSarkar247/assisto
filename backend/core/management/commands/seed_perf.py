"""seed_perf — bulk data for the 2 GB performance run (.github/workflows/perf2gb.yml).

    python manage.py seed_perf --settings=assisto_backend.settings_ci [--out f.json]

Runs AFTER seed_reality (same demo user A = 01700000001) and adds the volumes
a busy real user has, so list screens are measured with real-sized data:
500 reminders, 300 money transactions, 500 till customers, 500 khata
(ledger) customers with one entry each, a CRM org with 500 leads, a connected
seller page with 150 AI-sales chats (3 messages each), and A allow-listed on
the default-off launch flags measured here (budget_remittance, home_watchman)
so they open instead of the "not available" page. The 200 My Circle messages are sent by the test itself (they must be
REALLY encrypted to A's key).

Same refusal rule as seed_reality: only the CI sqlite file or the CI
throw-away Postgres inside GitHub Actions — never a real database.
Idempotent: rows are tagged "[perf]" and re-created on every run.
"""
import json
import os
from datetime import date, timedelta
from pathlib import Path

from django.conf import settings
from django.core.management.base import BaseCommand, CommandError
from django.utils import timezone

TAG = "[perf]"
N_REMINDERS = 500
N_TXNS = 300
N_CUSTOMERS = 500
N_KHATA = 500
N_LEADS = 500
N_THREADS = 150
PERF_FLAGS = ("budget_remittance", "home_watchman")

FIRST = ["Rahim", "Karim", "Salma", "Nasrin", "Jamal", "Rupa", "Tanvir", "Mitu",
         "Arif", "Shila", "Habib", "Lima", "Sohel", "Nipa", "Babul", "Ruma"]
LAST = ["Hossain", "Ahmed", "Akter", "Islam", "Khan", "Begum", "Uddin", "Sarkar"]


def _name(i):
    return f"{FIRST[i % len(FIRST)]} {LAST[(i // len(FIRST)) % len(LAST)]} {i + 1}"


def _phone(i, base=1800000000):
    return f"0{base + i}"


def assert_ci_db():
    """Raise unless the active DB is the CI throw-away one (see module doc)."""
    db = settings.DATABASES["default"]
    engine = db["ENGINE"]
    ci_pg = (
        "postgresql" in engine
        and os.environ.get("GITHUB_ACTIONS") == "true"
        and os.environ.get("ASSISTO_CI_PG_NAME")
        and db.get("NAME") == os.environ["ASSISTO_CI_PG_NAME"]
        and db.get("HOST") in ("127.0.0.1", "localhost")
    )
    if "sqlite" not in engine and not ci_pg:
        raise CommandError("seed_perf only runs against the CI database "
                           f"(got {engine}); refusing to touch a real database.")


class Command(BaseCommand):
    help = "Bulk perf data for user A on the CI database (sqlite / CI Postgres only)."

    def add_arguments(self, parser):
        parser.add_argument("--out", default=str(Path(settings.BASE_DIR) / "ci_perf_seed.json"))
        parser.add_argument("--phone", default="01700000001")

    def handle(self, *args, **opts):
        assert_ci_db()
        from core.models import (Account, BusinessProfile, ChatThread, Customer,
                                 FeatureFlag, KhataEntry, KhataParty, Message,
                                 Reminder, SellerChannel, Transaction)
        from core.phone import find_user
        from core import feature_flags as FF

        user = find_user(opts["phone"])
        if user is None:
            raise CommandError("user A not found — run seed_reality first")
        now = timezone.now()
        out = {"user_id": user.id}

        # ---------------------------------------------------- feature flags
        FF.ensure_seeded()
        n = 0
        # only the launch features that are OFF by default and measured here
        # (allow-listing every flag changed the sign-in path on run 40540444789)
        for ff in FeatureFlag.objects.filter(key__in=PERF_FLAGS):
            ids = [i for i in (ff.allow_user_ids or []) if i != user.id] + [user.id]
            ff.allow_user_ids = ids
            ff.save(update_fields=["allow_user_ids", "updated_at"])
            n += 1
        FF.invalidate()
        out["flags_allow_listed"] = n

        # ---------------------------------------------------- reminders
        Reminder.objects.filter(user=user, title__startswith=TAG).delete()
        Reminder.objects.bulk_create([
            Reminder(user=user, title=f"{TAG} Reminder {i + 1}: pay bill / call {_name(i)}",
                     notes="perf seed", due_at=now + timedelta(hours=3 * i + 1),
                     recurrence=("none", "daily", "weekly", "monthly")[i % 4])
            for i in range(N_REMINDERS)])
        out["reminders"] = Reminder.objects.filter(user=user).count()

        # ---------------------------------------------------- money
        acc = Account.objects.filter(user=user).first() or Account.objects.create(
            user=user, name="Cash wallet", acc_type="cash", opening_balance=5000)
        Transaction.objects.filter(user=user, note__startswith=TAG).delete()
        cats = ["food", "transport", "bills", "shopping", "health", "education"]
        Transaction.objects.bulk_create([
            Transaction(user=user, account=acc, kind="expense" if i % 7 else "income",
                        amount=50 + (i * 37) % 900, category=cats[i % len(cats)],
                        note=f"{TAG} {i + 1}", date=date.today() - timedelta(days=i % 90))
            for i in range(N_TXNS)])
        out["transactions"] = Transaction.objects.filter(user=user).count()

        # ---------------------------------------------------- business
        biz = BusinessProfile.objects.filter(user=user).first()
        if biz is None:
            biz = BusinessProfile.objects.create(user=user, shop_name="Rahim Store")
        Customer.objects.filter(user=user, notes=TAG).delete()
        Customer.objects.bulk_create([
            Customer(user=user, business=biz, name=_name(i), phone=_phone(i),
                     phone_key=f"88{_phone(i)}", area=("Mirpur", "Uttara", "Dhanmondi")[i % 3],
                     notes=TAG, vip=(i % 25 == 0))
            for i in range(N_CUSTOMERS)], ignore_conflicts=True)
        out["customers"] = Customer.objects.filter(user=user).count()

        KhataParty.objects.filter(business=biz, note=TAG).delete()
        KhataParty.objects.bulk_create([
            KhataParty(business=biz, book="customer", name=_name(i),
                       phone=_phone(i, 1900000000), area="Mirpur", note=TAG)
            for i in range(N_KHATA)])
        parties = list(KhataParty.objects.filter(business=biz, note=TAG).order_by("id"))
        KhataEntry.objects.bulk_create([
            KhataEntry(party=p, direction="gave" if i % 3 else "got",
                       amount_poisha=(100 + (i * 53) % 5000) * 100, note=f"{TAG} bill",
                       at=now - timedelta(days=i % 60))
            for i, p in enumerate(parties)])
        out["khata_parties"] = len(parties)

        # ---------------------------------------------------- CRM
        try:
            from crm.models import CrmMember, CrmOrg, Lead
            org = CrmOrg.objects.filter(owner=user, name="Perf Sales Org").first()
            if org is None:
                org = CrmOrg.objects.create(owner=user, name="Perf Sales Org",
                                            industry="retail", team_size="small")
            CrmMember.objects.get_or_create(org=org, user=user, defaults={"role": "owner"})
            Lead.objects.filter(org=org).delete()
            sts = ["new", "contacted", "demo", "proposal", "won", "lost"]
            Lead.objects.bulk_create([
                Lead(org=org, name=_name(i), company=f"Company {i + 1} Ltd",
                     industry=("rmg", "pharma", "retail", "other")[i % 4],
                     phone=_phone(i, 1700500000), status=sts[i % len(sts)],
                     score=(i * 7) % 100, priority="high" if i % 9 == 0 else "normal",
                     notes=TAG)
                for i in range(N_LEADS)])
            out["crm_org_id"] = org.id
            out["crm_leads"] = Lead.objects.filter(org=org).count()
        except Exception as e:  # CRM app missing in some branch = recorded, not fatal
            out["crm_error"] = repr(e)[:200]

        # ---------------------------------------------------- AI sales inbox
        ch, _ = SellerChannel.objects.get_or_create(
            kind="messenger", external_id="perf-page-1",
            defaults={"business": biz, "display_name": "Rahim Store (perf)",
                      "status": "connected", "test_mode": True, "connected_at": now})
        ChatThread.objects.filter(business=biz, external_user_id__startswith="perf-").delete()
        ChatThread.objects.bulk_create([
            ChatThread(user=user, business=biz, seller_channel=ch, channel="messenger",
                       external_user_id=f"perf-{i}", customer_name=_name(i),
                       customer_phone=_phone(i, 1600000000), lang="bn",
                       last_inbound_at=now - timedelta(minutes=7 * i),
                       last_message_at=now - timedelta(minutes=7 * i))
            for i in range(N_THREADS)])
        threads = list(ChatThread.objects.filter(business=biz, external_user_id__startswith="perf-"))
        msgs = []
        for t in threads:
            msgs += [Message(thread=t, direction="in", text="দাম কত? Price please", status="received"),
                     Message(thread=t, direction="out", text="৳450, delivery 2 days", is_ai=True,
                             status="sent", reply_source="rule"),
                     Message(thread=t, direction="in", text="ঠিক আছে, অর্ডার করবো", status="received")]
        Message.objects.bulk_create(msgs)
        out["sales_threads"] = len(threads)

        Path(opts["out"]).write_text(json.dumps(out, indent=2))
        self.stdout.write("seed_perf: " + json.dumps(out))
