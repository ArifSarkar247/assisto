"""aileft (owner 3 Nov 23:25 PART 7c): Photo Studio -> "Add to business catalog".

GET  business/products/photo  -> {has_catalog, products:[{id, name, has_photo}]}
     has_catalog = the user already runs a shop (a BusinessProfile they own,
     with a name or at least one product). It never creates a shop (the plain
     /business/products GET auto-creates an empty profile).
POST business/products/photo  (multipart: photo + product_id | name + price)
     -> attaches the edited photo to one of the user's own products, or creates
     a new product with it. Owner only (staff never write the catalog).
"""
from rest_framework.response import Response
from rest_framework.views import APIView

from .i18n import req_lang, pick

MAX_BYTES = 8 * 1024 * 1024
_IMAGE_MAGIC = (b"\x89PNG\r\n\x1a\n", b"\xff\xd8\xff", b"RIFF")


def _own_shop(user):
    from .models import BusinessProfile, Product
    prof = BusinessProfile.objects.filter(user=user).first()
    if prof is None:
        return None
    if (prof.shop_name or "").strip() or Product.objects.filter(user=user).exists():
        return prof
    return None


def _bad(lang, bn, en, code, status=400):
    return Response({"ok": False, "code": code, "detail": pick(lang, bn, en)}, status=status)


class CatalogPhotoView(APIView):
    def get(self, request):
        from .models import Product
        prof = _own_shop(request.user)
        if prof is None:
            return Response({"has_catalog": False, "products": []})
        rows = Product.objects.filter(user=request.user).order_by("-updated_at")[:50]
        return Response({"has_catalog": True,
                         "products": [{"id": p.id, "name": p.name, "has_photo": bool(p.photo)}
                                      for p in rows]})

    def post(self, request):
        from decimal import Decimal, InvalidOperation
        from django.core.files.base import ContentFile
        from .models import Product
        lang = req_lang(request)
        prof = _own_shop(request.user)
        if prof is None:
            return _bad(lang, "আপনার কোনো দোকানের ক্যাটালগ নেই।", "You don't have a shop catalog yet.",
                        "no_catalog", 404)
        f = request.FILES.get("photo")
        if f is None or f.size <= 0:
            return _bad(lang, "ছবি পাওয়া যায়নি।", "No photo received.", "no_photo")
        if f.size > MAX_BYTES:
            return _bad(lang, "ছবিটি খুব বড় (৮ MB পর্যন্ত)।", "The photo is too big (8 MB max).",
                        "too_big")
        head = f.read(12)
        f.seek(0)
        if not any(head.startswith(m) for m in _IMAGE_MAGIC):
            return _bad(lang, "এটি ছবি নয়।", "That is not a photo.", "not_image")
        ext = ".png" if head.startswith(_IMAGE_MAGIC[0]) else (
            ".jpg" if head.startswith(_IMAGE_MAGIC[1]) else ".webp")
        pid = request.data.get("product_id")
        if pid:
            p = Product.objects.filter(pk=pid, user=request.user).first()
            if p is None:
                return _bad(lang, "পণ্যটি পাওয়া যায়নি।", "Product not found.", "not_found", 404)
            created = False
        else:
            name = str(request.data.get("name") or "").strip()[:160]
            if not name:
                return _bad(lang, "পণ্যের নাম লিখুন।", "Type the product name.", "need_name")
            try:
                price = Decimal(str(request.data.get("price") or "0"))
            except (InvalidOperation, ValueError):
                price = Decimal("-1")
            if price < 0 or price > Decimal("100000000"):
                return _bad(lang, "দাম ঠিক নয়।", "The price is not valid.", "bad_price")
            p = Product.objects.create(user=request.user, business=prof, name=name, price=price)
            created = True
        p.photo.save("p%d%s" % (p.pk, ext), ContentFile(f.read()), save=True)
        from .business_views import _product_out
        from .logic import business_selling as selling
        return Response({"ok": True, "created": created,
                         "product": _product_out(p, selling.ROLE_OWNER)},
                        status=201 if created else 200)
