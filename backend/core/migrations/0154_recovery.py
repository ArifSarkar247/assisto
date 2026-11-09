# recovery (owner order Part 8): per-device sessions, account security state,
# identity-change log ("This was not me"), support recovery requests.
# Additive only (four new tables).
import django.db.models.deletion
import django.utils.timezone
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0153_carecall'),
    ]

    operations = [
        migrations.CreateModel(
            name='DeviceSession',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('key_hash', models.CharField(max_length=64, unique=True)),
                ('device_id', models.CharField(blank=True, default='', max_length=64)),
                ('device_name', models.CharField(blank=True, default='', max_length=80)),
                ('platform', models.CharField(blank=True, default='', max_length=16)),
                ('app_version', models.CharField(blank=True, default='', max_length=24)),
                ('ip', models.CharField(blank=True, default='', max_length=45)),
                ('created_at', models.DateTimeField(default=django.utils.timezone.now)),
                ('last_seen_at', models.DateTimeField(default=django.utils.timezone.now)),
                ('revoked_at', models.DateTimeField(blank=True, null=True)),
                ('revoke_reason', models.CharField(blank=True, default='', max_length=24)),
                ('user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='device_sessions', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'indexes': [models.Index(fields=['user', 'revoked_at'], name='core_devsess_user_rev_idx')],
            },
        ),
        migrations.CreateModel(
            name='AccountSecurityState',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('last_email_change_at', models.DateTimeField(blank=True, null=True)),
                ('last_phone_change_at', models.DateTimeField(blank=True, null=True)),
                ('identity_locked_until', models.DateTimeField(blank=True, null=True)),
                ('email_nudge_count', models.PositiveSmallIntegerField(default=0)),
                ('email_nudge_last_at', models.DateTimeField(blank=True, null=True)),
                ('password_changed_at', models.DateTimeField(blank=True, null=True)),
                ('user', models.OneToOneField(on_delete=django.db.models.deletion.CASCADE, related_name='security_state', to=settings.AUTH_USER_MODEL)),
            ],
        ),
        migrations.CreateModel(
            name='IdentityChange',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('kind', models.CharField(max_length=8)),
                ('old_value', models.CharField(blank=True, default='', max_length=254)),
                ('new_value', models.CharField(blank=True, default='', max_length=254)),
                ('created_at', models.DateTimeField(default=django.utils.timezone.now)),
                ('undo_hash', models.CharField(max_length=64, unique=True)),
                ('undo_expires_at', models.DateTimeField()),
                ('undone_at', models.DateTimeField(blank=True, null=True)),
                ('alert_sent', models.CharField(blank=True, default='', max_length=40)),
                ('user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='identity_changes', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'ordering': ['-id'],
            },
        ),
        migrations.CreateModel(
            name='RecoveryRequest',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('ref', models.CharField(max_length=12, unique=True)),
                ('secret_hash', models.CharField(max_length=64)),
                ('account_phone', models.CharField(max_length=24)),
                ('contact_phone', models.CharField(max_length=24)),
                ('typed_name', models.CharField(blank=True, default='', max_length=120)),
                ('proof', models.JSONField(blank=True, default=dict)),
                ('score', models.PositiveSmallIntegerField(default=0)),
                ('family_state', models.CharField(default='none', max_length=10)),
                ('family_decided_at', models.DateTimeField(blank=True, null=True)),
                ('state', models.CharField(default='pending', max_length=10)),
                ('hold_until', models.DateTimeField()),
                ('created_at', models.DateTimeField(default=django.utils.timezone.now)),
                ('reviewed_at', models.DateTimeField(blank=True, null=True)),
                ('review_note', models.CharField(blank=True, default='', max_length=300)),
                ('completed_at', models.DateTimeField(blank=True, null=True)),
                ('ip', models.CharField(blank=True, default='', max_length=45)),
                ('device_id', models.CharField(blank=True, default='', max_length=64)),
                ('family_user', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to=settings.AUTH_USER_MODEL)),
                ('reviewed_by', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to=settings.AUTH_USER_MODEL)),
                ('user', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.CASCADE, related_name='recovery_requests', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'ordering': ['-id'],
                'indexes': [models.Index(fields=['state', 'id'], name='core_recreq_state_idx')],
            },
        ),
    ]
