# citydata (owner 9 Nov 11:45, City Service): transit dataset per city,
# corrections, live reports, crowd fares, night ratings, trip learning.
# Additive only (8 new tables).
import django.db.models.deletion
import django.utils.timezone
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0155_bizai'),
    ]

    operations = [
        migrations.CreateModel(
            name='CityDataset',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('city', models.CharField(max_length=24, unique=True)),
                ('enabled', models.BooleanField(default=True)),
                ('version', models.CharField(blank=True, default='', max_length=40)),
                ('sha256', models.CharField(blank=True, default='', max_length=64)),
                ('blob', models.BinaryField(blank=True, default=b'')),
                ('dir_blob', models.BinaryField(blank=True, default=b'')),
                ('counts', models.JSONField(blank=True, default=dict)),
                ('report', models.JSONField(blank=True, default=dict)),
                ('overrides', models.JSONField(blank=True, default=dict)),
                ('ov_version', models.PositiveIntegerField(default=1)),
                ('imported_at', models.DateTimeField(blank=True, null=True)),
                ('last_check_at', models.DateTimeField(blank=True, null=True)),
                ('last_error', models.CharField(blank=True, default='', max_length=300)),
            ],
        ),
        migrations.CreateModel(
            name='CityCorrection',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('city', models.CharField(default='dhaka', max_length=24)),
                ('target', models.CharField(default='other', max_length=12)),
                ('target_id', models.CharField(blank=True, default='', max_length=80)),
                ('kind', models.CharField(blank=True, default='', max_length=24)),
                ('text', models.CharField(blank=True, default='', max_length=500)),
                ('lat', models.FloatField(blank=True, null=True)),
                ('lon', models.FloatField(blank=True, null=True)),
                ('status', models.CharField(default='open', max_length=10)),
                ('patch', models.JSONField(blank=True, default=dict)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('resolved_at', models.DateTimeField(blank=True, null=True)),
                ('user', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'ordering': ['-id'],
                'indexes': [models.Index(fields=['status', 'id'], name='core_cityfix_status_idx')],
            },
        ),
        migrations.CreateModel(
            name='CityLiveReport',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('city', models.CharField(default='dhaka', max_length=24)),
                ('kind', models.CharField(max_length=16)),
                ('lat', models.FloatField()),
                ('lon', models.FloatField()),
                ('route_id', models.CharField(blank=True, default='', max_length=80)),
                ('count', models.PositiveIntegerField(default=1)),
                ('voters', models.JSONField(blank=True, default=list)),
                ('flags', models.PositiveIntegerField(default=0)),
                ('hidden', models.BooleanField(default=False)),
                ('created_at', models.DateTimeField(default=django.utils.timezone.now)),
                ('last_at', models.DateTimeField(default=django.utils.timezone.now)),
                ('expires_at', models.DateTimeField(db_index=True)),
                ('user', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'ordering': ['-id'],
                'indexes': [models.Index(fields=['city', 'expires_at'], name='core_citylive_exp_idx')],
            },
        ),
        migrations.CreateModel(
            name='CityFareReport',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('city', models.CharField(default='dhaka', max_length=24)),
                ('mode', models.CharField(max_length=12)),
                ('km', models.FloatField()),
                ('paid', models.PositiveIntegerField()),
                ('created_at', models.DateTimeField(default=django.utils.timezone.now)),
                ('user', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'indexes': [models.Index(fields=['city', 'mode', 'created_at'], name='core_cityfare_idx')],
            },
        ),
        migrations.CreateModel(
            name='CityNightRating',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('city', models.CharField(default='dhaka', max_length=24)),
                ('route_id', models.CharField(max_length=80)),
                ('stars', models.PositiveSmallIntegerField()),
                ('created_at', models.DateTimeField(default=django.utils.timezone.now)),
                ('user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='+', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'constraints': [models.UniqueConstraint(fields=('route_id', 'user'), name='core_citynight_uniq')],
            },
        ),
        migrations.CreateModel(
            name='CityTripConsent',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('on', models.BooleanField(default=False)),
                ('changed_at', models.DateTimeField(default=django.utils.timezone.now)),
                ('user', models.OneToOneField(on_delete=django.db.models.deletion.CASCADE, related_name='+', to=settings.AUTH_USER_MODEL)),
            ],
        ),
        migrations.CreateModel(
            name='CityTrip',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('city', models.CharField(default='dhaka', max_length=24)),
                ('anon', models.CharField(db_index=True, max_length=24)),
                ('mode', models.CharField(default='bus', max_length=12)),
                ('points', models.JSONField(blank=True, default=list)),
                ('created_at', models.DateTimeField(db_index=True, default=django.utils.timezone.now)),
                ('processed', models.BooleanField(default=False)),
            ],
        ),
        migrations.CreateModel(
            name='CityLearned',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('city', models.CharField(default='dhaka', max_length=24)),
                ('kind', models.CharField(max_length=10)),
                ('key', models.CharField(max_length=120)),
                ('data', models.JSONField(blank=True, default=dict)),
                ('trips', models.PositiveIntegerField(default=0)),
                ('anons', models.JSONField(blank=True, default=list)),
                ('status', models.CharField(default='reported', max_length=10)),
                ('updated_at', models.DateTimeField(default=django.utils.timezone.now)),
            ],
            options={
                'constraints': [models.UniqueConstraint(fields=('city', 'kind', 'key'), name='core_citylearn_uniq')],
            },
        ),
    ]
