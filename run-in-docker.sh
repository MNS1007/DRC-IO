#!/bin/bash
set -euo pipefail
IMAGE="${DRCIO_EVAL_IMAGE:-drcio-eval:latest}"
if [[ "${DRCIO_SKIP_BUILD:-0}" != "1" ]]; then
  echo "[drcio] Building Docker image $IMAGE (set DRCIO_SKIP_BUILD=1 to skip)"
  docker build -t "$IMAGE" -f Dockerfile.runner .
fi
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <command> [args...]" >&2
  exit 1
fi
exec docker run --rm -it \
  -v "$HOME/.kube:/root/.kube:ro" \
  -v "$HOME/.aws:/root/.aws:ro" \
  -v "$(pwd)":/workspace \
  -w /workspace \
  "$IMAGE" "$@"
