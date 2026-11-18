"""Guard: no test module makes a temp dir or file at IMPORT time (module level
or a class body). --parallel forks the workers after import, so such a dir is
shared by every worker and one class's cleanup breaks another's files. Use
core.testing_tmp.TempDirMixin (a dir per class, made in setUpClass)."""
import ast
from pathlib import Path

from django.test import SimpleTestCase

BACKEND = Path(__file__).resolve().parent.parent
TMP_CALLS = {"mkdtemp", "mkstemp", "TemporaryDirectory", "NamedTemporaryFile",
             "TemporaryFile", "SpooledTemporaryFile"}


def import_time_tmp_calls(source):
    """(line, name) of tempfile calls that run when the module is imported."""
    found = []

    def visit(node, in_function):
        for child in ast.iter_child_nodes(node):
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)):
                # decorators and default values still run at import time
                for d in getattr(child, "decorator_list", []):
                    visit_expr(d, in_function)
                for d in child.args.defaults + child.args.kw_defaults:
                    if d is not None:
                        visit_expr(d, in_function)
                visit(child, True)
                continue
            if not in_function and isinstance(child, ast.Call):
                f = child.func
                name = f.attr if isinstance(f, ast.Attribute) else getattr(f, "id", "")
                if name in TMP_CALLS:
                    found.append((child.lineno, name))
            visit(child, in_function)

    def visit_expr(expr, in_function):
        wrapper = ast.Module(body=[ast.Expr(expr)], type_ignores=[])
        visit(wrapper, in_function)

    visit(ast.parse(source), False)
    return sorted(set(found))


class NoImportTimeTempDirTests(SimpleTestCase):
    def test_no_test_module_makes_a_temp_dir_at_import(self):
        bad = []
        for p in sorted(BACKEND.rglob("test*.py")):
            if "migrations" in p.parts or ".venv" in p.parts:
                continue
            for line, name in import_time_tmp_calls(p.read_text(encoding="utf-8")):
                bad.append("%s:%d tempfile.%s" % (p.relative_to(BACKEND), line, name))
        self.assertEqual(bad, [], "import-time temp dirs (use core.testing_tmp.TempDirMixin): %s" % bad)

    def test_the_scanner_sees_module_and_class_level_but_not_functions(self):
        src = ("import tempfile\n"
               "A = tempfile.mkdtemp()\n"
               "class C:\n"
               "    B = tempfile.mkstemp()\n"
               "    def f(self):\n"
               "        return tempfile.mkdtemp()\n"
               "def g(d=tempfile.mkdtemp()):\n"
               "    return tempfile.TemporaryDirectory()\n")
        self.assertEqual([n for n, _ in import_time_tmp_calls(src)], [2, 4, 7])
