#!/bin/bash
set -euo pipefail
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 vMAJOR.MINOR.PATCH" >&2
    exit 2
fi
project_dir="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$project_dir"
python3 scripts/package.py release --tag "$1"
swift test -c release -Xswiftc -warnings-as-errors
python3 -m unittest discover -s scripts/tests -v
