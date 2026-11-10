# messv2 (owner order 10 Nov 01:20, Part 2): SHARED Mess and bachelor V2.
# Additive only (5 new tables). Integrator renumbers.
import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


def _id():
    return ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID'))


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0165_aimoney'),
    ]

    operations = [
        migrations.CreateModel(
            name='Mess',
            fields=[
                _id(),
                ('name', models.CharField(max_length=80)),
                ('address', models.CharField(blank=True, default='', max_length=200)),
                ('month_start_day', models.PositiveSmallIntegerField(default=1)),
                ('breakfast_milli', models.PositiveSmallIntegerField(default=500)),
                ('cutoff_hour', models.PositiveSmallIntegerField(default=22)),
                ('status', models.CharField(default='active', max_length=8)),
                ('legacy', models.JSONField(blank=True, default=dict)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('closed_at', models.DateTimeField(blank=True, null=True)),
                ('creator', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='messes_created', to=settings.AUTH_USER_MODEL)),
                ('group', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='messes', to='core.circlegroup')),
            ],
            options={'ordering': ['-created_at']},
        ),
        migrations.CreateModel(
            name='MessMember',
            fields=[
                _id(),
                ('name', models.CharField(blank=True, default='', max_length=120)),
                ('role', models.CharField(default='member', max_length=8)),
                ('is_manager', models.BooleanField(default=False)),
                ('seat_share', models.PositiveSmallIntegerField(default=1)),
                ('status', models.CharField(default='active', max_length=8)),
                ('joined_on', models.DateField()),
                ('left_on', models.DateField(blank=True, null=True)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('mess', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='members', to='core.mess')),
                ('user', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='mess_memberships', to=settings.AUTH_USER_MODEL)),
            ],
            options={'ordering': ['id'],
                     'indexes': [models.Index(fields=['user', 'status'], name='core_messmem_user_st_idx')]},
        ),
        migrations.CreateModel(
            name='MessMonth',
            fields=[
                _id(),
                ('key', models.CharField(max_length=7)),
                ('start', models.DateField()),
                ('end', models.DateField()),
                ('counted_until', models.DateField()),
                ('summary', models.JSONField(blank=True, default=dict)),
                ('carry', models.JSONField(blank=True, default=dict)),
                ('closed_at', models.DateTimeField(auto_now_add=True)),
                ('closed_by', models.ForeignKey(null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to=settings.AUTH_USER_MODEL)),
                ('mess', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='months', to='core.mess')),
            ],
            options={'ordering': ['-start'], 'unique_together': {('mess', 'key')}},
        ),
        migrations.CreateModel(
            name='MessEntry',
            fields=[
                _id(),
                ('kind', models.CharField(max_length=8)),
                ('date', models.DateField()),
                ('amount', models.BigIntegerField(default=0)),
                ('data', models.JSONField(blank=True, default=dict)),
                ('photo', models.FileField(blank=True, null=True, upload_to='mess/')),
                ('client_id', models.CharField(blank=True, default='', max_length=64)),
                ('deleted', models.BooleanField(default=False)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('created_by', models.ForeignKey(null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to=settings.AUTH_USER_MODEL)),
                ('updated_by', models.ForeignKey(null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to=settings.AUTH_USER_MODEL)),
                ('member', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='entries', to='core.messmember')),
                ('mess', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='entries', to='core.mess')),
            ],
            options={'ordering': ['date', 'id'],
                     'indexes': [models.Index(fields=['mess', 'kind', 'date'], name='core_messent_kind_dt_idx')]},
        ),
        migrations.CreateModel(
            name='MessEditLog',
            fields=[
                _id(),
                ('action', models.CharField(max_length=24)),
                ('entry_id', models.IntegerField(blank=True, null=True)),
                ('before', models.JSONField(blank=True, default=dict)),
                ('after', models.JSONField(blank=True, default=dict)),
                ('at', models.DateTimeField(auto_now_add=True)),
                ('actor', models.ForeignKey(null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to=settings.AUTH_USER_MODEL)),
                ('mess', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='edit_log', to='core.mess')),
            ],
            options={'ordering': ['-at', '-id']},
        ),
    ]
