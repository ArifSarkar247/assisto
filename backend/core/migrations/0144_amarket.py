# amarket (Assisto Market v1, flag assisto_market OFF): six NEW tables only —
# no existing column or row changes. After the live leaf 0140_cctvalerts;
# the integrator renumbers if another branch lands first.
import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0143_cctvteam'),
    ]

    operations = [
        migrations.CreateModel(
            name='MarketSeller',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('area', models.CharField(default='', max_length=40)),
                ('categories', models.JSONField(blank=True, default=list)),
                ('status', models.CharField(default='pending', max_length=12)),
                ('owner_note', models.CharField(blank=True, default='', max_length=300)),
                ('rating_sum', models.IntegerField(default=0)),
                ('rating_count', models.IntegerField(default=0)),
                ('applied_at', models.DateTimeField(auto_now_add=True)),
                ('decided_at', models.DateTimeField(blank=True, null=True)),
                ('business', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to='core.businessprofile')),
                ('decided_by', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to=settings.AUTH_USER_MODEL)),
                ('user', models.OneToOneField(on_delete=django.db.models.deletion.CASCADE, related_name='market_seller', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'indexes': [models.Index(fields=['status'], name='mkt_seller_status')],
            },
        ),
        migrations.CreateModel(
            name='MarketNeed',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('category', models.CharField(max_length=24)),
                ('title', models.CharField(max_length=120)),
                ('description', models.TextField(blank=True, default='')),
                ('quantity', models.PositiveIntegerField(default=1)),
                ('unit', models.CharField(default='piece', max_length=12)),
                ('budget_min', models.BigIntegerField(blank=True, null=True)),
                ('budget_max', models.BigIntegerField(blank=True, null=True)),
                ('show_budget', models.BooleanField(default=False)),
                ('area', models.CharField(max_length=40)),
                ('deadline', models.DateTimeField()),
                ('group_open', models.BooleanField(default=False)),
                ('status', models.CharField(default='open', max_length=12)),
                ('content_status', models.CharField(default='visible', max_length=10)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('buyer', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='market_needs', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'ordering': ['-created_at'],
                'indexes': [models.Index(fields=['status', 'category'], name='mkt_need_status_cat'),
                            models.Index(fields=['buyer', 'created_at'], name='mkt_need_buyer_at')],
            },
        ),
        migrations.CreateModel(
            name='MarketBid',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('unit_price', models.BigIntegerField()),
                ('delivery_hours', models.PositiveIntegerField(default=24)),
                ('notes', models.CharField(blank=True, default='', max_length=300)),
                ('status', models.CharField(default='active', max_length=12)),
                ('content_status', models.CharField(default='visible', max_length=10)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('need', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='bids', to='core.marketneed')),
                ('seller', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='market_bids', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'ordering': ['unit_price'],
                'indexes': [models.Index(fields=['seller', 'created_at'], name='mkt_bid_seller_at')],
                'constraints': [models.UniqueConstraint(fields=('need', 'seller'), name='market_bid_once')],
            },
        ),
        migrations.AddField(
            model_name='marketneed',
            name='accepted_bid',
            field=models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to='core.marketbid'),
        ),
        migrations.CreateModel(
            name='MarketJoin',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('quantity', models.PositiveIntegerField(default=1)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('need', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='joins', to='core.marketneed')),
                ('user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='market_joins', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'constraints': [models.UniqueConstraint(fields=('need', 'user'), name='market_join_once')],
            },
        ),
        migrations.CreateModel(
            name='MarketDeal',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('quantity', models.PositiveIntegerField(default=1)),
                ('unit_price', models.BigIntegerField()),
                ('total', models.BigIntegerField()),
                ('payment', models.CharField(default='cod', max_length=8)),
                ('fee', models.BigIntegerField(default=0)),
                ('status', models.CharField(default='confirmed', max_length=12)),
                ('rating', models.PositiveSmallIntegerField(blank=True, null=True)),
                ('cancelled_by', models.CharField(blank=True, default='', max_length=8)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('delivered_at', models.DateTimeField(blank=True, null=True)),
                ('bid', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='deals', to='core.marketbid')),
                ('buyer', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='market_deals_bought', to=settings.AUTH_USER_MODEL)),
                ('need', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='deals', to='core.marketneed')),
                ('order', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to='core.order')),
                ('seller', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='market_deals_sold', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'ordering': ['-created_at'],
                'indexes': [models.Index(fields=['buyer', 'created_at'], name='mkt_deal_buyer_at'),
                            models.Index(fields=['seller', 'created_at'], name='mkt_deal_seller_at')],
            },
        ),
        migrations.CreateModel(
            name='MarketBlock',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('blocked', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='+', to=settings.AUTH_USER_MODEL)),
                ('user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='market_blocks', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'constraints': [models.UniqueConstraint(fields=('user', 'blocked'), name='market_block_once')],
            },
        ),
    ]
