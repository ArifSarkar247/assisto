# invite-join: short invite codes (multi/single use, revoke, label, resend) +
# the join/attribution row.

import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0100_family_alert_delivery'),
    ]

    operations = [
        migrations.AddField(
            model_name='circleinvite', name='code',
            field=models.CharField(blank=True, max_length=16, null=True, unique=True)),
        migrations.AddField(
            model_name='circleinvite', name='max_uses',
            field=models.PositiveSmallIntegerField(default=1)),
        migrations.AddField(
            model_name='circleinvite', name='use_count',
            field=models.PositiveSmallIntegerField(default=0)),
        migrations.AddField(
            model_name='circleinvite', name='revoked',
            field=models.BooleanField(default=False)),
        migrations.AddField(
            model_name='circleinvite', name='label',
            field=models.CharField(blank=True, default='', max_length=60)),
        migrations.AddField(
            model_name='circleinvite', name='last_sent_at',
            field=models.DateTimeField(blank=True, null=True)),
        migrations.CreateModel(
            name='CircleInviteJoin',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('via', models.CharField(default='link', max_length=16)),
                ('new_account', models.BooleanField(default=False)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('invite', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='joins', to='core.circleinvite')),
                ('user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='circle_invite_joins', to=settings.AUTH_USER_MODEL)),
            ],
            options={'ordering': ['-created_at'], 'unique_together': {('invite', 'user')}},
        ),
    ]
