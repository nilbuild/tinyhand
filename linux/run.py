#!/usr/bin/env python3
"""Run TinyHand from a checkout or an install directory: python3 run.py [--toggle|--settings|...]"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from tinyhand.__main__ import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main())
