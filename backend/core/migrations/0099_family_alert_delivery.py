# family100: audit + idempotency rows for server-pushed family alerts.

import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0098_ai_router'),
    ]

    operations = [
        migrations.CreateModel(
            name='FamilyAlertDelivery',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('event_key', models.CharField(max_length=120)),
                ('kind', models.CharField(max_length=24)),
                ('status', models.CharField(default='sent', max_length=16)),
                ('with_location', models.BooleanField(default=False)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('pushed_at', models.DateTimeField(blank=True, null=True)),
                ('received_at', models.DateTimeField(blank=True, null=True)),
                ('seen_at', models.DateTimeField(blank=True, null=True)),
                ('alert', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='deliveries', to='core.familyalert')),
                ('recipient', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='family_alert_deliveries', to=settings.AUTH_USER_MODEL)),
                ('sender', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='family_alerts_sent', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'ordering': ['-created_at', '-id'],
                'indexes': [models.Index(fields=['sender', 'created_at'], name='core_family_sender__idx'), models.Index(fields=['recipient', 'created_at'], name='core_family_recipie_idx'), models.Index(fields=['status'], name='core_family_status_idx')],
                'constraints': [models.UniqueConstraint(fields=('event_key', 'recipient'), name='uniq_family_alert_delivery')],
            },
        ),
    ]
