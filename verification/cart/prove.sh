#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
rm -f "$HERE/out/verified-results.json"
ROOT=$(cd -- "$HERE/../.." && pwd)
docker run --rm --platform linux/amd64 -v "$ROOT:/workspace" \
  -w /workspace/verification/cart --entrypoint python3 \
  runtimeverificationinc/kontrol@sha256:858f004144d61b005997f56bb8b7cd15673850286c96e0e5ec0502d9c9a9e204 \
  verify_lemmas.py
"$HERE/kontrol.sh" build
# Keep old checkpoints for inspection, but certify only this fresh run.
if [[ -d "$HERE/out/proofs" ]]; then
  mkdir -p "$HERE/out/proof-history"
  ARCHIVE=$(mktemp -d "$HERE/out/proof-history/run.XXXXXX")
  mv "$HERE/out/proofs" "$ARCHIVE/proofs"
fi
"$HERE/kontrol.sh" prove \
  --lemmas lemmas/word-arithmetic.k:CART-WORD-ARITHMETIC \
  --match-test '^test%CartSettlementProof\.testNativeGroupedPayout' \
  --match-test '^test%CartSettlementProof\.testNativeToWeth' \
  --match-test '^test%CartSettlementProof\.testWethToNative' \
  --match-test '^test%CartSettlementProof\.testErc20TemporaryApprovals' \
  --match-test '^test%CartApprovalProof\.testUnusedApprovalRevoked' \
  --match-test '^test%CartInventoryProof\.testProof_' \
  --match-test '^test%CartAuthorizationProof\.testProof_' \
  --match-test '^test%CartRevocationProof\.testRevocation_' \
  --workers "${CART_PROOF_WORKERS:-1}" --smt-timeout 30000 --smt-retry-limit 3 --maintenance-rate 1 --max-depth 1000 --no-log-rewrites --step-timeout 3600 --hide-status-bar --xml-test-report
exec docker run --rm --platform linux/amd64 -v "$ROOT:/workspace" \
  -w /workspace/verification/cart --entrypoint python3 \
  runtimeverificationinc/kontrol@sha256:858f004144d61b005997f56bb8b7cd15673850286c96e0e5ec0502d9c9a9e204 \
  check-results.py
