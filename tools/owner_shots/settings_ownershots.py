# ownershots.yml only (adminsafe): the website CI SQLite settings over plain
# http on 127.0.0.1 so headless Chromium can sign in to /owner/. Never used
# in production.
from .settings_webci import *  # noqa: F401,F403

OWNER_ADMIN_REQUIRE_HTTPS = False
