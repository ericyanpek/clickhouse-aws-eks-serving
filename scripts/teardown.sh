#!/usr/bin/env bash
set -euo pipefail
# The Python entry point verifies state/account/context and journals exact PV IDs.
exec python3 "$(dirname "$0")/teardown.py" "$@"
