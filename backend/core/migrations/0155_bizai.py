# bizai (owner 4 Nov 02:05 BUSINESS AI REAL IMPACT): in-app shop chat channel
# ("assisto") for the AI sales agent, its per-shop switch, the COD
# return-risk guard switch and the risk level stamped on each order.
# Additive only (5 new columns with defaults + 2 widened choice lists);
# pillar 5: the tracked post code on chats and orders (Prochar attribution);
# pillar 3: Market bulk tier + negotiation ask on bids.
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0154_recovery'),
    ]

    operations = [
        migrations.AddField(
            model_name='order',
            name='cod_risk',
            field=models.CharField(blank=True, default='', max_length=8),
        ),
        migrations.AddField(
            model_name='selleragent',
            name='app_chat_enabled',
            field=models.BooleanField(default=True),
        ),
        migrations.AddField(
            model_name='selleragent',
            name='cod_risk_guard',
            field=models.BooleanField(default=True),
        ),
        migrations.AddField(
            model_name='order',
            name='source_ref',
            field=models.CharField(blank=True, db_index=True, default='', max_length=12),
        ),
        migrations.AddField(
            model_name='chatthread',
            name='source_ref',
            field=models.CharField(blank=True, default='', max_length=12),
        ),
        migrations.AddField(
            model_name='marketbid', name='bulk_price',
            field=models.BigIntegerField(blank=True, null=True)),
        migrations.AddField(
            model_name='marketbid', name='bulk_min_qty',
            field=models.PositiveIntegerField(default=0)),
        migrations.AddField(
            model_name='marketbid', name='counter_price',
            field=models.BigIntegerField(blank=True, null=True)),
        migrations.AddField(
            model_name='marketbid', name='counter_at',
            field=models.DateTimeField(blank=True, null=True)),
        migrations.AlterField(
            model_name='chatthread',
            name='channel',
            field=models.CharField(choices=[('whatsapp_cloud', 'whatsapp_cloud'), ('messenger', 'messenger'), ('instagram', 'instagram'), ('website', 'website'), ('assisto', 'assisto')], default='whatsapp_cloud', max_length=20),
        ),
        migrations.AlterField(
            model_name='sellerchannel',
            name='kind',
            field=models.CharField(choices=[('messenger', 'messenger'), ('instagram', 'instagram'), ('whatsapp_cloud', 'whatsapp_cloud'), ('website', 'website'), ('assisto', 'assisto')], max_length=16),
        ),
    ]
