# cctvprice (owner-decided 17 Nov 12:35): installer-commission ledger.
# Additive only (one new table).
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0170_gap_familycare'),
    ]

    operations = [
        migrations.CreateModel(
            name='CctvCommissionEntry',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('order_id', models.CharField(max_length=64, unique=True)),
                ('month', models.CharField(default='', max_length=7)),
                ('cameras', models.PositiveSmallIntegerField(default=0)),
                ('premium_ai_net_bdt', models.DecimalField(decimal_places=2, default=0, max_digits=10)),
                ('pct', models.PositiveSmallIntegerField(default=10)),
                ('amount_bdt', models.PositiveIntegerField(default=0)),
                ('paid_month_no', models.PositiveSmallIntegerField(default=1)),
                ('status', models.CharField(choices=[('owed', 'owed'), ('paid', 'paid'), ('void', 'void')], default='owed', max_length=5)),
                ('created', models.DateTimeField(auto_now_add=True)),
                ('paid_at', models.DateTimeField(blank=True, null=True)),
                ('paid_ref', models.CharField(blank=True, default='', max_length=80)),
                ('partner', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='commissions', to='core.cctvpartner')),
                ('site', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to='core.shopsite')),
            ],
            options={
                'ordering': ['-created'],
                'indexes': [models.Index(fields=['partner', 'status'], name='cctv_comm_partner_idx')],
            },
        ),
    ]
