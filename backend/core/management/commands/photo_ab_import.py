"""d1-photo v2: load the blind A/B test pairs (Owner Admin → Photo Studio).

  manage.py photo_ab_import <eval_out_dir> <remini_dir>

<eval_out_dir> is tools/photo_eval/run_eval.py's --out (inputs/, assisto/,
results.json); <remini_dir> holds the owner's Remini outputs named like the
inputs (or starting with the same number). Files are copied into private
media (photo_studio/ab/); pairs without a Remini file are skipped (and listed).
"""
import json
import os
import shutil

from django.conf import settings
from django.core.management.base import BaseCommand, CommandError


class Command(BaseCommand):
    help = "Import Assisto-vs-Remini pairs for the blind A/B vote"

    def add_arguments(self, parser):
        parser.add_argument("eval_dir")
        parser.add_argument("remini_dir")

    def handle(self, eval_dir, remini_dir, **_):
        from core.models import PhotoABPair
        inp, ours = os.path.join(eval_dir, "inputs"), os.path.join(eval_dir, "assisto")
        if not (os.path.isdir(inp) and os.path.isdir(ours) and os.path.isdir(remini_dir)):
            raise CommandError("need <eval>/inputs, <eval>/assisto and the remini folder")
        meta = {}
        rj = os.path.join(eval_dir, "results.json")
        if os.path.exists(rj):
            meta = {p["photo"]: p for p in json.load(open(rj)).get("photos", [])}
        dst = os.path.join(str(settings.MEDIA_ROOT), "photo_studio", "ab")
        os.makedirs(dst, exist_ok=True)
        rem = sorted(os.listdir(remini_dir))
        made, skipped = 0, []
        for name in sorted(os.listdir(inp)):
            num = name.split("_")[0]
            r = name if name in rem else next((x for x in rem if x.split("_")[0] == num
                                               or x.startswith(num)), None)
            if not r or not os.path.exists(os.path.join(ours, name)):
                skipped.append(name)
                continue
            names = {}
            for tag, src in (("in", os.path.join(inp, name)), ("a", os.path.join(ours, name)),
                             ("r", os.path.join(remini_dir, r))):
                ext = os.path.splitext(src)[1].lower() or ".jpg"
                rel = "photo_studio/ab/%s_%s%s" % (os.path.splitext(name)[0], tag, ext)
                shutil.copyfile(src, os.path.join(str(settings.MEDIA_ROOT), rel))
                names[tag] = rel
            m = meta.get(name, {})
            PhotoABPair.objects.update_or_create(name=name, defaults={
                "category": m.get("category", ""), "input_name": names["in"],
                "assisto_name": names["a"], "remini_name": names["r"],
                "metrics": m.get("metrics", {})})
            made += 1
        self.stdout.write("pairs: %d imported, %d skipped %s" % (made, len(skipped), skipped[:10]))
