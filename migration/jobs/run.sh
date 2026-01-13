#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH="${1:-config/migration.yaml}"

echo "Running migration with config: ${CONFIG_PATH}"

# In Domino, you might already have dependencies baked into the environment.
# This is safe for learning; remove if your environment manages deps elsewhere.
python3 -m pip install --quiet --upgrade pip
python3 -m pip install --quiet -r requirements.txt

python3 scripts/run_migration.py "${CONFIG_PATH}"
