# b2-badges: per-user bell / Reminders-tab badge watermarks + rename the seeded
# Discover card "Enhance photo" -> "Photo Studio" (it opens Photo Studio).
# The card is updated ONLY while its title is still the original seed text,
# so an owner edit in the Discover manager is never overwritten.
# The integrator re-chains `dependencies` at merge time.
import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models

SEED_BN, SEED_EN = "ছবি উন্নত করুন", "Enhance photo"
NEW_BN, NEW_EN = "ফটো স্টুডিও", "Photo Studio"


def rename_card(apps, schema_editor):
    DiscoverCard = apps.get_model("core", "DiscoverCard")
    for c in DiscoverCard.objects.filter(key="photo_enhance"):
        fields = []
        if c.title_en == SEED_EN:
            c.title_en = NEW_EN
            fields.append("title_en")
        if c.title_bn == SEED_BN:
            c.title_bn = NEW_BN
            fields.append("title_bn")
        if fields:
            c.save(update_fields=fields)


def unrename_card(apps, schema_editor):
    DiscoverCard = apps.get_model("core", "DiscoverCard")
    for c in DiscoverCard.objects.filter(key="photo_enhance"):
        fields = []
        if c.title_en == NEW_EN:
            c.title_en = SEED_EN
            fields.append("title_en")
        if c.title_bn == NEW_BN:
            c.title_bn = SEED_BN
            fields.append("title_bn")
        if fields:
            c.save(update_fields=fields)


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0055_c3_msg'),
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
    ]

    operations = [
        migrations.CreateModel(
            name='NotifBadgeState',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('badge_cleared_at', models.DateTimeField(blank=True, null=True)),
                ('feed_tab_cleared_at', models.DateTimeField(blank=True, null=True)),
                ('reminders_cleared_at', models.DateTimeField(blank=True, null=True)),
                ('user', models.OneToOneField(on_delete=django.db.models.deletion.CASCADE, related_name='b2_badge_state', to=settings.AUTH_USER_MODEL)),
            ],
        ),
        migrations.RunPython(rename_card, unrename_card),
    ]
