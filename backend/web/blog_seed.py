"""seoblog: the 10 first how-to articles (owner order 17 Nov 00:32, item 6).

AI-drafted, fact-checked by hand on 17 Nov 2026 (sources in
owner_actions/SEO_KEYWORDS_BN.md). They load UNPUBLISHED (`manage.py
seed_blog`); the owner reads, edits and publishes each one in Owner Admin ->
Website blog. Rules kept: no fake reviews or stats, no copied text, prices
only with a date, laws only in general terms, no medical or legal advice
beyond general safety, no AI translation of Quran text (only licensed
sources are pointed to). Example names and numbers are made up.
"""
from . import blog_seed_a as A
from . import blog_seed_b as B

REVIEWED = "2026-11-17"

ARTICLES = A.ARTICLES + B.ARTICLES


def load(stdout=None):
    """Create each article that does not exist yet (by slug). Never
    overwrites an owner edit, never publishes. Returns (created, skipped)."""
    from django.utils.dateparse import parse_date
    from core.models import BlogPost
    created = skipped = 0
    for n, a in enumerate(ARTICLES):
        if BlogPost.objects.filter(slug=a["slug"]).exists():
            skipped += 1
            continue
        BlogPost.objects.create(
            slug=a["slug"], title_bn=a["title_bn"], title_en=a["title_en"],
            summary_bn=a["summary_bn"], summary_en=a["summary_en"],
            body_bn=a["body_bn"].strip() + "\n", body_en=a["body_en"].strip() + "\n",
            feature=a["feature"], keywords=a["keywords"], published=False,
            last_reviewed=parse_date(REVIEWED), order=(n + 1) * 10)
        created += 1
    return created, skipped
