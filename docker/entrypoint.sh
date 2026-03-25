#!/usr/bin/env bash
# Entrypoint script for lbm_eval Docker container.
# Activates the virtual environment and runs the provided command.

set -euo pipefail

LBM_EVAL_HOME="${LBM_EVAL_HOME:-/opt/lbm_eval}"
LBM_EVAL_VENV="${LBM_EVAL_VENV:-${LBM_EVAL_HOME}/.venv}"

# Activate the virtual environment
if [[ -f "${LBM_EVAL_VENV}/bin/activate" ]]; then
    # shellcheck disable=SC1091
    source "${LBM_EVAL_VENV}/bin/activate"
else
    echo "Error: Virtual environment not found at ${LBM_EVAL_VENV}" >&2
    exit 1
fi

# Change to /opt/anzu for compatibility with vla_foundry
cd /opt/anzu 2>/dev/null || true

# Ensure output directories exist (they are world-writable in the image,
# but may need creation if not bind-mounted).
mkdir -p /tmp/lbm /tmp/lbm/rollouts /tmp/lbm/logs 2>/dev/null || true

# Execute the command
exec "$@"
