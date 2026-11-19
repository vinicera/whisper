import sys
from pathlib import Path

import pytest

SERVER_DIR = Path(__file__).resolve().parents[1]
REPO_DIR = SERVER_DIR.parent
sys.path.insert(0, str(SERVER_DIR))


@pytest.fixture(scope="session", autouse=True)
def _sympy_pool():
    from app import verify_sympy

    yield
    verify_sympy.shutdown()
