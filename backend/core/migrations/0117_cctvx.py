# cctvx (CCTV extras, owner 28 Oct): guard settings on ShopSite, opened /
# pending on ShopEvent, the delayed guard steps (no-sale check, escalation)
# and the LAN "siren" gateway task.

import django.db.models.deletion
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0116_tagada2'),
    ]

    operations = [
        migrations.AddField(
            model_name='shopsite',
            name='guard',
            field=models.JSONField(blank=True, default=dict),
        ),
        migrations.AddField(
            model_name='shopevent',
            name='opened_at',
            field=models.DateTimeField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name='shopevent',
            name='pending',
            field=models.BooleanField(default=False),
        ),
        migrations.AlterField(
            model_name='shopgatewaytask',
            name='action',
            field=models.CharField(choices=[('discover', 'discover'), ('check', 'check'), ('siren', 'siren')], max_length=10),
        ),
        migrations.CreateModel(
            name='ShopGuardTask',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('kind', models.CharField(choices=[('nosale', 'no-sale check'), ('escalate', 'escalation'), ('siren_off', 'siren off')], max_length=12)),
                ('due_at', models.DateTimeField(db_index=True)),
                ('done', models.BooleanField(db_index=True, default=False)),
                ('state', models.JSONField(blank=True, default=dict)),
                ('created', models.DateTimeField(auto_now_add=True)),
                ('event', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.CASCADE, related_name='guard_tasks', to='core.shopevent')),
                ('site', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='guard_tasks', to='core.shopsite')),
            ],
            options={
                'ordering': ['due_at', 'id'],
            },
        ),
    ]
