#!/bin/bash
set -euo pipefail
export LINUXBROKER_API_BASE_URL="YOUR_LINUX_BROKER_API_BASE_URL"
export LINUXBROKER_API_CLIENT_ID="YOUR_LINUX_BROKER_API_CLIENT_ID"
exec /usr/local/bin/release-session-common.sh "$@"
