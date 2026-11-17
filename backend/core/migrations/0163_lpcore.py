# lpcore (owner 9 Nov 21:45, Language Partner V2): content items + review
# log + learner attempts. Additive only (3 new tables).
import django.db.models.deletion
import django.utils.timezone
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0162_cctvact'),
    ]

    operations = [
        migrations.CreateModel(
            name='LpItem',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('kind', models.CharField(db_index=True, max_length=10)),
                ('key', models.CharField(db_index=True, max_length=80)),
                ('version', models.PositiveIntegerField(default=1)),
                ('track', models.CharField(blank=True, db_index=True, default='', max_length=16)),
                ('level', models.CharField(blank=True, default='', max_length=12)),
                ('tag', models.CharField(blank=True, db_index=True, default='', max_length=40)),
                ('status', models.CharField(db_index=True, default='draft', max_length=16)),
                ('data', models.JSONField(blank=True, default=dict)),
                ('checks', models.JSONField(blank=True, default=dict)),
                ('content_hash', models.CharField(blank=True, db_index=True, default='', max_length=64)),
                ('source', models.CharField(blank=True, default='ai', max_length=12)),
                ('bundle', models.CharField(blank=True, default='', max_length=80)),
                ('reviewed_at', models.DateTimeField(blank=True, null=True)),
                ('created_at', models.DateTimeField(default=django.utils.timezone.now)),
                ('updated_at', models.DateTimeField(db_index=True, default=django.utils.timezone.now)),
                ('reviewed_by', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'constraints': [models.UniqueConstraint(fields=('key', 'version'), name='core_lpitem_key_ver')],
            },
        ),
        migrations.CreateModel(
            name='LpReviewLog',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('action', models.CharField(max_length=16)),
                ('note', models.CharField(blank=True, default='', max_length=500)),
                ('before', models.CharField(blank=True, default='', max_length=16)),
                ('after', models.CharField(blank=True, default='', max_length=16)),
                ('at', models.DateTimeField(default=django.utils.timezone.now)),
                ('actor', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='+', to=settings.AUTH_USER_MODEL)),
                ('item', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='reviews', to='core.lpitem')),
            ],
        ),
        migrations.CreateModel(
            name='LpAttempt',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('kind', models.CharField(db_index=True, max_length=12)),
                ('item_key', models.CharField(blank=True, default='', max_length=80)),
                ('section', models.CharField(blank=True, default='', max_length=12)),
                ('band', models.FloatField(blank=True, null=True)),
                ('data', models.JSONField(blank=True, default=dict)),
                ('credits', models.PositiveIntegerField(default=0)),
                ('created_at', models.DateTimeField(db_index=True, default=django.utils.timezone.now)),
                ('user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='+', to=settings.AUTH_USER_MODEL)),
            ],
        ),
    ]
