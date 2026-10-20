"""PyInstaller entry script (kept outside the package so relative imports in
`shopbox` work in the frozen build)."""
import sys

from shopbox.cli import main

if __name__ == "__main__":
    sys.exit(main())
