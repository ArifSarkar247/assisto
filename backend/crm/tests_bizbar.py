"""bizbar — CRM launch bar: Today rows open their lead (and carry the phone),
due tasks are returned with their lead, and a SALES rep never sees
colleagues' money on the leaderboard / commission preview."""
from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.utils import timezone
from rest_framework.test import APITestCase

from . import pipeline as pl
from .models import Activity, CrmMember, CrmOrg, Deal, Lead

User = get_user_model()


class CrmBizbarTests(APITestCase):
    def setUp(self):
        self.owner = User.objects.create_user(phone="01700000811", password="x12345")
        self.rep_user = User.objects.create_user(phone="01700000812", password="x12345")
        self.org = CrmOrg.objects.create(name="Shop", owner=self.owner)
        self.om = CrmMember.objects.create(org=self.org, user=self.owner,
                                           role=CrmMember.OWNER)
        self.rep = CrmMember.objects.create(org=self.org, user=self.rep_user,
                                            role=CrmMember.SALES)
        pipe = pl.ensure_default_pipeline(self.org)
        stage = pipe.stages.first()
        self.lead = Lead.objects.create(org=self.org, name="Nadia",
                                        phone="01712345678", whatsapp="01712345678")
        self.deal = Deal.objects.create(
            org=self.org, title="Eid order", lead=self.lead, pipeline=pipe,
            stage=stage, owner=self.om, value=Decimal("5000"), state="open",
            next_step="call", next_step_due=timezone.now().date() - timedelta(days=1))
        Deal.objects.create(org=self.org, title="Won", pipeline=pipe, stage=stage,
                            owner=self.om, value=Decimal("9000"), state="won")
        Activity.objects.create(org=self.org, kind=Activity.TASK, subject="Send sample",
                                deal=self.deal, due_at=timezone.now() - timedelta(hours=1))

    def test_today_rows_open_their_lead(self):
        self.client.force_authenticate(self.owner)
        r = self.client.get("/api/v1/crm/today?org=%d" % self.org.id)
        self.assertEqual(r.status_code, 200, r.data)
        od = r.data["overdue_next_steps"][0]
        self.assertEqual(od["lead_id"], self.lead.id)
        self.assertEqual(od["phone"], "01712345678")
        task = r.data["due_tasks"][0]
        self.assertEqual(task["lead_id"], self.lead.id)
        self.assertEqual(task["lead_name"], "Nadia")

    def test_sales_rep_sees_no_colleague_money(self):
        self.client.force_authenticate(self.rep_user)
        r = self.client.get("/api/v1/crm/leaderboard/?org=%d" % self.org.id)
        self.assertEqual(r.status_code, 200, r.data)
        self.assertTrue(all("won_amount" not in row for row in r.data["rows"]))
        r = self.client.get("/api/v1/crm/commission-config/?org=%d" % self.org.id)
        if r.status_code == 404:
            r = self.client.get("/api/v1/crm/commission-config?org=%d" % self.org.id)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(len(r.data["preview"]), 1)           # only their own row
        self.client.force_authenticate(self.owner)
        r = self.client.get("/api/v1/crm/leaderboard/?org=%d" % self.org.id)
        self.assertTrue(any(row.get("won_amount") == 9000.0 for row in r.data["rows"]))
