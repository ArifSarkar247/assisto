import django.utils.timezone
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0101_antitheft2_location_routing'),
    ]

    operations = [
        migrations.CreateModel(
            name='JobHeartbeat',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('name', models.CharField(max_length=48, unique=True)),
                ('last_start', models.DateTimeField(blank=True, null=True)),
                ('last_finish', models.DateTimeField(blank=True, null=True)),
                ('last_ok', models.DateTimeField(blank=True, null=True)),
                ('last_rc', models.IntegerField(blank=True, null=True)),
                ('last_duration_ms', models.IntegerField(blank=True, null=True)),
                ('last_error', models.CharField(blank=True, default='', max_length=200)),
                ('running', models.BooleanField(default=False)),
                ('runs_ok', models.PositiveIntegerField(default=0)),
                ('runs_failed', models.PositiveIntegerField(default=0)),
                ('fails_in_row', models.PositiveIntegerField(default=0)),
            ],
            options={'ordering': ['name']},
        ),
        migrations.CreateModel(
            name='OpsAlertState',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('key', models.CharField(max_length=64, unique=True)),
                ('bad', models.BooleanField(default=False)),
                ('bad_count', models.PositiveIntegerField(default=0)),
                ('detail', models.CharField(blank=True, default='', max_length=300)),
                ('first_seen', models.DateTimeField(default=django.utils.timezone.now)),
                ('since', models.DateTimeField(blank=True, null=True)),
                ('alerted_at', models.DateTimeField(blank=True, null=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
            ],
            options={'ordering': ['key']},
        ),
    ]
