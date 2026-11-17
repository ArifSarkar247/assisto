"""gap-quranblood: the Uthmani asset was renamed .txt.gz -> .txt.gzip (Android
drops *.gz assets from the APK). The backend must find the text under either
name so a server checkout from before or after the rename keeps working."""
import os
import tempfile

from django.test import SimpleTestCase, override_settings

from core import quran_pron as QP


class UthmaniPathTests(SimpleTestCase):
    def _tree(self, name):
        root = tempfile.mkdtemp(prefix="qp-")
        d = os.path.join(root, "app", "assets", "quran")
        os.makedirs(d)
        open(os.path.join(d, name), "wb").close()
        os.makedirs(os.path.join(root, "backend"))
        return root, os.path.join(d, name)

    def test_old_name_still_works(self):
        root, path = self._tree("quran-uthmani.txt.gz")
        with override_settings(BASE_DIR=os.path.join(root, "backend"), QURAN_UTHMANI_PATH=""):
            self.assertEqual(QP._text_path(), path)

    def test_new_name_preferred(self):
        root, path = self._tree("quran-uthmani.txt.gzip")
        with override_settings(BASE_DIR=os.path.join(root, "backend"), QURAN_UTHMANI_PATH=""):
            self.assertEqual(QP._text_path(), path)

    def test_repo_file_is_found(self):
        self.assertTrue(os.path.exists(QP._text_path()))
