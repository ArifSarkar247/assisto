"""seoblog: Owner Admin -> Blog (/owner/blog). List, new, edit (Bangla +
English Markdown, cover image, publish switch, last-reviewed date), one-tap
publish / unpublish, delete with a confirm tick, live preview of the page.
Every change is written to the owner audit log."""
from django.http import Http404
from django.views.decorators.http import require_http_methods

from . import security as S
from .base import done, owner_view, page

L = {
    "bn": {"title": "ব্লগ", "new": "নতুন লেখা", "edit": "লেখা সম্পাদনা", "slug": "ঠিকানা (ইংরেজি ছোট হাতের অক্ষর ও ড্যাশ)",
           "title_bn": "শিরোনাম (বাংলা)", "title_en": "শিরোনাম (ইংরেজি)",
           "summary_bn": "সারসংক্ষেপ / সার্চের বর্ণনা (বাংলা, ≤২০০)", "summary_en": "সারসংক্ষেপ / সার্চের বর্ণনা (ইংরেজি, ≤২০০)",
           "body_bn": "লেখা (বাংলা, Markdown)", "body_en": "লেখা (ইংরেজি, Markdown)",
           "feature": "কোন ফিচার পাতায় লিংক যাবে", "keywords": "লক্ষ্য কীওয়ার্ড (শুধু আপনার নোট, পাতায় দেখায় না)",
           "cover": "কভার ছবি (PNG/JPEG/WEBP ≤ ২ MB, ১২০০×৬৩০ ভালো)", "cover_alt_bn": "ছবির বর্ণনা (বাংলা)",
           "cover_alt_en": "ছবির বর্ণনা (ইংরেজি)", "remove_cover": "কভার ছবি সরান",
           "published": "প্রকাশিত (চালু করলে সবাই দেখবে, সাইটম্যাপে যাবে)", "last_reviewed": "সর্বশেষ যাচাইয়ের তারিখ",
           "order": "ক্রম (ছোট সংখ্যা আগে)", "save": "সেভ", "publish": "প্রকাশ করুন", "unpublish": "প্রকাশ বন্ধ",
           "delete": "মুছে ফেলুন", "confirm": "হ্যাঁ, এই লেখাটি মুছে ফেলুন", "view": "পাতা দেখুন",
           "state_on": "প্রকাশিত", "state_off": "খসড়া (প্রকাশিত নয়)", "none": "এখনো কোনো লেখা নেই। সার্ভারে একবার `python manage.py seed_blog` চালালে ১০টি খসড়া লেখা আসবে।",
           "intro": "লেখাগুলো খসড়া হিসেবে থাকে — পড়ে, দরকার হলে ঠিক করে, তারিখ বসিয়ে তারপর “প্রকাশ করুন”। প্রকাশ করতে বাংলা ও ইংরেজি দুটো শিরোনাম ও লেখা লাগবে। Markdown: ## শিরোনাম, - তালিকা, 1. ধাপ, **মোটা**, [লিংক](/features/...), > নোট, | টেবিল |।",
           "preview": "প্রিভিউ (বাংলা)", "errors": "এগুলো ঠিক করুন:", "reviewed": "যাচাই",
           "err": {"required": "লাগবে", "slug": "শুধু a-z, 0-9 আর ড্যাশ", "taken": "এই ঠিকানা আগেই আছে",
                   "too_long": "বেশি লম্বা", "unknown": "অচেনা ফিচার", "date": "তারিখ ঠিক নয়",
                   "number": "সংখ্যা দিন", "both_languages": "প্রকাশ করতে বাংলা ও ইংরেজি দুটো শিরোনাম ও লেখা লাগবে",
                   "too_large": "ছবি ২ MB-এর বেশি", "not_an_image": "PNG/JPEG/WEBP ছবি নয়"}},
    "en": {"title": "Blog", "new": "New article", "edit": "Edit article", "slug": "Address (slug: lowercase, dashes)",
           "title_bn": "Title (Bangla)", "title_en": "Title (English)",
           "summary_bn": "Summary / meta description (Bangla, ≤200)", "summary_en": "Summary / meta description (English, ≤200)",
           "body_bn": "Body (Bangla, Markdown)", "body_en": "Body (English, Markdown)",
           "feature": "Feature page it links to", "keywords": "Target keywords (your note only, not shown on the page)",
           "cover": "Cover image (PNG/JPEG/WEBP ≤ 2 MB, 1200×630 is best)", "cover_alt_bn": "Image description (Bangla)",
           "cover_alt_en": "Image description (English)", "remove_cover": "Remove the cover image",
           "published": "Published (visible to everyone, listed in the sitemap)", "last_reviewed": "Last reviewed date",
           "order": "Order (smaller first)", "save": "Save", "publish": "Publish", "unpublish": "Unpublish",
           "delete": "Delete", "confirm": "Yes, delete this article", "view": "View page",
           "state_on": "Published", "state_off": "Draft (not published)", "none": "No articles yet. Run `python manage.py seed_blog` once on the server to load the 10 draft articles.",
           "intro": "Articles start as drafts — read, fix if needed, set the date, then tap “Publish”. Publishing needs both the Bangla and English title and body. Markdown: ## heading, - list, 1. steps, **bold**, [link](/features/...), > note, | table |.",
           "preview": "Preview (Bangla)", "errors": "Please fix:", "reviewed": "Reviewed",
           "err": {"required": "required", "slug": "only a-z, 0-9 and dashes", "taken": "this address is taken",
                   "too_long": "too long", "unknown": "unknown feature", "date": "not a date",
                   "number": "enter a number", "both_languages": "publishing needs both the Bangla and English title and body",
                   "too_large": "image over 2 MB", "not_an_image": "not a PNG/JPEG/WEBP image"}},
}


def _L(request):
    return L.get(getattr(request, "owner_lang", "bn"), L["bn"])


def _post_or_404(pk):
    from core.models import BlogPost
    p = BlogPost.objects.filter(pk=pk).first()
    if p is None:
        raise Http404
    return p


def _snap(p):
    return {"slug": p.slug, "title_bn": p.title_bn, "title_en": p.title_en, "published": p.published,
            "feature": p.feature, "last_reviewed": p.last_reviewed.isoformat() if p.last_reviewed else "",
            "body_bn_len": len(p.body_bn), "body_en_len": len(p.body_en), "cover": bool(p.cover)}


def _form(request, post, data=None, errors=None, status=200):
    from web import blog as B
    lab = _L(request)
    preview = ""
    if post is not None and post.body_bn:
        preview, _ = B.render_markdown(post.body_bn)
    return page(request, "owner/blog_form.html",
                {"L": lab, "post": post, "d": data or {}, "errors": {k: lab["err"].get(v, v) for k, v in (errors or {}).items()},
                 "features": [(k, v[1] if getattr(request, "owner_lang", "bn") == "bn" else v[2]) for k, v in B.FEATURES.items()],
                 "preview": preview}, status=status, nav="blog")


@require_http_methods(["GET"])
@owner_view()
def blog_list(request):
    from core.models import BlogPost
    from web import blog as B
    rows = [{"p": p, "complete": B.is_complete(p)} for p in BlogPost.objects.all()]
    return page(request, "owner/blog_list.html", {"L": _L(request), "rows": rows}, nav="blog")


def _data(post):
    if post is None:
        return {}
    d = {f: getattr(post, f) for f in ("slug", "title_bn", "title_en", "summary_bn", "summary_en", "body_bn",
                                        "body_en", "feature", "keywords", "cover_alt_bn", "cover_alt_en", "order",
                                        "published")}
    d["last_reviewed"] = post.last_reviewed.isoformat() if post.last_reviewed else ""
    return d


@require_http_methods(["GET", "POST"])
@owner_view()
def blog_new(request):
    from core.models import BlogPost
    from web import blog as B
    if request.method == "GET":
        return _form(request, None, {"order": 0})
    v, e = B.clean(request.POST)
    f = request.FILES.get("cover")
    if e:
        return _form(request, None, request.POST, e, status=400)
    post = B.apply(BlogPost(), v)
    if f:
        err = B.save_cover(post, f)
        if err:
            return _form(request, post, _data(post), {"cover": err}, status=400)
    S.audit(request, request.owner, "blog.create", "blog:%s" % post.pk, after=_snap(post))
    return done("/owner/blog/%d" % post.pk, "created")


@require_http_methods(["GET", "POST"])
@owner_view()
def blog_edit(request, pk):
    from web import blog as B
    post = _post_or_404(pk)
    if request.method == "GET":
        return _form(request, post, _data(post))
    before = _snap(post)
    v, e = B.clean(request.POST, post)
    if e:
        return _form(request, post, request.POST, e, status=400)
    B.apply(post, v)
    if request.POST.get("remove_cover") == "on" and post.cover:
        post.cover.delete(save=True)
    f = request.FILES.get("cover")
    if f:
        err = B.save_cover(post, f)
        if err:
            return _form(request, post, _data(post), {"cover": err}, status=400)
    S.audit(request, request.owner, "blog.update", "blog:%s" % post.pk, before=before, after=_snap(post))
    return done("/owner/blog/%d" % post.pk)


@require_http_methods(["POST"])
@owner_view()
def blog_toggle(request, pk):
    from django.utils import timezone
    from web import blog as B
    post = _post_or_404(pk)
    if not post.published and not B.is_complete(post):
        return done("/owner/blog", "invalid")
    post.published = not post.published
    if post.published and not post.published_at:
        post.published_at = timezone.now()
    post.save(update_fields=["published", "published_at", "updated_at"])
    S.audit(request, request.owner, "blog.publish" if post.published else "blog.unpublish",
            "blog:%s" % post.pk, before={"published": not post.published}, after={"published": post.published})
    return done("/owner/blog")


@require_http_methods(["POST"])
@owner_view()
def blog_delete(request, pk):
    post = _post_or_404(pk)
    if request.POST.get("confirm") != "on":
        return done("/owner/blog/%d" % pk, "confirm_needed")
    snap = _snap(post)
    if post.cover:
        post.cover.delete(save=False)
    post.delete()
    S.audit(request, request.owner, "blog.delete", "blog:%s" % pk, before=snap)
    return done("/owner/blog", "deleted")
