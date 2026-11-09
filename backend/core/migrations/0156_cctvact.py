# cctvact (owner CCTV GUARD V3 9 Nov, parts D + F): partner POS events
# (source, ext_id unique per site + source = replay-safe, meta) and the
# Guard Box / phone-camera "play" task (siren / owner's warning).
# Additive only: 3 new columns with defaults, 1 partial unique constraint,
# 1 widened choice list.
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0155_bizai'),
    ]

    operations = [
        migrations.AddField(
            model_name='shopposevent',
            name='source',
            field=models.CharField(blank=True, default='', max_length=12),
        ),
        migrations.AddField(
            model_name='shopposevent',
            name='ext_id',
            field=models.CharField(blank=True, default='', max_length=64),
        ),
        migrations.AddField(
            model_name='shopposevent',
            name='meta',
            field=models.JSONField(blank=True, default=dict),
        ),
        migrations.AddConstraint(
            model_name='shopposevent',
            constraint=models.UniqueConstraint(
                condition=models.Q(('ext_id', ''), _negated=True),
                fields=('site', 'source', 'ext_id'),
                name='shoppos_site_source_ext_uniq'),
        ),
        migrations.AlterField(
            model_name='shopgatewaytask',
            name='action',
            field=models.CharField(choices=[('discover', 'discover'), ('check', 'check'), ('siren', 'siren'), ('play', 'play sound')], max_length=10),
        ),
    ]
