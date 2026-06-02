#!/usr/bin/env python3
import importlib.util
from pathlib import Path


def load_gate():
    path = Path(__file__).with_name("offline-gate.py")
    spec = importlib.util.spec_from_file_location("offline_gate", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_weighted_errors_matches_official_formula():
    gate = load_gate()
    assert gate.weighted_errors(fp=2, fn=3, errors=5) == 36
