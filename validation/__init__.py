"""Project design validation, independent of Flask and browser code."""
from .engine import RULES, validate


def run_project(path):
    from .service import run_project as run
    return run(path)


def read_report(path):
    from .service import read_report as read
    return read(path)
