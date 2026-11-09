# discms (owner 10 Nov 01:53): Discover card types "What's new" and "Offer".
# Choices only: no table / column change.
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0164_cctvdet'),
    ]

    operations = [
        migrations.AlterField(
            model_name='discovercard',
            name='type',
            field=models.CharField(choices=[('FEATURE', 'Feature'), ('OUR_PRODUCT', 'Our product'), ('SPONSORED', 'Sponsored'), ('ADMOB', 'AdMob slot'), ('WHATS_NEW', "What's new"), ('OFFER', 'Offer')], default='FEATURE', max_length=12),
        ),
    ]
