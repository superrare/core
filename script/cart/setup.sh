#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"

# Populate only missing Cart dependencies. Keep existing dependency checkouts intact.
dependencies=(lib/forge-std lib/ds-test lib/openzeppelin-contracts lib/openzeppelin-contracts-upgradeable)
sentinels=(src/Script.sol src/test.sol contracts/proxy/ERC1967/ERC1967Proxy.sol contracts/proxy/utils/UUPSUpgradeable.sol)
for index in "${!dependencies[@]}"; do
  if [[ ! -f "${dependencies[index]}/${sentinels[index]}" ]]; then
    git submodule update --init -- "${dependencies[index]}"
  fi
done

# Husky, lint-staged, and commitlint must come from this checkout's lockfile.
npm ci --include=dev
for tool in husky-run lint-staged commitlint; do
  if [[ ! -x "node_modules/.bin/${tool}" ]]; then
    echo "Setup did not install ${tool}. Check npm configuration and lifecycle-script settings." >&2
    exit 1
  fi
done
echo "Cart dependencies and Git hook tools are ready."
