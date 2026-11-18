"""One temp dir PER TEST CLASS, made when the class starts (never at import).

Why: `manage.py test --parallel` imports every test module in the parent and
then forks the workers, so a module-level `tempfile.mkdtemp()` is ONE dir
shared by every worker. A class's tearDownClass rmtree of that dir then
deleted files another worker was still using (tests_blood slip photo,
tests_p3docs share link -> 410: random red checks on 18 Nov). The guard
core.tests_no_import_tmp fails any test module that makes a temp dir/file at
import time.

Usage:

    class MyTests(TempDirMixin, TestCase):
        tmp_settings = {"MEDIA_ROOT": ""}                      # the dir itself
        # or {"BLOOD_BANKS_FILE": "blood_banks.json"}          # a path inside it

    self.tmp_dir / cls.tmp_dir is the class's own dir; it is removed after the
    class. Put the mixin FIRST in the bases so its override wraps the class.
"""
import os
import shutil
import tempfile

from django.test import override_settings


class TempDirMixin:
    tmp_settings = {"MEDIA_ROOT": ""}

    @classmethod
    def setUpClass(cls):
        cls.tmp_dir = tempfile.mkdtemp(prefix="%s-" % cls.__name__)
        values = {k: (os.path.join(cls.tmp_dir, rel) if rel else cls.tmp_dir)
                  for k, rel in (cls.tmp_settings or {}).items()}
        cls._tmp_override = override_settings(**values)
        cls._tmp_override.enable()
        try:
            super().setUpClass()
        except Exception:
            cls._tmp_override.disable()
            shutil.rmtree(cls.tmp_dir, ignore_errors=True)
            raise

    @classmethod
    def tearDownClass(cls):
        try:
            super().tearDownClass()
        finally:
            cls._tmp_override.disable()
            shutil.rmtree(cls.tmp_dir, ignore_errors=True)
