#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
IMAGE=runtimeverificationinc/kontrol@sha256:858f004144d61b005997f56bb8b7cd15673850286c96e0e5ec0502d9c9a9e204
exec docker run --rm --platform linux/amd64 \
  -e KPROFILE_TELEMETRY_DISABLED=true \
  -e K_OPTS="${CART_K_OPTS:--Xmx3g}" \
  -v "$ROOT:/workspace" -w /workspace/verification/cart \
  --entrypoint kontrol "$IMAGE" "$@"
