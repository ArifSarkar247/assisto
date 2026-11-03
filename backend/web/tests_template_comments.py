"""tplfix (owner 3 Nov 16:33): Django `{# #}` comments are single-line only; a
multi-line one renders as visible text on the public site. Fail CI if any
template (website, Owner Admin, emails, anything under backend/) has one, and
check that rendered public pages contain no template syntax."""
import os
import re

from django.conf import settings
from django.test import TestCase

BACKEND = settings.BASE_DIR  # backend/
SKIP = ("node_modules", "staticfiles", os.sep + "static" + os.sep)


def multiline_hash_comments(root):
    bad = []
    for d, _, files in os.walk(root):
        if any(s in d + os.sep for s in SKIP):
            continue
        for f in files:
            if not f.endswith((".html", ".txt", ".xml")):
                continue
            p = os.path.join(d, f)
            try:
                src = open(p, encoding="utf-8").read()
            except (UnicodeDecodeError, OSError):
                continue
            for n, line in enumerate(src.split("\n"), 1):
                for m in re.finditer(r"\{#", line):
                    if "#}" not in line[m.end():]:
                        bad.append("%s:%d" % (os.path.relpath(p, root), n))
    return bad


class TemplateCommentTests(TestCase):
    def test_no_multiline_hash_comments(self):
        bad = multiline_hash_comments(str(BACKEND))
        self.assertEqual(bad, [], "multi-line {# #} comment renders as text; use {% comment %}: %s" % bad)

    def test_detector_catches_multiline(self):
        import tempfile
        with tempfile.TemporaryDirectory() as t:
            open(os.path.join(t, "x.html"), "w").write("<p>{# one #}</p>\n{# two\n lines #}\n")
            self.assertEqual(multiline_hash_comments(t), ["x.html:2"])

    def test_public_pages_have_no_template_syntax(self):
        for path in ("/", "/?lang=en", "/?lang=bn", "/security", "/pricing", "/help"):
            r = self.client.get(path, HTTP_HOST="lifeassisto.com")
            if r.status_code != 200:
                continue
            html = r.content.decode("utf-8", "replace")
            for t in ("{#", "{%"):
                self.assertNotIn(t, html, "%s leaks %s" % (path, t))
            self.assertNotIn("sitefix (owner", html, path)
