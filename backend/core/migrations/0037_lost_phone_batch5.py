# Anti-theft Batch 5 — lost/stolen server-side (heartbeat, went-dark,
# lost-mode, store-and-forward). Hand-written to match core/models.py exactly
# so `makemigrations --dry-run` reports "No changes detected".

import django.db.models.deletion
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0036_batch4_registry_transfer'),
    ]

    operations = [
        # --- ProtectedPhone: lost-mode + heartbeat fields ---
        migrations.AddField(
            model_name='protectedphone',
            name='lost_mode',
            field=models.BooleanField(default=False),
        ),
        migrations.AddField(
            model_name='protectedphone',
            name='lost_message',
            field=models.TextField(blank=True, default=''),
        ),
        migrations.AddField(
            model_name='protectedphone',
            name='lost_contact',
            field=models.CharField(blank=True, default='', max_length=120),
        ),
        migrations.AddField(
            model_name='protectedphone',
            name='lost_reward',
            field=models.CharField(blank=True, default='', max_length=160),
        ),
        migrations.AddField(
            model_name='protectedphone',
            name='lost_since',
            field=models.DateTimeField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name='protectedphone',
            name='last_heartbeat_at',
            field=models.DateTimeField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name='protectedphone',
            name='last_lat',
            field=models.FloatField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name='protectedphone',
            name='last_lng',
            field=models.FloatField(blank=True, null=True),
        ),
        migrations.AddField(
            model_name='protectedphone',
            name='went_dark_alerted',
            field=models.BooleanField(default=False),
        ),
        migrations.AddField(
            model_name='protectedphone',
            name='heartbeat_interval_min',
            field=models.IntegerField(default=10),
        ),
        # --- PhoneHeartbeat ---
        migrations.CreateModel(
            name='PhoneHeartbeat',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('lat', models.FloatField(blank=True, null=True)),
                ('lng', models.FloatField(blank=True, null=True)),
                ('battery', models.IntegerField(blank=True, null=True)),
                ('network', models.CharField(blank=True, default='', max_length=16)),
                ('at', models.DateTimeField(auto_now_add=True, db_index=True)),
                ('phone', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='heartbeats', to='core.protectedphone')),
            ],
            options={
                'ordering': ['-at'],
            },
        ),
        # --- CapturedEvent (store-and-forward evidence) ---
        migrations.CreateModel(
            name='CapturedEvent',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('kind', models.CharField(choices=[('intruder_photo', 'intruder_photo'), ('sim_change', 'sim_change'), ('failed_unlock', 'failed_unlock'), ('low_battery_loc', 'low_battery_loc'), ('airplane_guard', 'airplane_guard')], max_length=20)),
                ('data', models.JSONField(blank=True, default=dict)),
                ('photo', models.FileField(blank=True, null=True, upload_to='theft/')),
                ('at', models.DateTimeField(blank=True, null=True)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('phone', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='captured_events', to='core.protectedphone')),
            ],
            options={
                'ordering': ['-created_at'],
            },
        ),
    ]
