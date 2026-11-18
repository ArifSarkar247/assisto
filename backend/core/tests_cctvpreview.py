"""cctv-preview — the CCTV alert photo on a 2G phone: a <= 20 KB preview of
the signed photo first (card + notification), the full photo after.
Synthetic images only."""
import io
import random

from django.core.cache import cache
from django.test import SimpleTestCase

from core import media_sign as MS
from core import tests_e2e_cctv as E2E


def _busy_jpeg(w=1280, h=720, seed=7):
    """A camera-like still: gradients + texture (a flat test card JPEGs to a
    few KB and would hide the 2G problem)."""
    from PIL import Image, ImageDraw
    rnd = random.Random(seed)
    im = Image.new("RGB", (w, h))
    px = im.load()
    for y in range(h):
        for x in range(w):
            n = rnd.randint(-28, 28)
            px[x, y] = (max(0, min(255, (x * 255) // w + n)),
                        max(0, min(255, (y * 255) // h + n)), max(0, min(255, 120 + n)))
    d = ImageDraw.Draw(im)
    for _ in range(40):
        x, y = rnd.randint(0, w), rnd.randint(0, h)
        d.rectangle((x, y, x + rnd.randint(10, 200), y + rnd.randint(10, 200)),
                    outline=(rnd.randint(0, 255),) * 3, width=3)
    out = io.BytesIO()
    im.save(out, "JPEG", quality=90)
    return out.getvalue()


class PreviewPureTests(SimpleTestCase):
    def test_preview_is_small_and_narrow(self):
        from PIL import Image
        raw = _busy_jpeg()
        self.assertGreater(len(raw), 100 * 1024)          # a real-size photo
        for w in MS.PREVIEW_WIDTHS:
            out = MS.preview_jpeg(raw, w)
            self.assertIsNotNone(out)
            self.assertLessEqual(len(out), MS.PREVIEW_MAX_BYTES, w)
            self.assertLessEqual(Image.open(io.BytesIO(out)).size[0], w)

    def test_not_an_image(self):
        self.assertIsNone(MS.preview_jpeg(b"not a jpeg", 320))

    def test_preview_url_keeps_the_signature(self):
        u = "https://api.example/api/v1/m/shop/a.jpg?e=1&s=abc"
        self.assertEqual(MS.preview_url(u), u + "&w=320")
        self.assertEqual(MS.preview_url(u, 160), u + "&w=160")
        self.assertIsNone(MS.preview_url(None))


class PreviewServeTests(E2E._Base):
    def setUp(self):
        super().setUp()
        cache.clear()

    def test_signed_preview_full_and_refused(self):
        from django.core.files.base import ContentFile
        from core.models import ShopEvent
        cam = self.add_camera("imou", "Gate")
        ev = ShopEvent.objects.create(site_id=self.site["id"], camera_id=cam["id"],
                                      type="person_detected", confidence=0.8)
        raw = _busy_jpeg()
        ev.snapshot.save("prev%d.jpg" % ev.id, ContentFile(raw), save=True)
        url = ev.snapshot.url
        full = self.client.get(url)
        self.assertEqual(full.status_code, 200)
        body = b"".join(full.streaming_content) if hasattr(full, "streaming_content") else full.content
        small = self.client.get(MS.preview_url(url))
        self.assertEqual(small.status_code, 200)
        self.assertEqual(small["Content-Type"], "image/jpeg")
        self.assertLessEqual(len(small.content), MS.PREVIEW_MAX_BYTES)
        self.assertLess(len(small.content), len(body))
        # an odd width is the full photo (no resize on demand), a bad sign 404
        odd = self.client.get(url + "&w=999")
        self.assertEqual(odd.status_code, 200)
        self.assertEqual(self.client.get(url.replace("s=", "s=0") + "&w=320").status_code, 404)
        # the card row carries the preview link
        r = self.client.get("/api/v1/shop/events?site=%d" % self.site["id"])
        row = [e for e in r.data["events"] if e["id"] == ev.id][0]
        self.assertTrue(row["snapshot_preview_url"].endswith("&w=320"))
