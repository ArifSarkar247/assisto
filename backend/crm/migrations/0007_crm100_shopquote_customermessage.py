# crm100: shop price quotes (public /q/<token> accept page) + the CRM
# send log (WhatsApp link / phone SMS / Assisto SMS). Additive only.

import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0113_vault_expiry'),
        ('crm', '0006_installment_contact_role_crmorg_round_robin_cursor_and_more'),
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
    ]

    operations = [
        migrations.CreateModel(
            name='CustomerMessage',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('phone_key', models.CharField(blank=True, db_index=True, default='', max_length=40)),
                ('name', models.CharField(blank=True, default='', max_length=120)),
                ('channel', models.CharField(choices=[('whatsapp_link', 'whatsapp_link'), ('sms_app', 'sms_app'), ('assisto_sms', 'assisto_sms')], max_length=14)),
                ('purpose', models.CharField(choices=[('message', 'message'), ('tagada', 'tagada'), ('quote', 'quote'), ('offer', 'offer')], default='message', max_length=8)),
                ('status', models.CharField(choices=[('opened', 'opened'), ('sent', 'sent'), ('blocked', 'blocked'), ('failed', 'failed')], default='opened', max_length=8)),
                ('reason', models.CharField(blank=True, default='', max_length=40)),
                ('text', models.TextField(blank=True, default='')),
                ('credits', models.IntegerField(default=0)),
                ('bulk_id', models.CharField(blank=True, default='', max_length=24)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('business', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.CASCADE, related_name='crm_messages', to='core.businessprofile')),
                ('lead', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='customer_messages', to='crm.lead')),
                ('org', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.CASCADE, related_name='customer_messages', to='crm.crmorg')),
                ('user', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'ordering': ['-created_at'],
                'indexes': [models.Index(fields=['business', 'phone_key', '-created_at'], name='crm_custome_busines_3f0a1c_idx'), models.Index(fields=['org', 'phone_key', '-created_at'], name='crm_custome_org_id_7b2e4d_idx')],
            },
        ),
        migrations.CreateModel(
            name='ShopQuote',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('customer_name', models.CharField(blank=True, default='', max_length=120)),
                ('customer_phone', models.CharField(blank=True, default='', max_length=40)),
                ('phone_key', models.CharField(blank=True, db_index=True, default='', max_length=40)),
                ('lang', models.CharField(default='bn', max_length=2)),
                ('items', models.JSONField(blank=True, default=list)),
                ('subtotal_poisha', models.BigIntegerField(default=0)),
                ('discount_poisha', models.BigIntegerField(default=0)),
                ('delivery_poisha', models.BigIntegerField(default=0)),
                ('total_poisha', models.BigIntegerField(default=0)),
                ('payment', models.CharField(choices=[('cod', 'cod'), ('bkash', 'bkash'), ('nagad', 'nagad'), ('paid', 'paid')], default='cod', max_length=8)),
                ('note', models.CharField(blank=True, default='', max_length=300)),
                ('valid_until', models.DateTimeField()),
                ('nonce', models.CharField(max_length=40, unique=True)),
                ('state', models.CharField(choices=[('issued', 'issued'), ('viewed', 'viewed'), ('accepted', 'accepted'), ('declined', 'declined'), ('expired', 'expired'), ('revoked', 'revoked')], default='issued', max_length=10)),
                ('viewed_at', models.DateTimeField(blank=True, null=True)),
                ('decided_at', models.DateTimeField(blank=True, null=True)),
                ('decline_reason', models.CharField(blank=True, default='', max_length=200)),
                ('accept_name', models.CharField(blank=True, default='', max_length=120)),
                ('accept_address', models.TextField(blank=True, default='')),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('business', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='crm_quotes', to='core.businessprofile')),
                ('created_by', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to=settings.AUTH_USER_MODEL)),
                ('lead', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='shop_quotes', to='crm.lead')),
                ('order', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='crm_quotes', to='core.order')),
            ],
            options={
                'ordering': ['-created_at'],
                'indexes': [models.Index(fields=['business', '-created_at'], name='crm_shopquo_busines_5c9d2e_idx'), models.Index(fields=['business', 'phone_key'], name='crm_shopquo_busines_8a1f3b_idx')],
            },
        ),
    ]
