"""c1-contacts — DATA migration: one canonical phone form + backfill hashes.

1. User.phone -> canonical E.164 (core.phone.canonical_phone), e.g.
   01711000777 / 8801711000777 / "+880 1711-000777" -> +8801711000777.
   COLLISIONS (two accounts whose numbers normalise to the same canonical
   value) are NEVER merged or deleted: every account in the group is left
   exactly as it is and reported in the migration output for the owner.
   Unparseable values are left as-is and reported too.
2. CircleMember.phone -> canonical (non-unique field; safe).
3. UserPhoneHash backfill for every account with a canonical phone (same
   HMAC scheme the app uses on device: GET /messenger/contacts/contract).
Usernames are NOT touched (login accepts the phone in any format).
Reverse is a no-op (the canonical form is a valid stored value).
"""
from collections import defaultdict

from django.db import migrations


def forwards(apps, schema_editor):
    from core.phone import (SALT_VERSION, canonical_phone, hash_canonical,
                            match_salt)

    User = apps.get_model("core", "User")
    CircleMember = apps.get_model("core", "CircleMember")
    UserPhoneHash = apps.get_model("core", "UserPhoneHash")

    groups = defaultdict(list)
    invalid = []
    for uid, phone in User.objects.exclude(phone__isnull=True).exclude(
            phone="").values_list("id", "phone"):
        c = canonical_phone(phone)
        if c:
            groups[c].append((uid, phone))
        else:
            invalid.append((uid, phone))

    changed, collisions, ok_users = 0, [], {}
    for canon, rows in groups.items():
        if len(rows) > 1:
            collisions.append((canon, rows))
            continue
        uid, phone = rows[0]
        ok_users[uid] = canon
        if phone != canon:
            User.objects.filter(pk=uid).update(phone=canon)
            changed += 1

    cm_changed = 0
    for mid, phone in CircleMember.objects.exclude(phone="").values_list(
            "id", "phone"):
        c = canonical_phone(phone)
        if c and c != phone:
            CircleMember.objects.filter(pk=mid).update(phone=c)
            cm_changed += 1

    salt = match_salt()
    hashed = 0
    for uid, canon in ok_users.items():
        h = hash_canonical(canon, salt)
        if UserPhoneHash.objects.filter(phone_hash=h).exclude(
                user_id=uid).exists():
            continue
        UserPhoneHash.objects.update_or_create(
            user_id=uid, defaults={"phone_hash": h, "salt_version": SALT_VERSION})
        hashed += 1

    if not (changed or cm_changed or hashed or collisions or invalid):
        return
    print(f"\n  [c1-contacts 0051] users normalised: {changed}; "
          f"circle edges normalised: {cm_changed}; phone hashes written: {hashed}")
    for canon, rows in collisions:
        ids = ", ".join(f"user {uid} ({p!r})" for uid, p in rows)
        print(f"  [c1-contacts 0051] COLLISION {canon}: {ids} — left untouched, "
              f"not matchable until the owner resolves it")
    for uid, phone in invalid:
        print(f"  [c1-contacts 0051] invalid phone kept as-is: user {uid} ({phone!r})")


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0049_d1_discover_cards"),  # integrator re-chains (0049/0050 are other slots)
    ]

    operations = [
        migrations.RunPython(forwards, migrations.RunPython.noop),
    ]
