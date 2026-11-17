# gap-familycare: shared family ledger (FamExpense.family / created_by) and
# named family savings goals (FamGoal, FamGoalGift). Additive only: nullable
# columns + two new tables; existing personal ledgers are untouched.
# Integrator: renumber after the leaf at merge time.
import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0169_emailrel'),
    ]

    operations = [
        migrations.AddField(
            model_name='famexpense',
            name='family',
            field=models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.CASCADE,
                                    related_name='fam_expenses', to='core.fcfamily'),
        ),
        migrations.AddField(
            model_name='famexpense',
            name='created_by',
            field=models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL,
                                    related_name='+', to=settings.AUTH_USER_MODEL),
        ),
        migrations.CreateModel(
            name='FamGoal',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('name', models.CharField(max_length=60)),
                ('target_poisha', models.BigIntegerField()),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('closed_at', models.DateTimeField(blank=True, null=True)),
                ('created_by', models.ForeignKey(null=True, on_delete=django.db.models.deletion.SET_NULL,
                                                 related_name='+', to=settings.AUTH_USER_MODEL)),
                ('family', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE,
                                             related_name='fam_goals', to='core.fcfamily')),
            ],
            options={'ordering': ['closed_at', '-id']},
        ),
        migrations.CreateModel(
            name='FamGoalGift',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('amount_poisha', models.BigIntegerField()),
                ('at', models.DateTimeField(auto_now_add=True)),
                ('added_by', models.ForeignKey(null=True, on_delete=django.db.models.deletion.SET_NULL,
                                               related_name='+', to=settings.AUTH_USER_MODEL)),
                ('goal', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE,
                                           related_name='gifts', to='core.famgoal')),
                ('member', models.ForeignKey(null=True, on_delete=django.db.models.deletion.SET_NULL,
                                             related_name='+', to=settings.AUTH_USER_MODEL)),
            ],
            options={'ordering': ['id']},
        ),
    ]
