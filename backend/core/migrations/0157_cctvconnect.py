# cctvconnect (CCTV Guard V3 A1 + B, 9 Nov): brand-cloud links per site
# (sealed grant) + DVR health reports + brand-cloud monthly quota use.
# Three new tables, nothing else touched.
from django.db import migrations, models
import django.db.models.deletion
import django.utils.timezone


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0156_citydata'),
    ]

    operations = [
        migrations.CreateModel(
            name='CctvCloudLink',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('provider', models.CharField(db_index=True, max_length=16)),
                ('label', models.CharField(blank=True, default='', max_length=80)),
                ('mode', models.CharField(default='device_code', max_length=12)),
                ('grant_blob', models.TextField(blank=True, default='')),
                ('serials', models.JSONField(blank=True, default=list)),
                ('status', models.CharField(choices=[('active', 'active'), ('error', 'error'), ('revoked', 'revoked')], default='active', max_length=8)),
                ('state', models.JSONField(blank=True, default=dict)),
                ('last_sync', models.DateTimeField(blank=True, null=True)),
                ('last_error', models.CharField(blank=True, default='', max_length=80)),
                ('created', models.DateTimeField(auto_now_add=True)),
                ('revoked_at', models.DateTimeField(blank=True, null=True)),
                ('site', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='cloud_links', to='core.shopsite')),
            ],
            options={
                'ordering': ['created', 'id'],
                'indexes': [models.Index(fields=['provider', 'status'], name='core_cctvcl_prov_st_idx')],
            },
        ),
        migrations.CreateModel(
            name='CctvDvrHealth',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('device', models.CharField(max_length=60)),
                ('source', models.CharField(blank=True, default='', max_length=16)),
                ('report', models.JSONField(blank=True, default=dict)),
                ('evaluation', models.JSONField(blank=True, default=dict)),
                ('alerted', models.JSONField(blank=True, default=dict)),
                ('updated', models.DateTimeField(default=django.utils.timezone.now)),
                ('site', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='dvr_health', to='core.shopsite')),
            ],
            options={
                'ordering': ['device'],
                'constraints': [models.UniqueConstraint(fields=('site', 'device'), name='uniq_cctv_dvr_health')],
            },
        ),
        migrations.CreateModel(
            name='CctvVendorUsage',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('provider', models.CharField(max_length=16)),
                ('month', models.CharField(max_length=7)),
                ('api_calls', models.PositiveIntegerField(default=0)),
                ('messages', models.PositiveIntegerField(default=0)),
                ('traffic_mb', models.FloatField(default=0.0)),
                ('warned', models.JSONField(blank=True, default=dict)),
                ('updated', models.DateTimeField(auto_now=True)),
            ],
            options={
                'constraints': [models.UniqueConstraint(fields=('provider', 'month'), name='uniq_cctv_vendor_usage')],
            },
        ),
    ]
