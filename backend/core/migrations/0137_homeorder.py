# homeorder (explicit owner order, 2 Nov 17:35 + 17:40): SOS is the FIRST
# default Discover item, Train tracker the second. These are ordinary
# DiscoverCard rows — SERVER-SIDE DEFAULTS the owner can edit, disable,
# reorder or delete at any time from Owner Admin (/owner/discover or the app's
# Discover manager) with no new app build. Created only when the key does not
# exist yet; never re-created after the owner deletes one.
# Train is shown only while flag `train_tracker` is ON (server + app filter).
from django.db import migrations

SEED = [
    ("sos", "emergency", "emergency_hub",
     "জরুরি SOS", "Emergency SOS",
     "এক চাপে পরিবার ও কাছের মানুষকে সাহায্যের খবর ও লোকেশন পাঠান।",
     "One press sends help and your location to family and close people."),
    ("train_tracker", "train", "train_tracker",
     "ট্রেন ট্র্যাকার", "Train tracker",
     "আপনার ট্রেন এখন কোথায়, কখন পৌঁছাবে — যাত্রীদের লাইভ তথ্যে।",
     "Where your train is now and when it arrives — live from passengers."),
]
KEYS = [s[0] for s in SEED]


def seed(apps, schema_editor):
    Card = apps.get_model("core", "DiscoverCard")
    first = Card.objects.order_by("order").values_list("order", flat=True).first()
    base = (first if first is not None else 10) - 10 * (len(SEED) + 1)
    for i, (key, icon, route, tbn, ten, dbn, den) in enumerate(SEED):
        Card.objects.get_or_create(key=key, defaults=dict(
            type="FEATURE", icon=icon, route=route, url="", title_bn=tbn,
            title_en=ten, desc_bn=dbn, desc_en=den, order=base + 10 * (i + 1),
            enabled=True, audience="all"))


def unseed(apps, schema_editor):
    apps.get_model("core", "DiscoverCard").objects.filter(key__in=KEYS).delete()


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0136_ledger"),
    ]

    operations = [migrations.RunPython(seed, unseed)]
