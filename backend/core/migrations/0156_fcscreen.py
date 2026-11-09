# fcscreen (Family Care v3, owner order 9 Nov 10:50): multi-family membership
# + shared family tasks. Additive only (three new tables).
import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0155_bizai'),
    ]

    operations = [
        migrations.CreateModel(
            name='FcFamily',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('name', models.CharField(max_length=60)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('created_by', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='fc_families_created', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'ordering': ['id'],
            },
        ),
        migrations.CreateModel(
            name='FcMembership',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('role', models.CharField(choices=[('admin', 'admin'), ('adult', 'adult'), ('child', 'child'), ('elder', 'elder')], default='adult', max_length=8)),
                ('state', models.CharField(choices=[('invited', 'invited'), ('active', 'active'), ('declined', 'declined'), ('left', 'left')], default='invited', max_length=8)),
                ('label', models.CharField(blank=True, default='', max_length=40)),
                ('relation', models.CharField(blank=True, default='', max_length=20)),
                ('alert', models.JSONField(blank=True, default=dict)),
                ('abroad_tz', models.CharField(blank=True, default='', max_length=40)),
                ('joined_at', models.DateTimeField(blank=True, null=True)),
                ('left_at', models.DateTimeField(blank=True, null=True)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('family', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='memberships', to='core.fcfamily')),
                ('invited_by', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to=settings.AUTH_USER_MODEL)),
                ('user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='fc_memberships', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'ordering': ['id'],
                'indexes': [models.Index(fields=['user', 'state'], name='core_fcmem_user_state_idx')],
                'unique_together': {('family', 'user')},
            },
        ),
        migrations.CreateModel(
            name='FcTask',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('title', models.CharField(max_length=120)),
                ('kind', models.CharField(choices=[('medicine', 'medicine'), ('doctor', 'doctor'), ('bill', 'bill'), ('other', 'other')], default='other', max_length=8)),
                ('due_date', models.DateField(blank=True, null=True)),
                ('taken_at', models.DateTimeField(blank=True, null=True)),
                ('done_at', models.DateTimeField(blank=True, null=True)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('created_by', models.ForeignKey(null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to=settings.AUTH_USER_MODEL)),
                ('done_by', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to=settings.AUTH_USER_MODEL)),
                ('family', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='tasks', to='core.fcfamily')),
                ('taken_by', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'ordering': ['-id'],
                'indexes': [models.Index(fields=['family', 'done_at'], name='core_fctask_fam_done_idx')],
            },
        ),
    ]
