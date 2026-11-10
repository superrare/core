#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
expected_ref="${CART_EXPECTED_REF:-origin/keegan/cart-fixed-quote-currency-swap}"

case "${1:-}" in
  "") check_remote=false ;;
  --remote) check_remote=true ;;
  *) echo "Usage: $0 [--remote]" >&2; exit 2 ;;
esac

cd "${repo_root}"

if ! branch="$(git symbolic-ref --quiet --short HEAD)"; then
  echo "Cart deployment requires a named branch; this checkout has detached HEAD." >&2
  exit 1
fi
if ! git rev-parse --verify --quiet "${expected_ref}^{commit}" >/dev/null; then
  echo "Missing Cart reference ${expected_ref}. Fetch the expected branch before deploying." >&2
  exit 1
fi
if [[ "${check_remote}" == true ]]; then
  remote_ref="${expected_ref#refs/remotes/}"
  remote="${remote_ref%%/*}"
  remote_branch="${remote_ref#*/}"
  if [[ "${remote_branch}" == "${remote_ref}" ]] || ! git remote get-url "${remote}" >/dev/null 2>&1; then
    echo "Broadcast requires CART_EXPECTED_REF to name a remote-tracking branch." >&2
    exit 1
  fi
  remote_line="$(git ls-remote --exit-code "${remote}" "refs/heads/${remote_branch}")"
  remote_head="${remote_line%%[[:space:]]*}"
  if [[ "${remote_head}" != "$(git rev-parse "${expected_ref}")" ]]; then
    echo "${expected_ref} is stale. Fetch and reconcile the current remote branch before broadcasting." >&2
    exit 1
  fi
fi
if ! git merge-base --is-ancestor "${expected_ref}" HEAD; then
  echo "Branch ${branch} does not contain ${expected_ref}. Reconcile this checkout before deploying." >&2
  exit 1
fi

changes="$(git status --porcelain=v1 --untracked-files=normal -- \
  src/cart src/test/cart script/cart script/NetworkConfig.s.sol tools/upgradeCartFreeListings.py \
  foundry.toml remappings.txt lib)"
if [[ -n "${changes}" ]]; then
  echo "Cart deployment sources, tests, or dependencies have uncommitted changes:" >&2
  echo "${changes}" >&2
  exit 1
fi

echo "Cart checkout: ${branch} at $(git rev-parse --short HEAD), contains ${expected_ref}"
