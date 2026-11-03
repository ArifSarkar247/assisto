# aifinal (owner AI order 3 Nov 23:15, PART 2): the AI usage log keeps the
# answer level and the credits given back. Additive only (two columns).
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0150_nearby'),
    ]

    operations = [
        migrations.AddField(
            model_name='aiusage',
            name='level',
            field=models.CharField(blank=True, default='', max_length=10),
        ),
        migrations.AddField(
            model_name='aiusage',
            name='refunded',
            field=models.IntegerField(default=0),
        ),
    ]
