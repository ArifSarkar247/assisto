# viewonce (owner My Circle order 3 Nov 16:30, part G): view-once for photo /
# video / voice in 1:1 AND groups. Per-recipient open times (each group
# member opens once), an "expired unopened" time (server copy deleted after
# 14 days), and an index on view_once so the per-minute purge is cheap.
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0146_p3docs'),
    ]

    operations = [
        migrations.AlterField(
            model_name='circlemessage',
            name='view_once',
            field=models.BooleanField(default=False, db_index=True),
        ),
        migrations.AddField(
            model_name='circlemessage',
            name='view_once_opens',
            field=models.JSONField(blank=True, default=dict),
        ),
        migrations.AddField(
            model_name='circlemessage',
            name='view_once_expired_at',
            field=models.DateTimeField(blank=True, null=True),
        ),
    ]
