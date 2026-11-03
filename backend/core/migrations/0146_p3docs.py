# p3docs (owner PART 3, 3 Nov): Documents vault end-to-end layer — one new
# boolean on Document + three new tables (key wraps, trusted-person recovery
# requests, time-limited encrypted share links). Additive only.
import core.models
import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0145_adminsafe'),
    ]

    operations = [
        migrations.AddField(
            model_name='document',
            name='e2e',
            field=models.BooleanField(default=False),
        ),
        migrations.CreateModel(
            name='VaultKeyWrap',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('kind', models.CharField(choices=[('recovery', 'recovery code'), ('helper', 'trusted person')], max_length=12)),
                ('blob', models.TextField()),
                ('helper_key_id', models.CharField(blank=True, default='', max_length=64)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('helper', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.CASCADE, related_name='vault_wraps_held', to=settings.AUTH_USER_MODEL)),
                ('user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='vault_key_wraps', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'ordering': ['-id'],
            },
        ),
        migrations.CreateModel(
            name='VaultHelpRequest',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('requester_pub', models.CharField(max_length=200)),
                ('requester_key_id', models.CharField(blank=True, default='', max_length=64)),
                ('state', models.CharField(choices=[('pending', 'pending'), ('approved', 'approved'), ('declined', 'declined'), ('cancelled', 'cancelled'), ('done', 'done')], default='pending', max_length=10)),
                ('handback', models.TextField(blank=True, default='')),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('decided_at', models.DateTimeField(blank=True, null=True)),
                ('ready_at', models.DateTimeField(blank=True, null=True)),
                ('helper', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='vault_help_inbox', to=settings.AUTH_USER_MODEL)),
                ('owner', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='vault_help_requests', to=settings.AUTH_USER_MODEL)),
                ('wrap', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='requests', to='core.vaultkeywrap')),
            ],
            options={
                'ordering': ['-id'],
            },
        ),
        migrations.CreateModel(
            name='VaultShareLink',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('token_hash', models.CharField(max_length=64, unique=True)),
                ('blob', models.FileField(blank=True, null=True, upload_to=core.models.p3_share_path)),
                ('size', models.PositiveIntegerField(default=0)),
                ('expires_at', models.DateTimeField()),
                ('max_opens', models.PositiveSmallIntegerField(default=1)),
                ('opens', models.PositiveSmallIntegerField(default=0)),
                ('revoked_at', models.DateTimeField(blank=True, null=True)),
                ('last_opened_at', models.DateTimeField(blank=True, null=True)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('document', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='share_links', to='core.document')),
                ('owner', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='vault_share_links', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'ordering': ['-id'],
            },
        ),
    ]
