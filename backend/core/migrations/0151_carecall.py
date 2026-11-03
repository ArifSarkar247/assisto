# carecall (owner order 4 Nov 01:50): Care Call — consent links, schedules and
# per-slot ring ladders. Additive only (three new tables).
import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0150_nearby'),
    ]

    operations = [
        migrations.CreateModel(
            name='CareCall',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('text', models.TextField(blank=True, default='')),
                ('time_hhmm', models.CharField(default='09:00', max_length=5)),
                ('repeat', models.CharField(default='daily', max_length=6)),
                ('days', models.JSONField(blank=True, default=list)),
                ('once_date', models.DateField(blank=True, null=True)),
                ('voice', models.FileField(blank=True, null=True, upload_to='carecall/')),
                ('voice_rev', models.PositiveIntegerField(default=0)),
                ('voice_sec', models.PositiveIntegerField(default=0)),
                ('active', models.BooleanField(default=True)),
                ('next_at', models.DateTimeField(blank=True, db_index=True, null=True)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('receiver', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='carecalls_received', to=settings.AUTH_USER_MODEL)),
                ('setter', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='carecalls_set', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'ordering': ['-id'],
            },
        ),
        migrations.CreateModel(
            name='CareCallLink',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('status', models.CharField(default='pending', max_length=10)),
                ('quiet_start', models.CharField(blank=True, default='', max_length=5)),
                ('quiet_end', models.CharField(blank=True, default='', max_length=5)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('decided_at', models.DateTimeField(blank=True, null=True)),
                ('receiver', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='carecall_links_in', to=settings.AUTH_USER_MODEL)),
                ('setter', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='carecall_links_out', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'unique_together': {('setter', 'receiver')},
            },
        ),
        migrations.CreateModel(
            name='CareCallRing',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('slot', models.CharField(max_length=12)),
                ('scheduled_at', models.DateTimeField()),
                ('status', models.CharField(db_index=True, default='pending', max_length=8)),
                ('due_at', models.DateTimeField(blank=True, db_index=True, null=True)),
                ('attempts', models.PositiveSmallIntegerField(default=0)),
                ('misses', models.PositiveSmallIntegerField(default=0)),
                ('snoozes', models.PositiveSmallIntegerField(default=0)),
                ('last_ring_at', models.DateTimeField(blank=True, null=True)),
                ('answered_at', models.DateTimeField(blank=True, null=True)),
                ('escalated_at', models.DateTimeField(blank=True, null=True)),
                ('late', models.BooleanField(default=False)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('care_call', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='rings', to='core.carecall')),
            ],
            options={
                'ordering': ['-scheduled_at', '-id'],
                'unique_together': {('care_call', 'slot')},
            },
        ),
    ]
