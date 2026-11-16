"""seoblog: load the first 10 how-to articles as UNPUBLISHED drafts.
Safe to run again: an article that already exists (same slug) is never
touched, so owner edits are kept. The owner publishes in Owner Admin ->
Website blog."""
from django.core.management.base import BaseCommand


class Command(BaseCommand):
    help = "Load the seed blog articles (unpublished; existing slugs are skipped)."

    def handle(self, *args, **opts):
        from web import blog_seed
        created, skipped = blog_seed.load()
        self.stdout.write("seed_blog: created %d, skipped %d (already there)" % (created, skipped))
