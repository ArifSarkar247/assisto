"""aifinal round 2 item 9 (owner 4 Nov 00:25): ONE real end-to-end AI check
on the live server, run by the lead after deploy (never in CI):

  manage.py ai_live_e2e --user <id> [--voice-file bn.wav] [--provider anthropic|gemini|both]

Checks (PASS / FAIL / SKIP per line, never prints a key or message text
beyond a short snippet):
  1. voice: a Bangla WAV -> server transcription in BANGLA SCRIPT (skipped
     without --voice-file; no Bangla sample is bundled — record one on a phone)
  2. photo: a generated sample image with "DHAKA - GAZIPUR 12" + a Bangla
     question -> one answer, in Bangla, that uses the image
  3. follow-up in the same chat (per provider) -> Bangla, still knows the
     image, not a "never reached me" answer
  4. ledger: the credits shown on every answer == the ledger rows of the run
It spends the test account's real credits (a few) and leaves one chat."""
import base64
import io

from django.core.management.base import BaseCommand, CommandError
from django.utils import timezone

_BN = "ঀ-৿"


def _bn(text):
    import re
    return bool(re.search("[%s]" % _BN, text or ""))


def _sample_png():
    from PIL import Image, ImageDraw
    im = Image.new("RGB", (640, 260), "white")
    d = ImageDraw.Draw(im)
    d.rectangle((10, 10, 630, 250), outline="black", width=4)
    try:
        from PIL import ImageFont
        f = ImageFont.load_default(size=48)
    except Exception:  # noqa: BLE001
        f = None
    d.text((40, 60), "DHAKA - GAZIPUR", fill="black", font=f)
    d.text((40, 140), "BUS 12", fill="black", font=f)
    b = io.BytesIO()
    im.save(b, "PNG")
    return b.getvalue()


class Command(BaseCommand):
    help = "Live AI end-to-end check (voice -> photo -> follow-up -> ledger). Lead only."

    def add_arguments(self, p):
        p.add_argument("--user", type=int, required=True)
        p.add_argument("--voice-file", default="")
        p.add_argument("--provider", default="both", choices=("anthropic", "gemini", "both"))

    def say(self, ok, name, detail=""):
        tag = {True: "PASS", False: "FAIL", None: "SKIP"}[ok]
        self.stdout.write("%s  %s%s" % (tag, name, (" — " + detail) if detail else ""))
        if ok is False:
            self.failed += 1

    def handle(self, *a, **o):
        from core import ai, chat_vision_service as CVS
        from core import views_chat as VC
        from core import voice_transcribe as VT
        from core.models import ChatSession, CreditLedger, User
        self.failed = 0
        u = User.objects.filter(pk=o["user"]).first()
        if u is None:
            raise CommandError("no such user")
        t0 = timezone.now()
        shown = 0
        # 1. voice
        if o["voice_file"]:
            wav = open(o["voice_file"], "rb").read()
            code, body = VT.transcribe(u, {"audio_b64": base64.b64encode(wav).decode(),
                                           "lang": "bn"})
            shown += int(body.get("credits") or 0)
            self.say(code == 200 and _bn(body.get("text")), "voice -> Bangla script",
                     (body.get("text") or body.get("reason") or "")[:40])
        else:
            self.say(None, "voice -> Bangla script", "no --voice-file (record a Bangla WAV)")
        # 2. photo + Bangla question in a new chat
        s = ChatSession.objects.create(user=u, title="ai_live_e2e")
        q = "এই ছবিতে কোন শহরের নাম লেখা আছে?"
        code, body = CVS.create_job(u, {"via": "credits", "question": q}, "bn")
        if code not in (200, 201):
            code, body = CVS.create_job(u, {"via": "pool", "question": q}, "bn")
        job = None
        if code in (200, 201):
            from core.models import PhotoStudioJob
            job = PhotoStudioJob.objects.get(pk=body["job"]["id"])
            code, body = CVS.answer(u, job, {"image_b64": base64.b64encode(_sample_png()).decode(),
                                             "question": q, "session_id": str(s.pk)}, "bn")
        ans = ((body or {}).get("job") or {}).get("answer", "")
        job and job.refresh_from_db()
        if job is not None and job.funding in ("credits", "pool"):
            shown += int(job.credits_charged or 0)
        self.say(code == 200 and _bn(ans), "photo answer in Bangla", ans[:40])
        self.say(code == 200 and ("গাজীপুর" in ans or "gazipur" in ans.lower()),
                 "photo answer used the image")
        # 3. follow-up per provider
        provs = ("anthropic", "gemini") if o["provider"] == "both" else (o["provider"],)
        for p in provs:
            with ai.only_provider(p):
                reply, meta, _ = VC._produce_reply(u, s, "বাসটি কোথায় যাবে?", "bn",
                                                   VC._history_for(s))
            shown += int(meta.get("credits") or 0)
            ok_ai = meta.get("source") == "ai"
            self.say(ok_ai, "follow-up answered by %s" % p, meta.get("ai_unavailable", ""))
            self.say(ok_ai and _bn(reply), "follow-up in Bangla (%s)" % p)
            self.say(ok_ai and ("গাজীপুর" in reply or "gazipur" in reply.lower())
                     and not VC._failed_task(reply), "follow-up still knows the image (%s)" % p)
        # 4. ledger == what the answers showed
        spent = -sum(r.delta for r in CreditLedger.objects.filter(
            user=u, created_at__gte=t0) if r.delta < 0 and r.reason == "consume")
        back = sum(r.delta for r in CreditLedger.objects.filter(
            user=u, created_at__gte=t0) if r.delta > 0)
        self.say(spent - back == shown, "ledger matches the bubbles",
                 "ledger %d - refunds %d vs shown %d" % (spent, back, shown))
        self.stdout.write("RESULT: %s" % ("FAIL (%d)" % self.failed if self.failed else "PASS"))
