#!/usr/bin/env bash
#
# Build the lbm-eval-oss Docker image.
#
# Usage:
#   ./docker/build.sh                     # builds lbm-eval-oss:latest
#   ./docker/build.sh my-tag              # builds lbm-eval-oss:my-tag
#   LBM_EVAL_VERSION=1.2.0 ./docker/build.sh  # override wheel version

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"
TAG="${1:-latest}"
LBM_EVAL_VERSION="${LBM_EVAL_VERSION:-1.1.0}"

# Ensure policy_interfaces is available
if [[ ! -d "${SCRIPT_DIR}/policy_interfaces" ]]; then
  echo "policy_interfaces not found. Cloning..."
  git clone --depth 1 \
    git@github.shared-services.aws.tri.global:robotics/policy_interfaces.git \
    "${SCRIPT_DIR}/policy_interfaces"
fi

echo "Building lbm-eval-oss:${TAG} (wheels v${LBM_EVAL_VERSION})"

DOCKER_BUILDKIT=1 docker build \
  --file "${SCRIPT_DIR}/Dockerfile" \
  --build-arg UID="$(id -u)" \
  --build-arg GID="$(id -g)" \
  --build-arg LBM_EVAL_VERSION="${LBM_EVAL_VERSION}" \
  --tag "lbm-eval-oss:${TAG}" \
  "${REPO_ROOT}"
