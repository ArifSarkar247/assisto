# ring-everywhere: per-call FCM delivery tracking (fcm_sent_at / fcm_msg_id /
# delivered_at / bounded resends), callee phone brand/model/sdk for the Owner
# Admin delivery table, missed-call-on-reconnect flag; Device brand/model/sdk.
# The integrator re-chains `dependencies`.
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0082_e2e_groups"),
    ]

    operations = [
        migrations.AddField("callsession", "fcm_sent_at",
                            models.DateTimeField(blank=True, null=True)),
        migrations.AddField("callsession", "fcm_msg_id",
                            models.CharField(blank=True, default="", max_length=160)),
        migrations.AddField("callsession", "delivered_at",
                            models.DateTimeField(blank=True, null=True)),
        migrations.AddField("callsession", "push_resends",
                            models.PositiveSmallIntegerField(default=0)),
        migrations.AddField("callsession", "last_push_at",
                            models.DateTimeField(blank=True, null=True)),
        migrations.AddField("callsession", "callee_brand",
                            models.CharField(blank=True, default="", max_length=32)),
        migrations.AddField("callsession", "callee_model",
                            models.CharField(blank=True, default="", max_length=48)),
        migrations.AddField("callsession", "callee_sdk",
                            models.PositiveSmallIntegerField(default=0)),
        migrations.AddField("callsession", "missed_pending",
                            models.BooleanField(default=False)),
        migrations.AddField("device", "brand",
                            models.CharField(blank=True, default="", max_length=32)),
        migrations.AddField("device", "model",
                            models.CharField(blank=True, default="", max_length=48)),
        migrations.AddField("device", "sdk_int",
                            models.PositiveSmallIntegerField(default=0)),
    ]
