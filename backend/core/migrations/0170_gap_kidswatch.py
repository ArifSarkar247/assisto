# gap-kidswatch (17 Nov): the kids watch's own SIM number (one-tap "Call the
# watch" for guardians). Additive only.
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0169_emailrel'),
    ]

    operations = [
        migrations.AddField(
            model_name='kidswatch',
            name='sim_phone',
            field=models.CharField(blank=True, default='', max_length=20),
        ),
    ]
