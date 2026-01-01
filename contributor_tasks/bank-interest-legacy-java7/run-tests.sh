#!/bin/bash
set -euo pipefail
pytest $TEST_DIR/test_outputs.py -v -rA
