#!/usr/bin/env bash
#
# launch_sim.sh - Compatible interface for lbm_eval benchmark
#
# This script provides the same interface as the vla_foundry launch_sim.sh
# but runs the lbm_eval benchmark instead of the Bazel-based simulator.
#
# Usage:
#   bash launch_sim.sh BimanualPutRedBellPepperInBin
#   bash launch_sim.sh  # Uses LAUNCH_TASK_NAME env var
#
# Environment variables (compatible with vla_foundry):
#   LAUNCH_TASK_NAME              - Task name in PascalCase (e.g., "BimanualPutRedBellPepperInBin")
#   LAUNCH_DEMONSTRATION_INDICES  - Episode range (e.g., "100:200" -> num_evaluations)
#   LAUNCH_SAVE_DIR               - Output directory for results
#   LAUNCH_SUMMARY_DIR            - Summary directory (same as LAUNCH_SAVE_DIR for lbm_eval)
#   LAUNCH_T_MAX                  - Not used by lbm_eval (ignored)
#   LAUNCH_SCENARIO               - Not used by lbm_eval (ignored)
#   LAUNCH_CONFIG_FILE            - Not used by lbm_eval (ignored)
#   USE_EVAL_SEED                 - If "1", use deterministic seeds
#   SKIP_BUILD                    - Ignored (no build needed for lbm_eval)
#   LAUNCH_EVALUATION_SUBFOLDER   - Optional subfolder in S3 path (e.g., "oss")
#                                   Path: {checkpoint}/evaluation/{subfolder}/{task}/rollouts/
#
# lbm_eval specific:
#   NUM_PROCESSES                 - Number of parallel evaluation processes (default: 1)
#   POLICY_HOST                   - gRPC policy server host (default: localhost)
#   POLICY_PORT                   - gRPC policy server port (default: 50051)
#   RECORD_VIDEO                  - If "1", save MP4 video(s) per evaluation (default: off)
#   VIDEO_CAMERA                  - Comma-separated list of cameras to record.
#                                   Special values: "mosaic" (grid of all cameras),
#                                                   "all" (every individual camera).
#                                   Examples: "mosaic"
#                                             "scene_left_0,scene_right_0"
#                                             "all,mosaic"
#                                   Typical camera names (task-dependent):
#                                     scene_left_0  scene_right_0
#                                     wrist_left_minus  wrist_left_plus
#                                     wrist_right_minus wrist_right_plus
#                                   Default when empty: "mosaic"
#   VIDEO_FPS                     - Output video frame rate (default: 10)

set -euo pipefail

# Convert PascalCase to snake_case
# BimanualPutRedBellPepperInBin -> bimanual_put_red_bell_pepper_in_bin
pascal_to_snake() {
  python3 -c "
import re
import sys
name = sys.argv[1]
# Insert underscore before uppercase letters (except at start)
snake = re.sub('(.)([A-Z][a-z]+)', r'\1_\2', name)
snake = re.sub('([a-z0-9])([A-Z])', r'\1_\2', snake).lower()
print(snake)
" "$1"
}

# Parse task name from command line or environment
if [ $# -gt 0 ]; then
  LAUNCH_TASK_NAME="$1"
  shift
else
  LAUNCH_TASK_NAME="${LAUNCH_TASK_NAME:-BimanualPutRedBellPepperInBin}"
fi

# Convert PascalCase task name to snake_case skill type for lbm_eval
SKILL_TYPE=$(pascal_to_snake "${LAUNCH_TASK_NAME}")

# Configuration with defaults matching vla_foundry interface
LAUNCH_DEMONSTRATION_INDICES="${LAUNCH_DEMONSTRATION_INDICES:-100:200}"
LAUNCH_SAVE_DIR="${LAUNCH_SAVE_DIR:-/tmp/lbm/rollouts/}"
LAUNCH_SUMMARY_DIR="${LAUNCH_SUMMARY_DIR:-/tmp/lbm/rollouts}"
NUM_PROCESSES="${NUM_PROCESSES:-1}"
POLICY_HOST="${POLICY_HOST:-localhost}"
POLICY_PORT="${POLICY_PORT:-50051}"
USE_EVAL_SEED="${USE_EVAL_SEED:-1}"

# Retry configuration
MAX_RETRIES="${MAX_RETRIES:-3}"
RETRY_DELAY="${RETRY_DELAY:-5}"

# Parse demonstration indices to get start_index and num_evaluations
# Format: "start:end" -> start_index = start, num_evaluations = end - start
parse_demonstration_indices() {
  local indices="$1"
  if [[ "${indices}" == *:* ]]; then
    local start end
    start="${indices%%:*}"
    end="${indices##*:}"
    echo "${start} $((end - start))"
  else
    # If just a number, assume it's num_evaluations starting from 0
    echo "0 ${indices}"
  fi
}

read -r START_INDEX NUM_EVALUATIONS <<< "$(parse_demonstration_indices "${LAUNCH_DEMONSTRATION_INDICES}")"

# Ensure output directory exists
mkdir -p "${LAUNCH_SAVE_DIR}"
mkdir -p "${LAUNCH_SUMMARY_DIR}"

echo "=========================================="
echo "LBM Eval - launch_sim.sh interface"
echo "=========================================="
echo "Task (PascalCase):  ${LAUNCH_TASK_NAME}"
echo "Skill (snake_case): ${SKILL_TYPE}"
echo "Demo indices:       ${LAUNCH_DEMONSTRATION_INDICES}"
echo "Start index:        ${START_INDEX}"
echo "Num evaluations:    ${NUM_EVALUATIONS}"
echo "Num processes:      ${NUM_PROCESSES}"
echo "Output directory:   ${LAUNCH_SAVE_DIR}"
echo "Policy server:      ${POLICY_HOST}:${POLICY_PORT}"
echo "=========================================="

# Verify GPU access
if command -v nvidia-smi &> /dev/null; then
  echo "Verifying GPU access..."
  nvidia-smi
else
  echo "WARNING: nvidia-smi not found"
fi

# Video recording configuration
RECORD_VIDEO="${RECORD_VIDEO:-0}"
VIDEO_CAMERA="${VIDEO_CAMERA:-}"
VIDEO_FPS="${VIDEO_FPS:-10}"

# Build evaluate command arguments
EVAL_ARGS=(
  --skill_type="${SKILL_TYPE}"
  --num_evaluations="${NUM_EVALUATIONS}"
  --start_index="${START_INDEX}"
  --num_processes="${NUM_PROCESSES}"
  --output_directory="${LAUNCH_SAVE_DIR}"
)

if [[ "${RECORD_VIDEO}" == "1" ]]; then
  EVAL_ARGS+=(--record_video --video_fps="${VIDEO_FPS}")
  if [[ -n "${VIDEO_CAMERA}" ]]; then
    # Split comma-separated list into repeated --video_camera flags.
    IFS=',' read -ra _cams <<< "${VIDEO_CAMERA}"
    for _cam in "${_cams[@]}"; do
      EVAL_ARGS+=(--video_camera="${_cam}")
    done
  fi
fi

# Retry loop with crash recovery
ATTEMPT=0
FINAL_EXIT_CODE=0

while true; do
  ATTEMPT=$((ATTEMPT + 1))

  echo "=========================================="
  echo "Attempt ${ATTEMPT}/${MAX_RETRIES}: Running evaluation"
  echo "=========================================="

  set +e
  # Run the lbm_eval evaluate command
  # Use xvfb-run for headless rendering if DISPLAY is not set
  if [[ -z "${DISPLAY:-}" ]]; then
    xvfb-run -a evaluate "${EVAL_ARGS[@]}"
  else
    evaluate "${EVAL_ARGS[@]}"
  fi
  EXIT_CODE=$?
  set -e

  if [ ${EXIT_CODE} -eq 0 ]; then
    echo "Evaluation completed successfully"
    FINAL_EXIT_CODE=0
    break
  fi

  echo "Evaluation failed with exit code ${EXIT_CODE}"

  # Check if we have more retries
  if [ ${ATTEMPT} -ge ${MAX_RETRIES} ]; then
    echo "Maximum retries (${MAX_RETRIES}) reached. Giving up."
    FINAL_EXIT_CODE=${EXIT_CODE}
    break
  fi

  echo "Will retry in ${RETRY_DELAY} seconds..."
  sleep ${RETRY_DELAY}
done

echo "=========================================="
echo "Final status: Attempt ${ATTEMPT}, Exit code ${FINAL_EXIT_CODE}"
echo "=========================================="

# Upload results to S3 if CHECKPOINT_DIR is set (for compatibility)
if [ -n "${CHECKPOINT_DIR:-}" ]; then
  # Strip trailing slashes to avoid double-slash paths in S3
  CHECKPOINT_DIR_CLEAN="${CHECKPOINT_DIR%/}"
  # Strip checkpoint filename if present (e.g., checkpoint.ckpt or checkpoint_12345.pt)
  if [[ "${CHECKPOINT_DIR_CLEAN}" == *.ckpt ]] || [[ "${CHECKPOINT_DIR_CLEAN}" == *.pt ]]; then
    CHECKPOINT_DIR_CLEAN="${CHECKPOINT_DIR_CLEAN%/*}"
  fi

  # Build S3 path components
  if [ -n "${LAUNCH_EVALUATION_SUBFOLDER:-}" ]; then
    S3_SUBFOLDER_PREFIX="${LAUNCH_EVALUATION_SUBFOLDER}/"
  else
    S3_SUBFOLDER_PREFIX=""
  fi

  if [ -n "${LAUNCH_TASK_NAME:-}" ]; then
    S3_TASK_PREFIX="${LAUNCH_TASK_NAME}/"
  else
    S3_TASK_PREFIX=""
  fi

  S3_UPLOAD_PATH="${CHECKPOINT_DIR_CLEAN}/evaluation/${S3_SUBFOLDER_PREFIX}${S3_TASK_PREFIX}rollouts/"
  echo "Uploading results to S3 at ${S3_UPLOAD_PATH}"

  if aws s3 sync "${LAUNCH_SAVE_DIR}" "${S3_UPLOAD_PATH}" 2>/dev/null; then
    echo "Results uploaded successfully"
    rm -rf "${LAUNCH_SAVE_DIR}"/* 2>/dev/null || true
  else
    echo "WARNING: S3 upload failed or not configured, keeping local copy"
  fi
else
  echo "Skipping S3 upload: CHECKPOINT_DIR is not set"
fi

exit ${FINAL_EXIT_CODE}
