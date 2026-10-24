# e-gaps (order E): view-once media flag + opened time on 1:1 messages.
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0076_p5_growth'),
    ]

    operations = [
        migrations.AddField(
            model_name='circlemessage',
            name='view_once',
            field=models.BooleanField(default=False),
        ),
        migrations.AddField(
            model_name='circlemessage',
            name='view_once_opened_at',
            field=models.DateTimeField(blank=True, null=True),
        ),
    ]
