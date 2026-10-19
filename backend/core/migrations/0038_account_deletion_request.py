# Secure "Delete my profile & all data" — Play-Store-compliant account deletion
# with a 7-day grace period, gated like Section 8 (password + OTP + Security PIN,
# blocked on a recent theft signal, delayed when untrusted). Hand-written to
# match core/models.py exactly so `makemigrations --dry-run` reports
# "No changes detected".

import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0037_lost_phone_batch5'),
    ]

    operations = [
        migrations.CreateModel(
            name='AccountDeletionRequest',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True,
                                           serialize=False, verbose_name='ID')),
                ('requested_at', models.DateTimeField(auto_now_add=True)),
                ('effective_at', models.DateTimeField()),
                ('state', models.CharField(
                    choices=[('pending', 'pending'), ('cancelled', 'cancelled'),
                             ('completed', 'completed')],
                    default='pending', max_length=12)),
                ('cancel_token', models.CharField(blank=True, db_index=True,
                                                  default='', max_length=64)),
                ('export_downloaded', models.BooleanField(default=False)),
                ('reason', models.TextField(blank=True, default='')),
                ('user', models.OneToOneField(
                    on_delete=django.db.models.deletion.CASCADE,
                    related_name='deletion_request',
                    to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'ordering': ['-requested_at'],
            },
        ),
    ]
