# remnotes (owner review 28 Oct): the note / reminder / to-do fields the app
# always sent but the server dropped (so the first sync wiped them), plus
# note colour, vault attachments, "shared from" and to-do repeat.
# Additive only: new columns with defaults; no existing row is rewritten.

from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0119_adscheck"),
    ]

    operations = [
        migrations.AddField(
            model_name="reminder", name="priority",
            field=models.CharField(blank=True, default="none", max_length=8)),
        migrations.AddField(
            model_name="reminder", name="category",
            field=models.CharField(blank=True, max_length=40)),
        migrations.AddField(
            model_name="note", name="checklist",
            field=models.JSONField(blank=True, default=list)),
        migrations.AddField(
            model_name="note", name="tags",
            field=models.JSONField(blank=True, default=list)),
        migrations.AddField(
            model_name="note", name="color",
            field=models.CharField(blank=True, max_length=12)),
        migrations.AddField(
            model_name="note", name="priority",
            field=models.CharField(blank=True, default="none", max_length=8)),
        migrations.AddField(
            model_name="note", name="due_at",
            field=models.DateTimeField(blank=True, null=True)),
        migrations.AddField(
            model_name="note", name="attachments",
            field=models.JSONField(blank=True, default=list)),
        migrations.AddField(
            model_name="note", name="reminder_local_id",
            field=models.CharField(blank=True, max_length=64)),
        migrations.AddField(
            model_name="note", name="shared_from",
            field=models.JSONField(blank=True, default=dict)),
        migrations.AddField(
            model_name="todo", name="priority",
            field=models.CharField(blank=True, default="none", max_length=8)),
        migrations.AddField(
            model_name="todo", name="recurrence_rule",
            field=models.JSONField(blank=True, default=dict)),
    ]
