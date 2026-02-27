#!/bin/bash
# entrypoint.sh — IT-Stack snipeit container entrypoint
set -euo pipefail

echo "Starting IT-Stack SNIPEIT (Module 16)..."

# Source any environment overrides
if [ -f /opt/it-stack/snipeit/config.env ]; then
    # shellcheck source=/dev/null
    source /opt/it-stack/snipeit/config.env
fi

# Execute the upstream entrypoint or command
exec "$$@"
