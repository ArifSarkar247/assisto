"""c1-contacts: recompute every UserPhoneHash with the CURRENT match salt.

Run after setting / rotating settings.SERVER_MATCH_SALT (or SECRET_KEY when no
explicit salt is set) — otherwise existing hashes stop matching what devices
compute from the contract salt. Idempotent; never touches User rows.

    python manage.py rebuild_phone_hashes
"""
from django.core.management.base import BaseCommand


class Command(BaseCommand):
    help = "Recompute UserPhoneHash rows for every user with a valid phone."

    def handle(self, *args, **opts):
        from core.models import User
        from core.phone import sync_phone_hash
        ok = skipped = 0
        for u in User.objects.exclude(phone__isnull=True).exclude(phone="").iterator():
            if sync_phone_hash(u):
                ok += 1
            else:
                skipped += 1
        self.stdout.write(f"phone hashes written: {ok}; skipped (invalid or "
                          f"collision): {skipped}")
