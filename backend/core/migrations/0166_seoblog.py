from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0165_aimoney'),
    ]

    operations = [
        migrations.CreateModel(
            name='BlogPost',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('slug', models.SlugField(max_length=80, unique=True)),
                ('title_bn', models.CharField(max_length=120)),
                ('title_en', models.CharField(blank=True, default='', max_length=120)),
                ('summary_bn', models.CharField(blank=True, default='', max_length=200)),
                ('summary_en', models.CharField(blank=True, default='', max_length=200)),
                ('body_bn', models.TextField(blank=True, default='')),
                ('body_en', models.TextField(blank=True, default='')),
                ('feature', models.CharField(blank=True, default='', max_length=40)),
                ('keywords', models.CharField(blank=True, default='', max_length=300)),
                ('cover', models.ImageField(blank=True, null=True, upload_to='blog/')),
                ('cover_alt_bn', models.CharField(blank=True, default='', max_length=160)),
                ('cover_alt_en', models.CharField(blank=True, default='', max_length=160)),
                ('published', models.BooleanField(default=False)),
                ('published_at', models.DateTimeField(blank=True, null=True)),
                ('last_reviewed', models.DateField(blank=True, null=True)),
                ('order', models.IntegerField(default=0)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
            ],
            options={
                'ordering': ['order', '-published_at', 'id'],
            },
        ),
    ]
