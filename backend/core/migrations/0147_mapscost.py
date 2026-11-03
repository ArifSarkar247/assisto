# mapscost (owner order 3 Nov 18:40, PART 1): paid maps call counters + the
# ~50 m reverse-geocode cache. Additive only (two new tables).
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0146_p3docs'),
    ]

    operations = [
        migrations.CreateModel(
            name='MapsUsage',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('day', models.DateField(db_index=True)),
                ('api', models.CharField(max_length=16)),
                ('user_id', models.IntegerField(default=0)),
                ('count', models.PositiveIntegerField(default=0)),
                ('capped', models.PositiveIntegerField(default=0)),
            ],
            options={
                'unique_together': {('day', 'api', 'user_id')},
            },
        ),
        migrations.CreateModel(
            name='MapsGeoCache',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('cell', models.CharField(db_index=True, max_length=32)),
                ('lat', models.FloatField()),
                ('lng', models.FloatField()),
                ('lang', models.CharField(default='bn', max_length=4)),
                ('address', models.CharField(max_length=300)),
                ('source', models.CharField(default='google', max_length=12)),
                ('created_at', models.DateTimeField(auto_now_add=True, db_index=True)),
            ],
        ),
    ]
