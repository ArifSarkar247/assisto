"""srvperf — realistic synthetic data for query-count tests and the CI load
test (never run against the live database: the `loadtest_seed` command
refuses unless LOADTEST_ALLOW_SEED=1, which only the CI workflow sets).

Shape per user (defaults mirror a heavy real My Circle user):
  - `peers` accepted 1:1 circle edges (both directions, like a real connect)
  - `msgs` messages per conversation (half from each side, some with receipts)
  - membership in `groups` groups of `group_size` with `group_msgs` messages
  - reminders, a cash account with transactions, family alerts, a push device
All bodies are opaque fake ciphertext (the server never sees plaintext).
"""
import random
from datetime import timedelta
from decimal import Decimal

from django.contrib.auth.hashers import make_password
from django.utils import timezone

PHONE_BASE = 1900000000  # 019xxxxxxxx — a block no real seed uses
PASSWORD = "loadtest-pw-1"


def phone_of(i):
    return "0%d" % (PHONE_BASE + i)


def make_users(n, start=0):
    """n users with tokens. Returns [(user, token_key)] in index order."""
    from rest_framework.authtoken.models import Token
    from .models import User
    pw = make_password(PASSWORD)
    rows = [User(username=phone_of(start + i), phone=phone_of(start + i),
                 name="LT User %d" % (start + i), language="bn", password=pw)
            for i in range(n)]
    User.objects.bulk_create(rows, batch_size=500)
    users = list(User.objects.filter(
        phone__in=[r.phone for r in rows]).order_by("id"))
    Token.objects.bulk_create([Token(user=u, key=Token.generate_key())
                               for u in users], batch_size=500)
    toks = dict(Token.objects.filter(user__in=users).values_list("user_id", "key"))
    return [(u, toks[u.id]) for u in users]


def connect(a, b):
    """Accepted 1:1 edge pair a<->b (what connect-flow leaves behind)."""
    from .models import CircleMember
    now = timezone.now()
    ab = CircleMember(user=a, peer_user=b, name=b.name, phone=b.phone,
                      state="accepted", direction="outgoing", connected_at=now)
    ba = CircleMember(user=b, peer_user=a, name=a.name, phone=a.phone,
                      state="accepted", direction="incoming", connected_at=now)
    return ab, ba


def seed_world(users, peers=8, msgs=12, groups=2, group_size=6, group_msgs=20,
               reminders=5, txns=10, rng=None):
    """Fill circles/chats/groups/reminders/ledger for `users` (list of User).
    Bulk inserts only; returns a dict of counts."""
    from .models import (Account, CircleGroup, CircleGroupMember,
                         CircleMember, CircleMessage, Device,
                         FamilyAlert, Reminder, Transaction, UserPublicKey)
    rng = rng or random.Random(7)
    n = len(users)
    now = timezone.now()
    # ---- 1:1 edges: a ring + random chords so every user has ~`peers`
    pairs = set()
    for i in range(n):
        for k in range(1, peers // 2 + 1):
            j = (i + k) % n
            if i != j:
                pairs.add((min(i, j), max(i, j)))
    edges = []
    for i, j in sorted(pairs):
        edges.extend(connect(users[i], users[j]))
    CircleMember.objects.bulk_create(edges, batch_size=1000)
    edges = list(CircleMember.objects.filter(
        user__in=users).order_by("id"))
    UserPublicKey.objects.bulk_create(
        [UserPublicKey(user=u, public_key="pk%d" % u.id, key_id="k%d" % u.id)
         for u in users], batch_size=1000, ignore_conflicts=True)
    # ---- 1:1 messages: on the outgoing edge, both senders
    out_msgs = []
    for e in edges:
        if e.direction != "outgoing":
            continue
        for m in range(msgs):
            sender = e.user_id if m % 2 == 0 else e.peer_user_id
            out_msgs.append(CircleMessage(
                member=e, sender_id=sender, ciphertext="Q1Q=" * 8,
                nonce="Tg==", client_msg_id="lt-%d-%d" % (e.id, m)))
    CircleMessage.objects.bulk_create(out_msgs, batch_size=1000)
    # ---- groups
    grp_rows, gmembers = [], []
    for g in range(max(0, (n * groups) // max(1, group_size))):
        creator = users[rng.randrange(n)]
        grp_rows.append(CircleGroup(creator=creator, name="LT group %d" % g))
    CircleGroup.objects.bulk_create(grp_rows, batch_size=500)
    grps = list(CircleGroup.objects.filter(name__startswith="LT group ")
                .order_by("id"))
    for gi, g in enumerate(grps):
        start = (gi * group_size) % n
        mem = {g.creator_id}
        for k in range(group_size - 1):
            mem.add(users[(start + k) % n].id)
        for uid in mem:
            gmembers.append(CircleGroupMember(
                group=g, member_id=uid,
                role="admin" if uid == g.creator_id else "member"))
    CircleGroupMember.objects.bulk_create(gmembers, batch_size=1000,
                                          ignore_conflicts=True)
    gm_by_group = {}
    for gm in CircleGroupMember.objects.filter(group__in=grps):
        gm_by_group.setdefault(gm.group_id, []).append(gm)
    gmsgs = []
    for g in grps:
        gms = gm_by_group.get(g.id, [])
        if not gms:
            continue
        for m in range(group_msgs):
            s = gms[m % len(gms)]
            rec = [x.id for x in gms if x.id != s.id]
            gmsgs.append(CircleMessage(
                group=g, sender_id=s.member_id, recipient_ids=rec,
                per_recipient={str(r): {"ciphertext": "Q1Q=", "nonce": "Tg=="}
                               for r in rec},
                ciphertext="", nonce="", client_msg_id="ltg-%d-%d" % (g.id, m)))
    CircleMessage.objects.bulk_create(gmsgs, batch_size=1000)
    # receipts are left to the app's own sync (the load test exercises it)
    # ---- reminders, ledger, alerts, devices
    Reminder.objects.bulk_create(
        [Reminder(user=u, title="LT reminder %d" % r,
                  due_at=now + timedelta(hours=r + 1))
         for u in users for r in range(reminders)], batch_size=1000)
    Account.objects.bulk_create(
        [Account(user=u, name="Cash", acc_type="cash",
                 opening_balance=Decimal("1000")) for u in users],
        batch_size=1000)
    accs = {a.user_id: a for a in Account.objects.filter(user__in=users)}
    today = now.date()
    Transaction.objects.bulk_create(
        [Transaction(user=u, account=accs[u.id], kind="expense",
                     amount=Decimal(rng.randint(10, 900)), category="food",
                     date=today - timedelta(days=t % 30))
         for u in users for t in range(txns)], batch_size=1000)
    FamilyAlert.objects.bulk_create(
        [FamilyAlert(user=u, kind="checkin_overdue", title="LT", body="LT",
                     severity="info") for u in users[::5]], batch_size=1000)
    Device.objects.bulk_create(
        [Device(user=u, push_token="lt-token-%d" % u.id) for u in users],
        batch_size=1000, ignore_conflicts=True)
    return {"users": n, "edges": len(edges), "messages": len(out_msgs),
            "groups": len(grps), "group_messages": len(gmsgs)}
