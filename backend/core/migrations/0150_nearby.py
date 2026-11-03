# nearby (owner 3 Nov 18:50): Assisto's own emergency place list (OSM extract
# + owner overrides), the "report wrong number" queue and per-country dataset
# versions. Additive only (three new tables).
import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0149_guardian2'),
    ]

    operations = [
        migrations.CreateModel(
            name='NearbyPlace',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('country', models.CharField(db_index=True, max_length=2)),
                ('category', models.CharField(max_length=12)),
                ('source', models.CharField(default='osm', max_length=12)),
                ('src_id', models.CharField(blank=True, default='', max_length=24)),
                ('name', models.CharField(blank=True, default='', max_length=160)),
                ('name_en', models.CharField(blank=True, default='', max_length=160)),
                ('lat', models.FloatField()),
                ('lon', models.FloatField()),
                ('phone', models.CharField(blank=True, default='', max_length=40)),
                ('refreshed_at', models.DateTimeField(blank=True, null=True)),
                ('gone_upstream', models.BooleanField(default=False)),
                ('o_name', models.CharField(blank=True, default='', max_length=160)),
                ('o_name_en', models.CharField(blank=True, default='', max_length=160)),
                ('o_phone', models.CharField(blank=True, default='', max_length=40)),
                ('o_lat', models.FloatField(blank=True, null=True)),
                ('o_lon', models.FloatField(blank=True, null=True)),
                ('hidden', models.BooleanField(default=False)),
                ('edited_at', models.DateTimeField(blank=True, null=True)),
                ('sponsored_until', models.DateTimeField(blank=True, null=True)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('business', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.CASCADE, related_name='nearby_listings', to='core.businessprofile')),
                ('edited_by', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'indexes': [models.Index(fields=['lat', 'lon'], name='core_nearby_lat_d0a1f4_idx'), models.Index(fields=['source', 'src_id'], name='core_nearby_source_5b6e2c_idx'), models.Index(fields=['country', 'category'], name='core_nearby_country_8c3d71_idx')],
            },
        ),
        migrations.CreateModel(
            name='NearbyReport',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('kind', models.CharField(default='wrong_number', max_length=16)),
                ('suggested_phone', models.CharField(blank=True, default='', max_length=40)),
                ('note', models.CharField(blank=True, default='', max_length=300)),
                ('status', models.CharField(default='open', max_length=10)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('resolved_at', models.DateTimeField(blank=True, null=True)),
                ('place', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='reports', to='core.nearbyplace')),
                ('user', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'ordering': ['-id'],
                'indexes': [models.Index(fields=['status', 'id'], name='core_nearby_status_4f9e02_idx')],
            },
        ),
        migrations.CreateModel(
            name='NearbyDataset',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('key', models.CharField(max_length=8, unique=True)),
                ('version', models.PositiveIntegerField(default=1)),
                ('records', models.PositiveIntegerField(default=0)),
                ('bytes', models.PositiveIntegerField(default=0)),
                ('sha256', models.CharField(blank=True, default='', max_length=64)),
                ('osm_timestamp', models.CharField(blank=True, default='', max_length=40)),
                ('refreshed_at', models.DateTimeField(blank=True, null=True)),
                ('enabled', models.BooleanField(default=True)),
                ('last_check_at', models.DateTimeField(blank=True, null=True)),
                ('last_error', models.CharField(blank=True, default='', max_length=300)),
            ],
        ),
    ]
