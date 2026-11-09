# cctvroles (CCTV Guard V3 I + J): staff role, audit detail + new audit
# actions, installer partners and the owner's installer invites.
import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', "0158_cctvconnect"),
    ]

    operations = [
        migrations.AlterField(
            model_name='shopsiteviewer',
            name='role',
            field=models.CharField(choices=[('family', 'family'), ('manager', 'manager'), ('guard', 'guard'), ('staff', 'staff')], default='family', max_length=8),
        ),
        migrations.AlterField(
            model_name='cctvaccesslog',
            name='action',
            field=models.CharField(choices=[('alerts', 'alert list'), ('alert', 'one alert / clip / evidence'), ('still', 'camera photo'), ('live', 'live view'), ('link', 'share link opened'), ('export', 'evidence exported'), ('share', 'clip or link shared'), ('change', 'setting changed'), ('delete', 'something deleted'), ('role', 'role changed'), ('installer', 'installer step')], max_length=10),
        ),
        migrations.AddField(
            model_name='cctvaccesslog',
            name='detail',
            field=models.CharField(blank=True, default='', max_length=120),
        ),
        migrations.CreateModel(
            name='CctvPartner',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('name', models.CharField(blank=True, default='', max_length=80)),
                ('area', models.CharField(blank=True, default='', max_length=80)),
                ('status', models.CharField(choices=[('pending', 'pending'), ('approved', 'approved'), ('suspended', 'suspended')], default='pending', max_length=10)),
                ('created', models.DateTimeField(auto_now_add=True)),
                ('decided_at', models.DateTimeField(blank=True, null=True)),
                ('user', models.OneToOneField(on_delete=django.db.models.deletion.CASCADE, related_name='cctv_partner', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'ordering': ['-created'],
            },
        ),
        migrations.CreateModel(
            name='CctvInstallerLink',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('code_hash', models.CharField(max_length=64, unique=True)),
                ('status', models.CharField(choices=[('invited', 'invited'), ('active', 'active'), ('ended', 'ended')], default='invited', max_length=8)),
                ('created', models.DateTimeField(auto_now_add=True)),
                ('expires_at', models.DateTimeField()),
                ('accepted_at', models.DateTimeField(blank=True, null=True)),
                ('ended_at', models.DateTimeField(blank=True, null=True)),
                ('partner', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.CASCADE, related_name='links', to='core.cctvpartner')),
                ('site', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='installer_links', to='core.shopsite')),
            ],
            options={
                'ordering': ['-created'],
                'indexes': [models.Index(fields=['site', 'status'], name='cctv_inst_site_idx')],
            },
        ),
    ]
