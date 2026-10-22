"""w1-webphoto — the lifeassisto.com/photo growth funnel, with NO free bypass.

  * The web makes the passport/visa photo but only ever shows a reduced,
    visibly watermarked PREVIEW (the watermark crosses the face area on
    purpose — it stays a useful "is the crop right?" preview, not a usable file).
  * The clean processed JPEG is parked server-side under an unguessable token
    (256-bit, urlsafe) for at most TTL_MIN minutes, in the DATABASE (never on
    disk, never under /media). No web route ever returns those bytes.
  * The "Get it in the Assisto app" deep link carries the token. The app,
    after login, CLAIMS it once (core/views_w1_webphoto.py): the clean file
    becomes a Photo Studio job result, so saving/sharing goes through the
    normal Photo Studio export gate (ads / credits / Premium) — no new bypass.
  * Expired drops are deleted on access, opportunistically on every new
    upload, and by `manage.py purge_web_photos` (cron, every 10 minutes).
"""
import io
import secrets
from datetime import timedelta

from django.utils import timezone

TTL_MIN = 60                # owner order: expire within 1 hour (hard ceiling)
PREVIEW_MAX_PX = 240        # long edge of the web preview (the clean file is 531+ px)
PREVIEW_QUALITY = 60
APP_PREVIEW_MAX_PX = 360    # free users' in-app preview (same strong watermark)
WATERMARK = "ASSISTO PREVIEW"

# web preset -> the matching Photo Studio option (the job "kind" in the app)
STUDIO_OPTION = {
    "bd_passport": "passport_bd",
    "bd_mrp": "passport_bd",
    "schengen": "passport_bd",
    "passport_2x2": "visa_bd",
    "us_visa": "visa_bd",
}


def ttl():
    return timedelta(minutes=min(60, max(1, TTL_MIN)))


def new_token():
    return secrets.token_urlsafe(32)          # 43 chars, 256 bits


def watermarked_preview(clean_jpeg, max_px=PREVIEW_MAX_PX):
    """Reduced-size JPEG with a heavy diagonal watermark band across the
    centre (face area) plus a tiled light watermark everywhere."""
    from PIL import Image, ImageDraw, ImageFont
    im = Image.open(io.BytesIO(clean_jpeg)).convert("RGB")
    im.thumbnail((max_px, max_px), Image.LANCZOS)
    w, h = im.size
    try:
        font = ImageFont.load_default(size=max(12, w // 11))
        small = ImageFont.load_default(size=max(9, w // 18))
    except TypeError:                          # very old Pillow
        font = small = ImageFont.load_default()
    # tiled light marks over the whole picture
    tile = Image.new("RGBA", (w * 2, h * 2), (0, 0, 0, 0))
    d = ImageDraw.Draw(tile)
    step = max(28, h // 7)
    for i, yy in enumerate(range(0, h * 2, step)):
        for xx in range(-w, w * 2, max(60, w // 2)):
            d.text((xx + (i % 2) * w // 4, yy), "Assisto", font=small,
                   fill=(255, 255, 255, 120))
            d.text((xx + (i % 2) * w // 4 + 1, yy + 1), "Assisto", font=small,
                   fill=(0, 0, 0, 70))
    tile = tile.rotate(30, resample=Image.BICUBIC)
    tile = tile.crop((w // 2, h // 2, w // 2 + w, h // 2 + h))
    base = Image.alpha_composite(im.convert("RGBA"), tile)
    # the solid band across the face area
    band = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    bd = ImageDraw.Draw(band)
    bh = max(18, h // 6)
    top = int(h * 0.42) - bh // 2
    bd.rectangle([0, top, w, top + bh], fill=(10, 26, 61, 150))
    tw = bd.textlength(WATERMARK, font=font)
    bd.text(((w - tw) / 2, top + (bh - font.size) / 2 - 1), WATERMARK,
            font=font, fill=(255, 255, 255, 235))
    out = Image.alpha_composite(base, band).convert("RGB")
    buf = io.BytesIO()
    out.save(buf, "JPEG", quality=PREVIEW_QUALITY)
    return buf.getvalue()


def park(clean_jpeg, preset, ip_hash=""):
    """Store the clean photo under a fresh token. Returns the drop."""
    from core.models import WebPhotoDrop
    purge_expired()
    return WebPhotoDrop.objects.create(
        token=new_token(), preset=preset[:24], image=clean_jpeg,
        ip_hash=ip_hash[:64], expires_at=timezone.now() + ttl())


def live_drop(token):
    """The drop for `token` if it is still valid. An expired one is deleted
    right here (on-access expiry) and None is returned."""
    from core.models import WebPhotoDrop
    if not token or len(token) > 64:
        return None
    d = WebPhotoDrop.objects.filter(token=token).first()
    if d is None:
        return None
    if d.expires_at <= timezone.now():
        d.delete()
        return None
    return d


def purge_expired(now=None):
    """Delete every expired drop. Returns how many rows went."""
    from core.models import WebPhotoDrop
    n, _ = WebPhotoDrop.objects.filter(expires_at__lte=now or timezone.now()).delete()
    return n
