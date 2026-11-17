# ads-guard (owner 17 Nov): split Google TEST-ad events from real ones in the
# AdMob tuning log. Additive (default False = every old row stays "real").
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0172_flag_antitheft'),
    ]

    operations = [
        migrations.AddField(
            model_name='adplacementstat',
            name='test',
            field=models.BooleanField(default=False),
        ),
        migrations.AlterUniqueTogether(
            name='adplacementstat',
            unique_together={('date', 'placement', 'fmt', 'currency', 'test')},
        ),
    ]
