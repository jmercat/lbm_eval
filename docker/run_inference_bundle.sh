#!/usr/bin/env bash
#
# run_inference_bundle.sh - Orchestrates policy server and evaluation for lbm_eval
#
# This script provides the same interface as the vla_foundry run_inference_bundle.sh
# but runs lbm_eval's policy server and evaluate commands.
#
# Expected environment variables (compatible with vla_foundry):
#   JOB_NAME                      - Friendly name for log folders (default: job-<pid>)
#   CHECKPOINT_DIR                - Model checkpoint path (for custom policies)
#   TASK_NAME / LAUNCH_TASK_NAME  - Task name in PascalCase (e.g., "BimanualPutRedBellPepperInBin")
#   LAUNCH_DEMONSTRATION_INDICES  - Episode range (e.g., "100:200")
#   LAUNCH_SAVE_DIR               - Output directory for results
#   LOG_DIR                       - Base directory for logs (default: /tmp/lbm/logs)
#   MAX_RETRIES                   - Maximum retry attempts (default: 3)
#   RETRY_DELAY                   - Delay between retries in seconds (default: 5)
#
# lbm_eval specific:
#   POLICY_SERVER_CMD             - Custom policy server command (default: wave_around_policy_server)
#   NUM_PROCESSES                 - Parallel evaluation processes (default: 1)
#   INFERENCE_CMD_OVERRIDE        - Complete override for policy server command

echo "Running lbm_eval inference bundle v1.0.0"
set -euo pipefail

# Disable HuggingFace Hub downloads to prevent rate limiting during cluster evaluations.
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1

# Convert PascalCase to snake_case
pascal_to_snake() {
  python3 -c "
import re
import sys
name = sys.argv[1]
snake = re.sub('(.)([A-Z][a-z]+)', r'\1_\2', name)
snake = re.sub('([a-z0-9])([A-Z])', r'\1_\2', snake).lower()
print(snake)
" "$1"
}

# Configuration with defaults
JOB_NAME="${JOB_NAME:-job-$$}"
LOG_DIR="${LOG_DIR:-/tmp/lbm/logs}"
TASK_NAME="${TASK_NAME:-${LAUNCH_TASK_NAME:-BimanualPutRedBellPepperInBin}}"
LAUNCH_TASK_NAME="${TASK_NAME}"
LAUNCH_DEMONSTRATION_INDICES="${LAUNCH_DEMONSTRATION_INDICES:-100:200}"
LAUNCH_SAVE_DIR="${LAUNCH_SAVE_DIR:-/tmp/lbm/rollouts/}"
LAUNCH_SUMMARY_DIR="${LAUNCH_SUMMARY_DIR:-/tmp/lbm/rollouts}"
NUM_PROCESSES="${NUM_PROCESSES:-1}"
MAX_RETRIES="${MAX_RETRIES:-3}"
RETRY_DELAY="${RETRY_DELAY:-5}"

# Convert PascalCase task name to snake_case skill type
SKILL_TYPE=$(pascal_to_snake "${TASK_NAME}")

# Policy server configuration
POLICY_SERVER_CMD="${POLICY_SERVER_CMD:-wave_around_policy_server}"
INFERENCE_CMD_OVERRIDE="${INFERENCE_CMD_OVERRIDE:-}"

# Memory monitoring configuration
MAX_MEMORY_USAGE_PERCENT="${MAX_MEMORY_USAGE_PERCENT:-90}"
MEMORY_CHECK_INTERVAL="${MEMORY_CHECK_INTERVAL:-10}"

# Create log directory
mkdir -p "${LOG_DIR}/${JOB_NAME}"
EVAL_LOG="${LOG_DIR}/${JOB_NAME}/eval.log"
POLICY_LOG="${LOG_DIR}/${JOB_NAME}/policy.log"
SETUP_LOG="${LOG_DIR}/${JOB_NAME}/setup.log"
MEMORY_LOG="${LOG_DIR}/${JOB_NAME}/memory_profile.log"
LOW_MEMORY_FLAG="${LOG_DIR}/${JOB_NAME}/low_memory_flag"

touch "${EVAL_LOG}" "${POLICY_LOG}" "${SETUP_LOG}"

# Redirect setup output to log
exec 1> >(tee -a "${SETUP_LOG}")
exec 2> >(tee -a "${SETUP_LOG}" >&2)

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting lbm_eval inference bundle for ${JOB_NAME}"
echo "Task (PascalCase):  ${TASK_NAME}"
echo "Skill (snake_case): ${SKILL_TYPE}"
echo "Demo indices:       ${LAUNCH_DEMONSTRATION_INDICES}"
echo "Output:             ${LAUNCH_SAVE_DIR}"
echo "Policy server:      ${POLICY_SERVER_CMD}"
echo "Eval log:           ${EVAL_LOG}"
echo "Policy log:         ${POLICY_LOG}"

# Memory monitoring functions
get_memory_usage_percent() {
  if command -v free >/dev/null 2>&1; then
    free | awk '/^Mem:/ {printf "%.0f", ($2 - $7) / $2 * 100}'
  else
    echo "0"
  fi
}

monitor_memory() {
  local max_usage_percent="$1"
  local check_interval="$2"

  while true; do
    local usage_percent
    usage_percent=$(get_memory_usage_percent)

    if [[ "${usage_percent}" -ge "${max_usage_percent}" ]]; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] MEMORY CRITICAL: ${usage_percent}% >= ${max_usage_percent}%" >> "${MEMORY_LOG}"
      echo "LOW_MEMORY" > "${LOW_MEMORY_FLAG}"
      pkill -TERM -f "evaluate" 2>/dev/null || true
      pkill -TERM -f "policy_server" 2>/dev/null || true
      sleep 2
      pkill -KILL -f "evaluate" 2>/dev/null || true
      pkill -KILL -f "policy_server" 2>/dev/null || true
    fi

    sleep "${check_interval}"
  done
}

# Start memory monitor
rm -f "${LOW_MEMORY_FLAG}"
memory_monitor_pid=""
if command -v free >/dev/null 2>&1; then
  monitor_memory "${MAX_MEMORY_USAGE_PERCENT}" "${MEMORY_CHECK_INTERVAL}" &
  memory_monitor_pid=$!
fi

# Health checks
echo "===== Node Diagnostics ====="
echo "Hostname: $(hostname)"
echo "Memory:"
free -h 2>/dev/null || echo "free command not available"
echo "============================"

if command -v nvidia-smi &> /dev/null; then
  echo "===== GPU Health Check ====="
  nvidia-smi
  echo "============================"
fi

# Mount check for debugging
echo "===== Mount Diagnostics ====="
echo "INFERENCE_WORKDIR: ${INFERENCE_WORKDIR:-not set}"
echo "INFERENCE_CMD_OVERRIDE: ${INFERENCE_CMD_OVERRIDE:-not set}"
if [[ -n "${INFERENCE_WORKDIR:-}" ]]; then
  echo "Checking ${INFERENCE_WORKDIR}:"
  if [[ -d "${INFERENCE_WORKDIR}" ]]; then
    echo "  Directory exists"
    file_count=$(ls -A "${INFERENCE_WORKDIR}" 2>/dev/null | wc -l)
    echo "  File count: ${file_count}"
    if [[ "${file_count}" -eq 0 ]]; then
      echo "  WARNING: Directory is EMPTY - mount may have failed!"
    else
      echo "  First 5 files/dirs:"
      ls -la "${INFERENCE_WORKDIR}" 2>/dev/null | head -7
    fi
    if [[ -d "${INFERENCE_WORKDIR}/diffusion_policy" ]]; then
      echo "  diffusion_policy dir: EXISTS"
    else
      echo "  diffusion_policy dir: MISSING"
    fi
  else
    echo "  Directory does NOT exist"
  fi
fi
echo "============================="

# Log streaming
log_stream_pids=()
policy_pid=""
eval_pid=""

stream_log() {
  local label="$1"
  local path="$2"
  stdbuf -oL tail -n +1 -F "${path}" | sed -e "s/^/[${label}] /" &
  log_stream_pids+=("$!")
}

stream_log "POLICY" "${POLICY_LOG}"
stream_log "EVAL" "${EVAL_LOG}"

# Cleanup function
cleanup_processes() {
  if [[ -n "${memory_monitor_pid:-}" ]] && kill -0 "${memory_monitor_pid}" 2>/dev/null; then
    kill "${memory_monitor_pid}" 2>/dev/null || true
    wait "${memory_monitor_pid}" 2>/dev/null || true
  fi
  if [[ -n "${policy_pid:-}" ]] && kill -0 "${policy_pid}" 2>/dev/null; then
    echo "Stopping policy server (pid ${policy_pid})"
    kill "${policy_pid}" 2>/dev/null || true
    wait "${policy_pid}" 2>/dev/null || true
  fi
  if [[ -n "${eval_pid:-}" ]] && kill -0 "${eval_pid}" 2>/dev/null; then
    echo "Stopping evaluation (pid ${eval_pid})"
    kill "${eval_pid}" 2>/dev/null || true
    wait "${eval_pid}" 2>/dev/null || true
  fi
  for pid in "${log_stream_pids[@]}"; do
    kill "${pid}" 2>/dev/null || true
  done
}

trap cleanup_processes EXIT INT TERM

# Build policy server command
if [[ -n "${INFERENCE_CMD_OVERRIDE:-}" ]]; then
  policy_cmd="${INFERENCE_CMD_OVERRIDE}"
  policy_cmd="${policy_cmd//\{checkpoint\}/${CHECKPOINT_DIR:-}}"
else
  policy_cmd="${POLICY_SERVER_CMD}"
fi

# Parse demonstration indices
parse_demonstration_indices() {
  local indices="$1"
  if [[ "${indices}" == *:* ]]; then
    local start end
    start="${indices%%:*}"
    end="${indices##*:}"
    echo "${start} $((end - start))"
  else
    echo "0 ${indices}"
  fi
}

read -r START_INDEX NUM_EVALUATIONS <<< "$(parse_demonstration_indices "${LAUNCH_DEMONSTRATION_INDICES}")"
echo "Start index:        ${START_INDEX}"
echo "Num evaluations:    ${NUM_EVALUATIONS}"

# Main execution with retry loop
retry_count=0
final_status=0

while true; do
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting attempt $((retry_count + 1)) of $((MAX_RETRIES + 1))"

  rm -f "${LOW_MEMORY_FLAG}"

  # Backup previous logs on retry
  if [[ "${retry_count}" -gt 0 ]]; then
    cp "${EVAL_LOG}" "${EVAL_LOG}.attempt${retry_count}" 2>/dev/null || true
    cp "${POLICY_LOG}" "${POLICY_LOG}.attempt${retry_count}" 2>/dev/null || true
  fi
  : > "${EVAL_LOG}"
  : > "${POLICY_LOG}"

  # Start policy server
  if [[ -n "${INFERENCE_WORKDIR:-}" ]]; then
    if [[ -d "${INFERENCE_WORKDIR}" ]]; then
      echo "Changing to INFERENCE_WORKDIR: ${INFERENCE_WORKDIR}"
      cd "${INFERENCE_WORKDIR}"
      echo "Contents of ${INFERENCE_WORKDIR}:"
      ls -la "${INFERENCE_WORKDIR}" | head -20
    else
      echo "ERROR: INFERENCE_WORKDIR does not exist: ${INFERENCE_WORKDIR}"
      final_status=1
      break
    fi
  fi

  # Verify the policy script exists before trying to run it
  if [[ -n "${INFERENCE_CMD_OVERRIDE:-}" ]]; then
    script_path=$(echo "${policy_cmd}" | grep -oP 'python\s+\K[^\s]+' | head -1)
    if [[ -n "${script_path}" ]] && [[ ! -f "${script_path}" ]]; then
      echo "ERROR: Policy server script not found: ${script_path}"
      echo "Current directory: $(pwd)"
      echo "Directory contents:"
      ls -la
      final_status=1
      break
    fi
  fi

  echo "Starting policy server: ${policy_cmd}"
  if [[ -n "${INFERENCE_CMD_OVERRIDE:-}" ]]; then
    env -u PYTHONPATH -u VIRTUAL_ENV bash -c "${policy_cmd}" > "${POLICY_LOG}" 2>&1 &
  else
    ${policy_cmd} > "${POLICY_LOG}" 2>&1 &
  fi
  policy_pid=$!

  # Wait for policy server to be ready
  POLICY_READY_TIMEOUT="${POLICY_READY_TIMEOUT:-600}"
  POLICY_CHECK_INTERVAL="${POLICY_CHECK_INTERVAL:-5}"
  POLICY_SERVER_PORT="${POLICY_SERVER_PORT:-50051}"

  echo "Waiting for policy server to be ready (timeout: ${POLICY_READY_TIMEOUT}s)..."

  wait_for_policy_server() {
    local timeout="$1"
    local interval="$2"
    local port="$3"
    local elapsed=0

    while [[ "${elapsed}" -lt "${timeout}" ]]; do
      if ! kill -0 "${policy_pid}" 2>/dev/null; then
        echo "ERROR: Policy server process died"
        return 1
      fi

      if command -v nc >/dev/null 2>&1; then
        if nc -z localhost "${port}" 2>/dev/null; then
          echo "Policy server is listening on port ${port}"
          return 0
        fi
      elif command -v python3 >/dev/null 2>&1; then
        if python3 -c "import socket; s=socket.socket(); s.settimeout(1); result=s.connect_ex(('localhost',${port})); s.close(); exit(0 if result==0 else 1)" 2>/dev/null; then
          echo "Policy server is listening on port ${port}"
          return 0
        fi
      fi

      if grep -q "Starting server\|Server started\|Listening on\|serving on" "${POLICY_LOG}" 2>/dev/null; then
        echo "Policy server reports ready in logs"
        return 0
      fi

      if [[ $((elapsed % 30)) -eq 0 ]] && [[ "${elapsed}" -gt 0 ]]; then
        echo "  Still waiting for policy server... (${elapsed}s elapsed)"
        tail -3 "${POLICY_LOG}" 2>/dev/null | sed 's/^/    /'
      fi

      sleep "${interval}"
      elapsed=$((elapsed + interval))
    done

    echo "ERROR: Timeout waiting for policy server after ${timeout}s"
    return 1
  }

  if ! wait_for_policy_server "${POLICY_READY_TIMEOUT}" "${POLICY_CHECK_INTERVAL}" "${POLICY_SERVER_PORT}"; then
    echo "Policy server failed to start. Log contents:"
    cat "${POLICY_LOG}"
    final_status=1
    break
  fi

  sleep 2

  # Start evaluation
  echo "Starting evaluation: ${TASK_NAME} (${SKILL_TYPE}) with ${NUM_EVALUATIONS} episodes"
  mkdir -p "${LAUNCH_SAVE_DIR}"

  EVAL_ARGS=(
    --skill_type="${SKILL_TYPE}"
    --num_evaluations="${NUM_EVALUATIONS}"
    --start_index="${START_INDEX}"
    --num_processes="${NUM_PROCESSES}"
    --output_directory="${LAUNCH_SAVE_DIR}"
  )

  (
    if [[ -z "${DISPLAY:-}" ]]; then
      xvfb-run -a evaluate "${EVAL_ARGS[@]}" > "${EVAL_LOG}" 2>&1
    else
      evaluate "${EVAL_ARGS[@]}" > "${EVAL_LOG}" 2>&1
    fi
  ) &
  eval_pid=$!

  set +e
  wait "${eval_pid}"
  eval_status=$?
  set -e
  eval_pid=""

  # Stop policy server
  if [[ -n "${policy_pid:-}" ]] && kill -0 "${policy_pid}" 2>/dev/null; then
    echo "Stopping policy server"
    kill "${policy_pid}" 2>/dev/null || true
    wait "${policy_pid}" 2>/dev/null || true
    policy_pid=""
  fi

  # Check for retryable errors
  retryable_error=""
  if [[ -f "${LOW_MEMORY_FLAG}" ]]; then
    retryable_error="LowMemory"
    rm -f "${LOW_MEMORY_FLAG}"
  elif grep -q "OOM\|out of memory\|MemoryError" "${EVAL_LOG}" 2>/dev/null; then
    retryable_error="OOM"
  fi

  if [[ -n "${retryable_error}" && "${retry_count}" -lt "${MAX_RETRIES}" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${retryable_error} detected. Retrying in ${RETRY_DELAY}s..."
    retry_count=$((retry_count + 1))
    sleep "${RETRY_DELAY}"
    continue
  fi

  if [[ "${eval_status}" -eq 0 ]]; then
    final_status=0
  else
    final_status="${eval_status}"
  fi
  break
done

cleanup_processes

echo ""
echo "===== Policy Server Log ====="
cat "${POLICY_LOG}" 2>/dev/null || true
echo "===== End Policy Server Log ====="
echo ""
echo "===== Evaluation Log ====="
cat "${EVAL_LOG}" 2>/dev/null || true
echo "===== End Evaluation Log ====="

# Upload results to S3 if configured
if [[ "${CHECKPOINT_DIR:-}" == s3://* ]] && [[ -d "${LAUNCH_SAVE_DIR}" ]]; then
  CHECKPOINT_DIR_CLEAN="${CHECKPOINT_DIR%/}"
  if [[ "${CHECKPOINT_DIR_CLEAN}" == *.ckpt ]] || [[ "${CHECKPOINT_DIR_CLEAN}" == *.pt ]]; then
    CHECKPOINT_DIR_CLEAN="${CHECKPOINT_DIR_CLEAN%/*}"
  fi

  S3_DEST="${CHECKPOINT_DIR_CLEAN}/evaluation/${TASK_NAME}/results/"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Uploading results to ${S3_DEST}"

  if aws s3 sync "${LAUNCH_SAVE_DIR}" "${S3_DEST}" --quiet 2>/dev/null; then
    echo "Results uploaded successfully"
    rm -rf "${LAUNCH_SAVE_DIR}"/* 2>/dev/null || true
  else
    echo "WARNING: S3 upload failed, keeping local copy"
  fi
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] lbm_eval inference bundle completed with status ${final_status}"
exit "${final_status}"
