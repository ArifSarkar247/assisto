# cctvalerts (W3 smart alert types): two new ShopEvent types. Choices only —
# no column change, no data change.
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0139_ledger2'),
    ]

    operations = [
        migrations.AlterField(
            model_name='shopevent',
            name='type',
            field=models.CharField(choices=[('hand_in_cash_zone', 'hand in cash zone'), ('drawer_open', 'drawer open'), ('void_spike', 'void spike'), ('refund_spike', 'refund spike'), ('discount_spike', 'discount spike'), ('eod_mismatch', 'end-of-day mismatch'), ('motion', 'motion'), ('after_hours', 'after hours'), ('pose_possible', 'pose (possible)'), ('person_detected', 'person seen while armed'), ('zone_intrusion', 'restricted zone entered'), ('line_crossing', 'entry line crossed'), ('camera_alarm', "camera's own alarm"), ('loitering', 'loitering at night'), ('camera_health', 'camera covered / moved / dark / SD')], max_length=20),
        ),
    ]
