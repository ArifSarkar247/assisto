# sjtrain (Safe Journey V2, 9 Nov): crowd-sourced train SEAT CARD answers.
# Additive only: one new table.
from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0160_fcscreen'),
    ]

    operations = [
        migrations.CreateModel(
            name='TrainSeatAnswer',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('train_no', models.CharField(max_length=8)),
                ('coach', models.CharField(max_length=8)),
                ('seat', models.CharField(max_length=8)),
                ('facing', models.CharField(blank=True, default='', max_length=10)),
                ('place', models.CharField(blank=True, default='', max_length=10)),
                ('side', models.CharField(blank=True, default='', max_length=10)),
                ('coach_pos', models.PositiveSmallIntegerField(blank=True, null=True)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('user', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='train_seat_answers', to=settings.AUTH_USER_MODEL)),
            ],
            options={
                'indexes': [models.Index(fields=['train_no', 'coach'], name='core_trainseat_coach_idx')],
                'constraints': [models.UniqueConstraint(fields=('user', 'train_no', 'coach', 'seat'), name='core_trainseat_once')],
            },
        ),
    ]
