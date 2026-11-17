"""seolive (owner orders 17 Nov: "SEO LIVE" + "Assisto is LIVE on Google Play").

ONE idempotent step the lead runs after a deploy (the lead cannot tap Owner
Admin; this is the same audited flag engine the Owner Admin -> Website
buttons use):

  * site_seo_growth_preview -> OFF  (feature landing pages indexable, in the
    sitemap and the site navigation; a page whose app feature is OFF stays 404)
  * site_play_badge_hidden  -> OFF  (Google Play badge + links on the site,
    Play URL in the SoftwareApplication JSON-LD)
  * publishes the blog articles that passed the 17 Nov fact-check, BY SLUG
    (PASSING). Missing ones are loaded from web.blog_seed first. A stored
    body that is still an older, superseded seed text (STALE) is refreshed to
    the fact-checked text; an owner-edited body is never overwritten.

  manage.py site_go_live --dry-run   # prints what would change, writes nothing
  manage.py site_go_live --apply     # does it; running it again changes nothing
"""
import hashlib

from django.core.management.base import BaseCommand, CommandError
from django.db import transaction
from django.utils import timezone

# Fact-checked 17 Nov 2026 (seolive): Bangladesh facts dated, no medical or
# legal advice beyond general safety, nothing about an app feature that is
# OFF live. Kept as drafts: blood-donation-eligibility-bangladesh (the blood
# donor panel `blood_donors` is OFF live) and
# quran-reading-bangla-pronunciation-guide (`quran` / `quran_learn` are OFF).
PASSING = (
    "mess-bazar-meal-hisab",
    "family-location-sharing-safely",
    "old-phone-as-shop-cctv",
    "ielts-4-week-mock-test-plan",
    "dhaka-metro-rail-station-guide",
    "dokaner-baki-khata-niyom",
    "safe-journey-night-travel-tips",
    "ai-assistant-bangla-daily-tasks",
)
KEPT_DRAFT = ("blood-donation-eligibility-bangladesh", "quran-reading-bangla-pronunciation-guide")

# sha256[:16] of seed bodies that the 17 Nov fact-check replaced (stored as
# body.strip() + "\n" by blog_seed.load). Such a body was never edited by the
# owner, so it is safe to refresh it to the corrected text before publishing.
STALE = {
    "family-location-sharing-safely": {"bn": "6929820fa57b1211", "en": "b2f1081047aef26f"},
    "ielts-4-week-mock-test-plan": {"bn": "ba5688236b7503af", "en": "16520eb6be13df45"},
}
ACTOR = "site_go_live (lead, owner orders 17 Nov: SEO live + live on Google Play)"


def _h(text):
    return hashlib.sha256((text or "").encode()).hexdigest()[:16]


def _seed_body(a, lang):
    return a["body_" + lang].strip() + "\n"


class Command(BaseCommand):
    help = "Website go-live: landing pages indexable, Google Play shown, fact-checked blog articles published."

    def add_arguments(self, parser):
        g = parser.add_mutually_exclusive_group(required=True)
        g.add_argument("--dry-run", action="store_true", help="show what would change, write nothing")
        g.add_argument("--apply", action="store_true", help="make the changes (idempotent)")

    def handle(self, *args, **opts):
        apply = bool(opts["apply"])
        out = []
        with transaction.atomic():
            out += self._flags(apply)
            out += self._blog(apply)
        if apply:
            from django.core.cache import cache
            from web import site_v3_dist as DIST
            cache.delete(DIST.PLAY_CACHE_KEY)   # re-check the Play listing on the next page view
        changed = [x for x in out if x.startswith("CHANGE")]
        for line in out:
            self.stdout.write(line)
        self.stdout.write("%s: %d change(s)%s" % ("site_go_live --apply" if apply else "site_go_live --dry-run",
                                                  len(changed), "" if apply else " (nothing written)"))

    # ------------------------------------------------------------ flags
    def _flags(self, apply):
        from core.views_build61 import flags_flip
        from web import site_landing as LP
        from web import site_v3_dist as DIST
        rows = []
        for fid, label, is_live in ((LP.PREVIEW_FLAG, "feature landing pages live (indexable)", LP.growth_live),
                                    (DIST.PLAY_BADGE_HIDDEN_FLAG, "Google Play badge + links shown", DIST.play_badge_on)):
            if is_live():
                rows.append("ok      %s: already ON (%s=OFF)" % (label, fid))
                continue
            rows.append("CHANGE  %s: OFF -> ON (%s -> OFF)" % (label, fid))
            if apply:
                ok, payload = flags_flip(ACTOR, fid, False, "website go-live: %s" % label)
                if not ok and "no_op" not in (payload.get("problems") or []):
                    raise CommandError("flag %s: %s" % (fid, payload.get("problems")))
        return rows

    # ------------------------------------------------------------- blog
    def _blog(self, apply):
        from core.models import BlogPost
        from web import blog as B
        from web import blog_seed
        seed = {a["slug"]: a for a in blog_seed.ARTICLES}
        unknown = [s for s in PASSING if s not in seed]
        if unknown:
            raise CommandError("not in web.blog_seed: %s" % ", ".join(unknown))
        rows = []
        missing = [s for s in PASSING + KEPT_DRAFT if not BlogPost.objects.filter(slug=s).exists()]
        if missing:
            rows.append("CHANGE  blog: load %d missing seed article(s) as drafts: %s" % (len(missing), ", ".join(missing)))
            if apply:
                blog_seed.load()
        now = timezone.now()
        for slug in PASSING:
            p = BlogPost.objects.filter(slug=slug).first()
            a = seed[slug]
            refresh = []
            if p is not None:
                for lang in ("bn", "en"):
                    if _h(getattr(p, "body_" + lang)) == STALE.get(slug, {}).get(lang):
                        refresh.append(lang)
            if refresh:
                rows.append("CHANGE  blog %s: refresh superseded seed text (%s) to the fact-checked text"
                            % (slug, "+".join(refresh)))
            if p is not None and p.published and B.is_complete(p) and not refresh:
                rows.append("ok      blog %s: already published" % slug)
                continue
            if p is None:
                rows.append("CHANGE  blog %s: publish (after loading it)" % slug)
            elif not p.published:
                rows.append("CHANGE  blog %s: draft -> published" % slug)
            if not apply:
                continue
            p = p or BlogPost.objects.get(slug=slug)
            for lang in refresh:
                setattr(p, "body_" + lang, _seed_body(a, lang))
            if not B.is_complete(p):
                raise CommandError("blog %s: a title or body is empty — not publishing a half page" % slug)
            p.published = True
            p.published_at = p.published_at or now
            p.save()
        for slug in KEPT_DRAFT:
            p = BlogPost.objects.filter(slug=slug).first()
            state = "published (left as the owner set it)" if (p and p.published) else "draft"
            rows.append("ok      blog %s: kept %s — feature OFF live, not fact-check passed" % (slug, state))
        return rows
