#!/bin/bash
# Lease, preflight, and systemd startup verbs are root-only; API sudo allows cleanup only.
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
if [ "$EUID" -ne 0 ]; then
    echo "Lease management requires root." >&2
    exit 1
fi
BROKER_PYTHON="/usr/local/libexec/linuxbroker/python3"
if [ ! -f "$BROKER_PYTHON" ] || [ ! -x "$BROKER_PYTHON" ]; then
    echo "The deployment-pinned Python 3.9+ broker runtime is missing." >&2
    exit 1
fi
exec "$BROKER_PYTHON" -I "$(dirname -- "${BASH_SOURCE[0]}")/broker-lease.py" "$@"
