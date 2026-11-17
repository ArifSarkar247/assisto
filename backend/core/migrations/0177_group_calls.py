# group-calls (17 Nov): My Circle group calls (mesh, up to 8). Additive only:
# two new tables + a nullable CallRecord.room link.
from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0176_ai_reply_core'),
    ]

    operations = [
        migrations.CreateModel(
            name='GroupCall',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('kind', models.CharField(choices=[('voice', 'voice'), ('video', 'video')], default='voice', max_length=8)),
                ('state', models.CharField(default='live', max_length=8)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('ended_at', models.DateTimeField(blank=True, null=True)),
                ('group', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='group_calls', to='core.circlegroup')),
                ('host', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='group_calls_hosted', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'ordering': ['-created_at'],
                'indexes': [models.Index(fields=['group', 'state'], name='gc_group_state')],
            },
        ),
        migrations.CreateModel(
            name='GroupCallMember',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('state', models.CharField(choices=[('ringing', 'ringing'), ('joined', 'joined'), ('left', 'left'), ('declined', 'declined'), ('missed', 'missed')], default='ringing', max_length=8)),
                ('muted', models.BooleanField(default=False)),
                ('camera', models.BooleanField(default=False)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('joined_at', models.DateTimeField(blank=True, null=True)),
                ('left_at', models.DateTimeField(blank=True, null=True)),
                ('invited_by', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to=settings.AUTH_USER_MODEL)),
                ('ring_call', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to='core.callrecord')),
                ('room', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='members', to='core.groupcall')),
                ('user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='group_call_seats', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'ordering': ['created_at', 'id'],
                'unique_together': {('room', 'user')},
            },
        ),
        migrations.AddField(
            model_name='callrecord',
            name='room',
            field=models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='legs', to='core.groupcall'),
        ),
    ]
