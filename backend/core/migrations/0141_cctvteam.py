# cctvteam (W11): viewer roles + per-camera allow-list, a camera's latest
# still, share links, the access log, private neighbourhood watch.
# Additive only (new columns with defaults + new tables); no data change.
# On merge: re-chain the dependency to the latest leaf.

import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0140_cctvalerts'),
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
    ]

    operations = [
        migrations.AddField(
            model_name='shopsiteviewer',
            name='role',
            field=models.CharField(choices=[('family', 'family'), ('manager', 'manager'), ('guard', 'guard')], default='family', max_length=8),
        ),
        migrations.AddField(
            model_name='shopsiteviewer',
            name='cameras',
            field=models.JSONField(blank=True, default=list),
        ),
        migrations.AddField(
            model_name='shopsiteviewer',
            name='live_ok',
            field=models.BooleanField(default=False),
        ),
        migrations.AddField(
            model_name='shopcamera',
            name='still',
            field=models.ImageField(blank=True, null=True, upload_to='shop/still/'),
        ),
        migrations.AddField(
            model_name='shopcamera',
            name='still_at',
            field=models.DateTimeField(blank=True, null=True),
        ),
        migrations.CreateModel(
            name='CctvShareLink',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('token_hash', models.CharField(max_length=64, unique=True)),
                ('label', models.CharField(blank=True, default='', max_length=40)),
                ('cameras', models.JSONField(blank=True, default=list)),
                ('expires_at', models.DateTimeField()),
                ('revoked_at', models.DateTimeField(blank=True, null=True)),
                ('views', models.PositiveIntegerField(default=0)),
                ('last_view_at', models.DateTimeField(blank=True, null=True)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('created_by', models.ForeignKey(null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to=settings.AUTH_USER_MODEL)),
                ('site', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='share_links', to='core.shopsite')),
            ],
            options={
                'ordering': ['-created_at'],
                'indexes': [models.Index(fields=['site', '-created_at'], name='cctv_share_site_idx')],
            },
        ),
        migrations.CreateModel(
            name='CctvAccessLog',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('action', models.CharField(choices=[('alerts', 'alert list'), ('alert', 'one alert / clip / evidence'), ('still', 'camera photo'), ('live', 'live view'), ('link', 'share link opened')], max_length=8)),
                ('created', models.DateTimeField(auto_now_add=True, db_index=True)),
                ('camera', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to='core.shopcamera')),
                ('link', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to='core.cctvsharelink')),
                ('site', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='access_logs', to='core.shopsite')),
                ('user', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'ordering': ['-created'],
                'indexes': [models.Index(fields=['site', '-created'], name='cctv_access_site_idx')],
            },
        ),
        migrations.CreateModel(
            name='CctvWatchPost',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('image', models.ImageField(blank=True, null=True, upload_to='cctvwatch/')),
                ('caption', models.CharField(blank=True, default='', max_length=200)),
                ('created', models.DateTimeField(auto_now_add=True)),
                ('expires_at', models.DateTimeField(db_index=True)),
                ('removed', models.BooleanField(default=False)),
                ('removed_reason', models.CharField(blank=True, default='', max_length=10)),
                ('author', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='cctv_watch_posts', to=settings.AUTH_USER_MODEL)),
                ('group', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='cctv_watch_posts', to='core.communitygroup')),
            ],
            options={
                'ordering': ['-created'],
                'indexes': [models.Index(fields=['group', '-created'], name='cctv_watch_group_idx')],
            },
        ),
        migrations.CreateModel(
            name='CctvWatchReport',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('reason', models.CharField(default='other', max_length=12)),
                ('created', models.DateTimeField(auto_now_add=True)),
                ('post', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='reports', to='core.cctvwatchpost')),
                ('reporter', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='+', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'constraints': [models.UniqueConstraint(fields=('post', 'reporter'), name='uniq_cctv_watch_report')],
            },
        ),
        migrations.CreateModel(
            name='CctvWatchBlock',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('created', models.DateTimeField(auto_now_add=True)),
                ('blocked', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='+', to=settings.AUTH_USER_MODEL)),
                ('blocker', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='cctv_watch_blocks', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'constraints': [models.UniqueConstraint(fields=('blocker', 'blocked'), name='uniq_cctv_watch_block')],
            },
        ),
    ]
