# ownershots.yml (owneradmin): crawl every Owner Admin page in the THROWAWAY
# seeded CI database with the same checks as web/tests_owneradmin_crawl.py and
# write crawl.json (+ the page list for the headless-browser 360 px pass).
#   python manage.py shell -c "exec(open('<this file>').read())"
import json
import os

from django.test import Client

from core.models import OwnerSession, User
from web.owner import crawlcheck as CC
from web.owner import security as S
from web.tests_owneradmin_crawl import seed_sample

out = os.environ.get("CRAWL_OUT", "/tmp/crawl.json")
owner = User.objects.filter(is_superuser=True).order_by("pk").first()
people = seed_sample(owner)
c = Client(SERVER_NAME="127.0.0.1")
r = c.post("/owner/login", {"phone": "01700000001", "password": "shots-pass-123"})
sess = OwnerSession.objects.get(key_hash=S.sha256(c.cookies[S.COOKIE].value))
r = c.post("/owner/2fa", {"code": S.totp("JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP"), "_ot": sess.csrf})
assert r.status_code == 302, r.status_code
rep = CC.crawl(c, extra=["/owner/users/%d" % people[0].pk])
with open(out, "w", encoding="utf-8") as f:
    json.dump(rep, f, ensure_ascii=False, indent=1)
print(CC.summary(rep, limit=2000))
