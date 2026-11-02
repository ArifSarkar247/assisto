# ownerfix (owner fixes 3 Nov 02:55). Placed after the live leaf 0139_ledger2
# — the integrator renumbers if another 0140 lands first.
#
# 1) ONE blood donor feature: a new table BloodSavedDonor ("My saved donors",
#    private to the list's owner) and a DATA copy of every row of the old
#    personal registry (PaCollectionItem collection "blood/donors") into it.
#    Idempotent (one row per legacy_item_id, a re-run copies nothing twice);
#    the old rows are KEPT until a later cleanup, so going back loses nothing
#    (reverse = drop the new table only).
# 2) Discover defaults (owner 2 Nov + Safe Journey final 3 Nov): SOS first,
#    Train tracker, then Live Location and Destination Alarm, then Blood
#    donor, then everything else in the owner's current order. Ordinary
#    DiscoverCard rows the owner can edit / disable / reorder / delete in
#    Owner Admin -> Discover. A card the owner renamed is never overwritten.
from datetime import date

import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models

from core.logic import blood_rules as BR

LIVE = ("live_location", "near_me", "journey",
        "লাইভ লোকেশন", "Live Location",
        "পরিবার দেখে আপনি কোথায়, পৌঁছালে খবর পায়।",
        "Family sees where you are and gets notified when you arrive.")
DEST = ("dest_alarm", "alarm", "dest_alarm",
        "গন্তব্য অ্যালার্ম", "Destination Alarm",
        "নামার জায়গার আগে জাগিয়ে দেয়, নেট ছাড়াও।",
        "Wakes you before your stop, even without internet.")
BLOOD = ("blood_donor", "bloodtype", "blood_panel",
         "রক্তদাতা", "Blood donor",
         "কাছের রক্তদাতা খুঁজুন, জরুরি অনুরোধ পাঠান — সব অ্যাপের ভেতরে।",
         "Find blood donors near you and send an urgent request — all in the app.")
# 0049 seed copy of the old Safe Journey card: renamed only while untouched.
OLD_JOURNEY_TITLES = ("নিরাপদ যাত্রা", "Safe Journey")


def copy_legacy_donors(apps, schema_editor):
    Item = apps.get_model("core", "PaCollectionItem")
    Saved = apps.get_model("core", "BloodSavedDonor")
    today = date.today()
    done = set(Saved.objects.filter(legacy_item_id__isnull=False)
               .values_list("legacy_item_id", flat=True))
    for it in Item.objects.filter(collection=BR.LEGACY_COLLECTION).iterator():
        if it.id in done:
            continue
        Saved.objects.get_or_create(owner_id=it.user_id, legacy_item_id=it.id,
                                    defaults=BR.legacy_to_saved(it.data, today))


def _card(Card, spec):
    key, icon, route, tbn, ten, dbn, den = spec
    return Card(key=key, type="FEATURE", icon=icon, route=route, url="",
                title_bn=tbn, title_en=ten, desc_bn=dbn, desc_en=den,
                enabled=True, audience="all", order=0)


def seed_discover(apps, schema_editor):
    Card = apps.get_model("core", "DiscoverCard")
    cards = list(Card.objects.order_by("order", "id"))
    by_key = {c.key: c for c in cards}
    # Live Location = the Safe Journey hub (route `journey`). Reuse the old
    # Safe Journey card (renamed only while it still has the seed titles);
    # create one only when no card opens that route.
    live = by_key.get("live_location") or by_key.get("journey") or \
        next((c for c in cards if c.route == "journey"), None)
    if live is None:
        live = _card(Card, LIVE)
        live.save()
    elif (live.title_bn, live.title_en) == OLD_JOURNEY_TITLES:
        _, _, _, live.title_bn, live.title_en, live.desc_bn, live.desc_en = LIVE
        live.save()
    picked = [live]
    for spec in (DEST, BLOOD):
        c = by_key.get(spec[0]) or next((x for x in cards if x.route == spec[2]), None)
        if c is None:
            c = _card(Card, spec)
            c.save()
        picked.append(c)
    ids = {c.id for c in picked}
    rest = [c for c in Card.objects.order_by("order", "id") if c.id not in ids]
    lead = [c for c in rest if c.key in ("sos", "train_tracker")]
    lead.sort(key=lambda c: 0 if c.key == "sos" else 1)
    tail = [c for c in rest if c not in lead]
    for n, c in enumerate(lead + picked + tail):
        Card.objects.filter(pk=c.pk).update(order=(n + 1) * 10)


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0139_ledger2"),
    ]

    operations = [
        migrations.CreateModel(
            name="BloodSavedDonor",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("name", models.CharField(max_length=80)),
                ("blood_group", models.CharField(blank=True, default="", max_length=4)),
                ("area_text", models.CharField(blank=True, default="", max_length=60)),
                ("phone", models.CharField(blank=True, default="", max_length=20)),
                ("available", models.BooleanField(default=True)),
                ("last_donation", models.DateField(blank=True, null=True)),
                ("note", models.CharField(blank=True, default="", max_length=200)),
                ("legacy_item_id", models.BigIntegerField(blank=True, null=True)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("updated_at", models.DateTimeField(auto_now=True)),
                ("owner", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="blood_saved", to=settings.AUTH_USER_MODEL)),
            ],
            options={"ordering": ["id"]},
        ),
        migrations.AddConstraint(
            model_name="bloodsaveddonor",
            constraint=models.UniqueConstraint(fields=("owner", "legacy_item_id"),
                                               name="core_bloodsaved_legacy_once"),
        ),
        migrations.RunPython(copy_legacy_donors, migrations.RunPython.noop),
        migrations.RunPython(seed_discover, migrations.RunPython.noop),
    ]
