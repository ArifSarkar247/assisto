# channels (2 Nov): channel directory + invite codes, channel block, community
# invite code, community group -> E2E circle group, a default Discover card.
import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


def seed_discover(apps, schema_editor):
    """Add the 'Channels & Communities' Discover card ONLY if the key is new
    (the owner can edit/disable it in Owner Admin -> Discover manager). Older
    app builds hide it on their own (unknown in-app route)."""
    DiscoverCard = apps.get_model("core", "DiscoverCard")
    if DiscoverCard.objects.filter(key="circle_channels").exists():
        return
    DiscoverCard.objects.create(
        key="circle_channels", type="FEATURE",
        title_bn="চ্যানেল ও কমিউনিটি",
        title_en="Channels & communities",
        desc_bn="পছন্দের চ্যানেল খুঁজে ফলো করুন, নিজের কমিউনিটি বানান",
        desc_en="Find and follow channels, start your own community",
        icon="campaign", route="channels", order=60, enabled=True,
        audience="all")


def unseed_discover(apps, schema_editor):
    pass


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0137_homeorder"),
    ]

    operations = [
        migrations.AddField(
            model_name="channel", name="is_public",
            field=models.BooleanField(default=False)),
        migrations.AddField(
            model_name="channel", name="invite_code",
            field=models.CharField(blank=True, db_index=True, default="",
                                   max_length=16)),
        migrations.AddField(
            model_name="channel", name="content_status",
            field=models.CharField(default="visible", max_length=10)),
        migrations.AddField(
            model_name="community", name="invite_code",
            field=models.CharField(blank=True, db_index=True, default="",
                                   max_length=16)),
        migrations.AddField(
            model_name="communitygroup", name="circle_group",
            field=models.ForeignKey(
                blank=True, null=True,
                on_delete=django.db.models.deletion.SET_NULL,
                related_name="community_groups", to="core.circlegroup")),
        migrations.CreateModel(
            name="ChannelBlock",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True,
                                           serialize=False, verbose_name="ID")),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("channel", models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name="blocks", to="core.channel")),
                ("user", models.ForeignKey(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name="channel_blocks",
                    to=settings.AUTH_USER_MODEL)),
            ],
            options={"unique_together": {("channel", "user")}},
        ),
        migrations.RunPython(seed_discover, unseed_discover),
    ]
