# placesafe (owner decision 2 Nov): saved places are no longer ALL anti-theft
# safe places. New SavedPlace.theft_safe flag; the data step turns it ON for
# Home and leaves it OFF for School / Office / every other place (existing
# users: this intentionally turns School / Office off — they can switch them
# back on in the saved-place sheet). Agent number 0123 — may be renumbered
# at merge.
from django.db import migrations, models


def home_on(apps, schema_editor):
    SavedPlace = apps.get_model("core", "SavedPlace")
    ids = [p.id for p in SavedPlace.objects.only("id", "label")
           if " ".join(str(p.label or "").split()).lower() == "home"]
    SavedPlace.objects.filter(id__in=ids).update(theft_safe=True)
    SavedPlace.objects.exclude(id__in=ids).update(theft_safe=False)


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0122_kidswatch"),
    ]

    operations = [
        migrations.AddField(
            model_name="savedplace",
            name="theft_safe",
            field=models.BooleanField(default=False),
        ),
        migrations.RunPython(home_on, migrations.RunPython.noop),
    ]
