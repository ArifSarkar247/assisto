# ai-reply-core (17 Nov): AI reply modes, style profile, AI-sent marks and
# text-free decision events. Additive only (new tables).
from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0175_train_engine'),
    ]

    operations = [
        migrations.CreateModel(
            name='AiReplyProfile',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('style_consent', models.BooleanField(default=False)),
                ('style', models.JSONField(blank=True, default=dict)),
                ('samples_seen', models.IntegerField(default=0)),
                ('notif_on', models.BooleanField(default=False)),
                ('notif_token_ver', models.IntegerField(default=1)),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('user', models.OneToOneField(on_delete=django.db.models.deletion.CASCADE, related_name='ai_reply_profile', to=settings.AUTH_USER_MODEL)),
            ],
        ),
        migrations.CreateModel(
            name='AiReplyMark',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('kind', models.CharField(default='auto', max_length=8)),
                ('label', models.BooleanField(default=True)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('message', models.OneToOneField(on_delete=django.db.models.deletion.CASCADE, related_name='ai_mark', to='core.circlemessage')),
            ],
        ),
        migrations.CreateModel(
            name='AiReplySetting',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('mode', models.CharField(choices=[('off', 'off'), ('suggest', 'suggest'), ('busy', 'busy'), ('auto', 'auto')], default='off', max_length=8)),
                ('busy_until', models.DateTimeField(blank=True, null=True)),
                ('label_on', models.BooleanField(default=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('group', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.CASCADE, related_name='+', to='core.circlegroup')),
                ('member', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.CASCADE, related_name='+', to='core.circlemember')),
                ('user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='ai_reply_settings', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'constraints': [models.UniqueConstraint(condition=models.Q(('member__isnull', False)), fields=('user', 'member'), name='aireply_user_member'), models.UniqueConstraint(condition=models.Q(('group__isnull', False)), fields=('user', 'group'), name='aireply_user_group')],
            },
        ),
        migrations.CreateModel(
            name='AiReplyEvent',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('group_id_ref', models.IntegerField(blank=True, null=True)),
                ('source', models.CharField(default='circle', max_length=8)),
                ('kind', models.CharField(max_length=10)),
                ('category', models.CharField(blank=True, default='', max_length=20)),
                ('in_message_id', models.IntegerField(blank=True, null=True)),
                ('credits', models.IntegerField(default=0)),
                ('token_used', models.BooleanField(default=False)),
                ('seen', models.BooleanField(default=False)),
                ('lock_key', models.CharField(blank=True, max_length=40, null=True, unique=True)),
                ('created_at', models.DateTimeField(auto_now_add=True, db_index=True)),
                ('member', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.CASCADE, related_name='+', to='core.circlemember')),
                ('user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='ai_reply_events', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'ordering': ['-created_at'],
                'indexes': [models.Index(fields=['user', 'kind', 'created_at'], name='aireply_evt_user_kind')],
            },
        ),
    ]
