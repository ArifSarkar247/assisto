# c3-msg: message receipts (delivered/seen per recipient) + presence/typing.
# The integrator re-chains `dependencies` at merge time.
import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0054_c2_calls'),
    ]

    operations = [
        migrations.CreateModel(
            name='CircleChatFlag',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('chat_kind', models.CharField(default='member', max_length=8)),
                ('chat_id', models.CharField(max_length=32)),
                ('marked_unread', models.BooleanField(default=False)),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='c3_chat_flags', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'unique_together': {('user', 'chat_kind', 'chat_id')},
            },
        ),
        migrations.CreateModel(
            name='CirclePresence',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('last_seen', models.DateTimeField(blank=True, null=True)),
                ('online_until', models.DateTimeField(blank=True, null=True)),
                ('activity', models.CharField(blank=True, default='', max_length=10)),
                ('activity_to_user', models.IntegerField(blank=True, null=True)),
                ('activity_group', models.IntegerField(blank=True, null=True)),
                ('activity_until', models.DateTimeField(blank=True, null=True)),
                ('user', models.OneToOneField(on_delete=django.db.models.deletion.CASCADE, related_name='c3_presence', to=settings.AUTH_USER_MODEL)),
            ],
        ),
        migrations.CreateModel(
            name='CircleReceipt',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('delivered_at', models.DateTimeField(blank=True, null=True)),
                ('seen_at', models.DateTimeField(blank=True, null=True)),
                ('message', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='receipts', to='core.circlemessage')),
                ('user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='circle_receipts', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'unique_together': {('message', 'user')},
            },
        ),
    ]
