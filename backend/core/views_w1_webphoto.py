"""w1-webphoto: the app side of the lifeassisto.com/photo deep link.

  POST web-photo/claim {token}   (login required)
      Claims a photo made on the website ONCE, within its expiry (<= 1 hour).
      The clean file becomes the result of a Photo Studio `enhance_hd` job
      (job kind = the passport/visa preset), so saving / sharing goes through
      THE existing Photo Studio export gate: free users watch the rewarded
      ads (SSV-verified) or spend credits; Premium/Business export clean.
      The response carries only the job state + the (watermarked for free
      users) preview URL — never the clean file itself.
      410 {reason: "expired"}  unknown, already used, or expired token.
"""
from django.db import transaction
from rest_framework.response import Response
from rest_framework.views import APIView

from . import photo_studio_service as S
from .i18n import req_lang, pick
from web.logic import photo as photologic
from web.logic import webphoto as W


def claim(user, token, lang="bn"):
    from .models import PhotoStudioJob, WebPhotoDrop
    token = str(token or "").strip()
    with transaction.atomic():
        drop = W.live_drop(token)
        if drop is not None:
            drop = WebPhotoDrop.objects.select_for_update().filter(pk=drop.pk).first()
        if drop is None:
            return 410, {"ok": False, "reason": "expired", "message": pick(
                lang,
                "লিংকটির মেয়াদ শেষ বা আগেই ব্যবহার হয়েছে (ছবি ১ ঘণ্টা পর মুছে যায়)। "
                "ওয়েবসাইটে আবার ছবি বানিয়ে নিন, অথবা অ্যাপের Photo Studio-তে নিজের ছবি দিন।",
                "This link has expired or was already used (photos are deleted after "
                "1 hour). Make the photo again on the website, or open your own photo "
                "in Photo Studio.")}
        clean = bytes(drop.image)
        preset = drop.preset
        code, body = S.create_job(
            user, {"feature": "enhance_hd", "via": "ads" if S.is_free(user) else "",
                   "own_photo": True}, lang)
        if code != 201:
            return code, body                  # drop kept: the user may retry
        job = PhotoStudioJob.objects.get(pk=body["job"]["id"])
        opt = W.STUDIO_OPTION.get(preset)
        job.options = {**(job.options or {}), "options": [opt] if opt else [],
                       "source": "web_photo", "preset": preset}
        job.result_name = S._save_bytes(clean, "jpg")
        if S.is_free(user):
            # free: reduced + the strong face-band watermark (the clean file
            # leaves only through the export gate)
            job.preview_name = S._save_bytes(
                W.watermarked_preview(clean, W.APP_PREVIEW_MAX_PX), "jpg")
        else:
            prev = S.make_preview(clean, S.ps_cfg()["preview_max_px"], watermark=False)
            if prev:
                job.preview_name = S._save_bytes(prev, "png")
        job.save()
        drop.delete()                          # claimed once, gone from the web store
    label, phys, _bg = photologic.preset_label(preset, lang)
    return 200, {"ok": True, "job": S.job_state(job, lang), "preset": preset,
                 "label": label, "physical": phys, "studio_option": opt or ""}


class WebPhotoClaimView(APIView):
    def post(self, request):
        code, body = claim(request.user, (request.data or {}).get("token"),
                           req_lang(request))
        return Response(body, status=code)
