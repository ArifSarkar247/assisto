"""
cctv_store_migrate — ONE-SHOT: seal every legacy PLAIN CCTV file (alert
snapshots, camera previews, cash-guard clip ciphertext written before
cctvevidence W7) with core/logic/cctv_store.py, in place (encrypted local) or
uploaded to the S3-compatible bucket when CCTV_S3_* are set.

NO DATA LOSS: each file is read, sealed, written to a temp file and atomically
renamed (or uploaded, read back and opened, THEN the local copy removed). A
file that fails stays exactly as it was and is reported. Re-running is safe
(sealed files are skipped). The same happens lazily on the next access of a
file, so this command only speeds things up.

    # 1) always first: what WOULD happen (nothing is written)
    python manage.py cctv_store_migrate --dry-run
    # 2) then for real (low priority)
    nice -n15 ionice -c3 python manage.py cctv_store_migrate
"""
from django.core.management.base import BaseCommand


def _names():
    from core.models import ShopCamera, ShopEvent, ShopEventClip
    for n in ShopEvent.objects.exclude(snapshot="").exclude(snapshot=None) \
            .values_list("snapshot", flat=True).iterator():
        yield n
    for n in ShopCamera.objects.exclude(preview="").exclude(preview=None) \
            .values_list("preview", flat=True).iterator():
        yield n
    for n in ShopEventClip.objects.exclude(blob="").exclude(blob=None) \
            .values_list("blob", flat=True).iterator():
        yield n


def migrate(dry_run=True, names=None):
    """Returns {"plain", "sealed", "missing", "done", "failed": [names]}."""
    from core.logic import cctv_store as S
    out = {"plain": 0, "sealed": 0, "missing": 0, "done": 0, "failed": []}
    s3 = S.s3_backend()
    for name in (names if names is not None else _names()):
        if not S.valid_name(name):
            out["failed"].append(name)
            continue
        state = S.local_state(name)
        if state == "missing":
            out["missing"] += 1          # already in S3, or gone
            continue
        if state == "sealed" and s3 is None:
            out["sealed"] += 1
            continue
        out["plain" if state == "plain" else "sealed"] += 1
        if dry_run:
            continue
        try:
            data = S.get(name, migrate=False)
            if data is None:
                raise S.StoreError("unreadable")
            if s3 is not None:
                s3.put(name, S.seal(data, name))
                back = s3.get(name)
                if back is None or S.open_blob(back, name) != data:
                    raise S.StoreError("verify_failed")
                import os
                os.remove(S._local_path(name))
            else:
                S._write_local(name, S.seal(data, name))
                if S.get(name, migrate=False) != data:
                    raise S.StoreError("verify_failed")
            out["done"] += 1
        except Exception as e:  # noqa: BLE001 - file stays as it was
            out["failed"].append("%s (%s)" % (name, str(e)[:60]))
    return out


class Command(BaseCommand):
    help = "Seal legacy plain CCTV photo/clip files (dry-run first)."

    def add_arguments(self, parser):
        parser.add_argument("--dry-run", action="store_true",
                            help="only count; write nothing")

    def handle(self, *args, **opts):
        from core.logic import cctv_store as S
        res = migrate(dry_run=opts["dry_run"])
        self.stdout.write("cctv_store_migrate%s backend=%s plain=%d sealed=%d missing=%d "
                          "done=%d failed=%d" % (" (dry-run)" if opts["dry_run"] else "",
                                                 S.backend_name(), res["plain"], res["sealed"],
                                                 res["missing"], res["done"], len(res["failed"])))
        for f in res["failed"][:50]:
            self.stdout.write("  failed: %s" % f)
