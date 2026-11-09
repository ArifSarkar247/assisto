# cctvdet (CCTV Guard V3 part C): new ShopEvent types — the stage-1 zone
# detections (gate_person, post_empty, gate_open) and the later-stage types
# in ONE migration. Choices only: no table / column change.
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0163_lpcore'),
    ]

    operations = [
        migrations.AlterField(
            model_name='shopevent',
            name='type',
            field=models.CharField(
                choices=[
                    ('hand_in_cash_zone', 'hand in cash zone'),
                    ('drawer_open', 'drawer open'),
                    ('void_spike', 'void spike'),
                    ('refund_spike', 'refund spike'),
                    ('discount_spike', 'discount spike'),
                    ('eod_mismatch', 'end-of-day mismatch'),
                    ('motion', 'motion'),
                    ('after_hours', 'after hours'),
                    ('pose_possible', 'pose (possible)'),
                    ('person_detected', 'person seen while armed'),
                    ('zone_intrusion', 'restricted zone entered'),
                    ('line_crossing', 'entry line crossed'),
                    ('camera_alarm', "camera's own alarm"),
                    ('loitering', 'loitering at night'),
                    ('camera_health', 'camera covered / moved / dark / SD'),
                    ('gate_person', 'person at the shutter / gate'),
                    ('post_empty', 'counter / post left empty'),
                    ('gate_open', 'gate / shutter left open'),
                    ('crowd', 'crowd / queue'),
                    ('vehicle_in_out', 'vehicle in / out'),
                    ('parking_overstay', 'parking overstay'),
                    ('wrong_parking', 'wrong parking'),
                    ('smoke_fire', 'smoke / fire (possible)'),
                    ('fight', 'scuffle (possible)'),
                    ('fall', 'fall (possible)'),
                    ('weapon_review', 'weapon-like object (review only)'),
                    ('loud_sound', 'loudness level (opt-in)'),
                ],
                max_length=20),
        ),
    ]
