# adminsafe (owner 3 Nov): Owner Admin staff roles, account actions with a
# user-visible reason, feature restrictions, hashed ban identities, appeals,
# and the 'likely uninstalled' push marker. New tables only.
import django.db.models.deletion
import django.utils.timezone
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0140_cctvalerts'),
    ]

    operations = [
        migrations.CreateModel(
            name='AdminStaffRole',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('role', models.CharField(choices=[('support', 'support'), ('moderator', 'moderator'), ('finance', 'finance'), ('readonly', 'read-only')], max_length=10)),
                ('active', models.BooleanField(default=True)),
                ('note', models.CharField(blank=True, default='', max_length=200)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('granted_by', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to=settings.AUTH_USER_MODEL)),
                ('user', models.OneToOneField(on_delete=django.db.models.deletion.CASCADE, related_name='admin_staff_role', to=settings.AUTH_USER_MODEL)),
            ],
        ),
        migrations.CreateModel(
            name='AccountAction',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('kind', models.CharField(choices=[('warn', 'warn'), ('restrict', 'restrict'), ('unrestrict', 'unrestrict'), ('suspend', 'suspend'), ('ban', 'ban'), ('unblock', 'unblock'), ('force_logout', 'force logout'), ('remove_content', 'remove content')], max_length=16)),
                ('reason', models.CharField(max_length=300)),
                ('detail', models.JSONField(blank=True, default=dict)),
                ('until', models.DateTimeField(blank=True, null=True)),
                ('created_at', models.DateTimeField(auto_now_add=True, db_index=True)),
                ('actor', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to=settings.AUTH_USER_MODEL)),
                ('user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='account_actions', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'ordering': ['-created_at', '-id'],
                'indexes': [models.Index(fields=['user', 'kind'], name='adminsafe_act_uk')],
            },
        ),
        migrations.CreateModel(
            name='UserRestriction',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('kind', models.CharField(choices=[('stranger_msg', 'messaging strangers'), ('channel_post', 'channel posting'), ('community_join', 'community joining')], max_length=16)),
                ('until', models.DateTimeField(blank=True, null=True)),
                ('lifted_at', models.DateTimeField(blank=True, null=True)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('action', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to='core.accountaction')),
                ('user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='restrictions', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'indexes': [models.Index(fields=['user', 'kind'], name='adminsafe_rst_uk')],
            },
        ),
        migrations.CreateModel(
            name='BannedIdentity',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('kind', models.CharField(choices=[('phone', 'phone'), ('email', 'email')], max_length=6)),
                ('value_hash', models.CharField(db_index=True, max_length=64)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('lifted_at', models.DateTimeField(blank=True, null=True)),
                ('action', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to='core.accountaction')),
                ('user', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to=settings.AUTH_USER_MODEL)),
            ],
        ),
        migrations.CreateModel(
            name='AccountAppeal',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('text', models.TextField()),
                ('state', models.CharField(choices=[('open', 'open'), ('upheld', 'decision kept'), ('lifted', 'lifted')], default='open', max_length=8)),
                ('decision_note', models.CharField(blank=True, default='', max_length=300)),
                ('created_at', models.DateTimeField(auto_now_add=True, db_index=True)),
                ('decided_at', models.DateTimeField(blank=True, null=True)),
                ('action', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='appeals', to='core.accountaction')),
                ('decided_by', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to=settings.AUTH_USER_MODEL)),
                ('user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='account_appeals', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'ordering': ['-created_at', '-id'],
            },
        ),
        migrations.CreateModel(
            name='PushDeadMark',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('at', models.DateTimeField(default=django.utils.timezone.now)),
                ('user', models.OneToOneField(on_delete=django.db.models.deletion.CASCADE, related_name='push_dead_mark', to=settings.AUTH_USER_MODEL)),
            ],
        ),
    ]
