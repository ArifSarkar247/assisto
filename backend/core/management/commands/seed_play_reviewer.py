"""Create / refresh the Google Play REVIEWER demo account (idempotent).

Reads everything secret from the server environment (backend .env, never git):
  PLAY_REVIEWER_PHONE     fixed demo number (non-real 010… test range)
  PLAY_REVIEWER_PASSWORD  its password
  PLAY_REVIEWER_OTP       fixed 6-digit login code (used by core.otp)
  PLAY_REVIEWER_PEER_ID   optional: user id of a test account to add to My Circle

Seeds realistic SAMPLE data only (no real person's data): reminders, notes,
to-dos, a cash + bKash account with income/expenses, Premium for 1 year, and an
accepted My Circle connection with the test account.

    python manage.py seed_play_reviewer
"""
import os
from datetime import timedelta
from decimal import Decimal

from django.core.management.base import BaseCommand, CommandError
from django.db import transaction
from django.utils import timezone

NAME = "Play Reviewer"


class Command(BaseCommand):
    help = "Create/refresh the Play reviewer demo account from server env."

    @transaction.atomic
    def handle(self, *args, **opts):
        from core.models import (User, Reminder, Note, Todo, Account, Transaction,
                                 CircleMember)
        from core import otp

        phone = os.environ.get("PLAY_REVIEWER_PHONE", "")
        password = os.environ.get("PLAY_REVIEWER_PASSWORD", "")
        canon = otp.reviewer_canon()
        if not canon or len(password) < 12:
            raise CommandError("Set PLAY_REVIEWER_PHONE (01…, 11 digits) and "
                               "PLAY_REVIEWER_PASSWORD (12+ chars) in the server .env")

        user = otp.find_user_by_phone(canon) or User.objects.filter(phone=phone).first()
        if user is None:
            user = User.objects.create_user(name=NAME, phone=phone, password=password)
            created = True
        else:
            created = False
            user.name = NAME
            user.set_password(password)
        now = timezone.now()
        user.is_active = True
        user.plan = "premium"
        user.plan_until = now + timedelta(days=365)
        user.save()

        # Sample data (replaced on every run so it always looks fresh).
        Reminder.objects.filter(user=user).delete()
        Note.objects.filter(user=user).delete()
        Todo.objects.filter(user=user).delete()
        Transaction.objects.filter(user=user).delete()
        Account.objects.filter(user=user).delete()

        day = now.replace(hour=9, minute=0, second=0, microsecond=0)
        for title, delta, notes in [
            ("Pay electricity bill", timedelta(days=1, hours=2), "DESCO prepaid meter"),
            ("Doctor appointment", timedelta(days=3, hours=8), "Bring last prescription"),
            ("Call Mum", timedelta(hours=10), ""),
            ("Renew mobile data pack", timedelta(days=6), "10 GB monthly"),
        ]:
            Reminder.objects.create(user=user, title=title, notes=notes, due_at=day + delta)
        Note.objects.create(user=user, title="Shopping list",
                            body="Rice 5 kg\nLentils 1 kg\nOnion 2 kg\nEggs 12\nMilk 1 L",
                            pinned=True)
        Note.objects.create(user=user, title="Trip ideas",
                            body="Cox's Bazar in December\nSylhet tea gardens\nSajek Valley")
        Note.objects.create(user=user, title="Meeting notes",
                            body="Budget review on Sunday. Send the report by Thursday.")
        for title, done in [("Buy birthday gift", False), ("Clean the room", True),
                            ("Submit office report", False)]:
            Todo.objects.create(user=user, title=title, done=done,
                                due_at=day + timedelta(days=2) if not done else None)

        cash = Account.objects.create(user=user, name="Cash", acc_type="cash",
                                      opening_balance=Decimal("5000"))
        bkash = Account.objects.create(user=user, name="bKash", acc_type="bkash",
                                       opening_balance=Decimal("2500"))
        today = now.date()
        for acc, kind, amount, cat, note, ago in [
            (bkash, "income", "35000", "Salary", "October salary", 20),
            (cash, "expense", "850", "Food", "Groceries", 6),
            (cash, "expense", "120", "Transport", "Rickshaw + bus", 5),
            (bkash, "expense", "1450", "Bills", "Electricity bill", 4),
            (cash, "expense", "300", "Food", "Tea and snacks", 3),
            (bkash, "expense", "499", "Bills", "Mobile recharge", 2),
            (cash, "expense", "2200", "Shopping", "Shirt", 1),
            (cash, "income", "1500", "Other", "Sold old books", 1),
        ]:
            Transaction.objects.create(user=user, account=acc, kind=kind,
                                       amount=Decimal(amount), category=cat, note=note,
                                       date=today - timedelta(days=ago))

        peer_note = "no My Circle peer (PLAY_REVIEWER_PEER_ID not set)"
        peer_id = os.environ.get("PLAY_REVIEWER_PEER_ID", "").strip()
        if peer_id:
            peer = User.objects.filter(id=int(peer_id), is_active=True).first()
            if peer is None:
                raise CommandError(f"PLAY_REVIEWER_PEER_ID={peer_id}: no active user")
            CircleMember.objects.update_or_create(
                user=user, peer_user=peer,
                defaults={"name": peer.name, "relation": "friend",
                          "direction": "outgoing", "state": "accepted",
                          "phone": peer.phone or ""})
            CircleMember.objects.update_or_create(
                user=peer, peer_user=user,
                defaults={"name": NAME, "relation": "friend",
                          "direction": "incoming", "state": "accepted",
                          "phone": user.phone or ""})
            peer_note = f"My Circle: connected with test account id {peer.id}"

        self.stdout.write(self.style.SUCCESS(
            f"{'created' if created else 'refreshed'} Play reviewer id={user.id}; "
            f"premium until {user.plan_until.date()}; {peer_note}"))
