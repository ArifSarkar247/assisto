# Merge migration: the agent-core branch (0099_agent_core -> 0100_agent_nudges)
# and main (0099_daily_info_flag -> 0100_family_alert_delivery ->
# 0101_antitheft2_location_routing). No schema change. The integrator may
# renumber when agent-core lands on main.
from django.db import migrations


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0100_agent_nudges'),
        ('core', '0101_antitheft2_location_routing'),
    ]

    operations = []
