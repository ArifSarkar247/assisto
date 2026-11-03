"""guardian2 (PART 6): Owner Admin / staff NEVER see any location.

Seeds a child with a school plan, a kids watch, a second guardian and an SOS
— all carrying the same unmistakable coordinates — then crawls every
argument-free Owner Admin page (logged in as the enrolled owner) plus the
user-detail pages of the people involved, and the Django admin index, and
checks that the coordinates never appear. A static check makes sure the owner
panel code / templates never import the location-bearing models and that
Django admin registers none of them."""
import re
from pathlib import Path
from unittest import mock

from django.contrib import admin
from django.core.cache import cache
from django.urls import URLPattern, get_resolver
from django.utils import timezone

from core import family_alerts as FA
from core.models import CircleMember, GuardianLink, KidsWatch, SchoolPlan, User
from web.tests_o2_owner_admin import OwnerBase

LAT, LNG = "23.7771", "90.3991"
LOCATION_MODELS = ("GuardianLink", "KidsWatch", "KidsWatchPosition", "SchoolPlan",
                   "SchoolEvent", "FamilyAlert", "FamilyAlertDelivery", "JourneyPoint",
                   "VehiclePosition", "PhoneHeartbeat", "CirclePresence", "SavedPlace")
OWNER_DIR = Path(__file__).resolve().parent / "owner"
TPL_DIR = Path(__file__).resolve().parent / "templates" / "owner"


def _pair(a, b, rab, rba):
    CircleMember.objects.create(user=a, peer_user=b, name=b.name, state="accepted",
                                relation=rab)
    CircleMember.objects.create(user=b, peer_user=a, name=a.name, state="accepted",
                                relation=rba, direction="incoming")


class AdminSeesNoLocation(OwnerBase):
    def setUp(self):
        super().setUp()
        cache.clear()
        self.ready()
        p = mock.patch("core.push.safe_push", return_value=True)
        p.start()
        self.addCleanup(p.stop)
        now = timezone.now()
        self.mom = User.objects.create_user(name="Mom", phone="01711500001", password="pw12345!")
        self.dad = User.objects.create_user(name="Dad", phone="01711500002", password="pw12345!")
        self.kid = User.objects.create_user(name="Rina", phone="01711500003", password="pw12345!")
        _pair(self.mom, self.kid, "child", "mother")
        SchoolPlan.objects.create(owner=self.mom, child_user=self.kid, child_name="Rina",
                                  accepted_at=now,
                                  last_known={"lat": 23.7771234, "lng": 90.3991234})
        KidsWatch.objects.create(owner=self.mom, child_user=self.kid, child_name="Rina",
                                 imei="8800000988", state="paired",
                                 last_lat=23.7771234, last_lng=90.3991234)
        GuardianLink.objects.create(child=self.kid, invited_by=self.mom, guardian=self.dad,
                                    code="TESTG2AA", state="approved", approved_at=now,
                                    decided_by=self.mom, expires_at=now)
        FA.sos(self.kid, lat=23.7771234, lng=90.3991234, client_id="adm")

    def _owner_urls(self):
        out = []
        for p in get_resolver("web.owner.urls").url_patterns:
            if isinstance(p, URLPattern) and not p.pattern.converters:
                route = str(p.pattern)
                if route in ("logout", "login", "2fa", "enrol"):
                    continue
                out.append("/owner/" + route)
        return out

    def test_owner_admin_pages_return_no_coordinates(self):
        self.c.raise_request_exception = False
        urls = self._owner_urls() + ["/owner/users/%d" % u.pk
                                     for u in (self.mom, self.dad, self.kid)]
        checked = 0
        for url in urls:
            r = self.c.get(url)
            if r.status_code != 200 or getattr(r, "streaming", False):
                continue
            body = r.content.decode("utf-8", "ignore")
            self.assertNotIn(LAT, body, url)
            self.assertNotIn(LNG, body, url)
            checked += 1
        self.assertGreater(checked, 10)

    def test_django_admin_registers_no_location_model(self):
        names = {m.__name__ for m in admin.site._registry}
        self.assertEqual(names & set(LOCATION_MODELS), set())
        self.client.force_login(self.owner)
        r = self.client.get("/admin/", secure=True)
        body = r.content.decode("utf-8", "ignore")
        self.assertNotIn(LAT, body)

    def test_owner_code_never_reads_location_models(self):
        hits = []
        for f in list(OWNER_DIR.glob("*.py")) + list(TPL_DIR.glob("*.html")):
            text = f.read_text(encoding="utf-8")
            for tok in LOCATION_MODELS + ("last_lat", "last_lng", "last_known"):
                if re.search(r"\b%s\b" % tok, text):
                    hits.append("%s: %s" % (f.name, tok))
        self.assertEqual(hits, [], hits)
