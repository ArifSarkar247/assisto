# cashguard (Smart Cash Guard, owner 28 Oct): owner-away mode on ShopSite +
# the encrypted 24 h event clip (ciphertext only).

import django.db.models.deletion
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0114_veh100'),
    ]

    operations = [
        migrations.AddField(
            model_name='shopsite',
            name='away',
            field=models.JSONField(blank=True, default=dict),
        ),
        migrations.CreateModel(
            name='ShopEventClip',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('blob', models.FileField(blank=True, null=True, upload_to='shop/clip/')),
                ('meta', models.JSONField(blank=True, default=dict)),
                ('size', models.PositiveIntegerField(default=0)),
                ('sha256', models.CharField(blank=True, default='', max_length=64)),
                ('status', models.CharField(choices=[('ready', 'ready'), ('viewed', 'viewed'), ('expired', 'expired')], default='ready', max_length=8)),
                ('created', models.DateTimeField(auto_now_add=True)),
                ('expires_at', models.DateTimeField(db_index=True)),
                ('viewed_at', models.DateTimeField(blank=True, null=True)),
                ('event', models.OneToOneField(on_delete=django.db.models.deletion.CASCADE, related_name='clip', to='core.shopevent')),
            ],
            options={
                'ordering': ['-created'],
                'indexes': [models.Index(fields=['status', 'expires_at'], name='core_shopev_status_685d89_idx')],
            },
        ),
    ]
