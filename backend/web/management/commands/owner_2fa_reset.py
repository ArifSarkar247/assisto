"""Last-resort recovery for the web owner panel: the owner lost BOTH the
authenticator phone and every recovery code. Run on the server shell:

    python manage.py owner_2fa_reset <phone-in-any-format>

Removes the owner's TOTP enrolment and signs out every panel session; the
next login (password) goes straight to a fresh 2FA enrolment. Audited."""
from django.core.management.base import BaseCommand, CommandError


class Command(BaseCommand):
    help = "Reset the web owner panel 2FA for a superuser (lost phone + codes)."

    def add_arguments(self, parser):
        parser.add_argument("phone")

    def handle(self, *args, **opts):
        from core.models import OwnerAudit, OwnerSession, OwnerTOTP
        from web.owner.views_auth import _find_user
        u = _find_user(opts["phone"])
        if u is None or not u.is_superuser:
            raise CommandError("no superuser with that phone")
        n = OwnerTOTP.objects.filter(user=u).delete()[0]
        s = OwnerSession.objects.filter(user=u).delete()[0]
        OwnerAudit.objects.create(actor=u, action="security.reset_2fa_cli",
                                  target="user:%s" % u.pk,
                                  after={"totp_removed": bool(n), "sessions": s},
                                  ip="server-shell")
        self.stdout.write("2FA reset for user #%s; %s session(s) signed out. "
                          "Next login will enrol a new authenticator." % (u.pk, s))
