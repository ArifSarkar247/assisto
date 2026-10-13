"""
Management command: run the AXON 30-day sales-month scenario (crm/scenario.py).

The owner/integrator runs this — not the builder agent. It creates an isolated
throwaway org, asserts the pipeline/forecast/reports are correct, prints a
summary, and (with --cleanup) deletes the throwaway org afterwards.

    python manage.py crm_scenario            # keep data for inspection
    python manage.py crm_scenario --cleanup  # delete the throwaway org after
"""
from django.core.management.base import BaseCommand

from crm import scenario


class Command(BaseCommand):
    help = "Simulate a 30-day AXON sales month and verify pipeline/forecast/reports."

    def add_arguments(self, parser):
        parser.add_argument("--cleanup", action="store_true",
                            help="Delete the throwaway scenario org when done.")

    def handle(self, *args, **opts):
        summary = scenario.run(cleanup=opts["cleanup"])
        self.stdout.write(self.style.SUCCESS("AXON scenario passed ✓"))
        for k, v in summary.items():
            self.stdout.write(f"  {k}: {v}")
