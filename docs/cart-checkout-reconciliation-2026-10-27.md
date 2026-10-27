# Cart checkout reconciliation, October 27, 2026

The canonical core branch is `keegan/cart-fixed-quote-currency-swap`, reviewed in [core PR #26](https://github.com/superrare/core/pull/26). It contains the free-listing fix `fec6176` and the later capacity, listing-index, hashing, and mint-result changes.

## What went wrong

The October 26 work used detached commit `606df5c`, the parent of the October 15 free-listing fix. The newer source therefore omitted zero-price support in Cart, CartPayments, and CartLens, as well as `CartFree.t.sol`. The deployment record and live Sepolia bytecode confirm that the October 26 implementation and Lens used this source.

The reconciliation replays the newer work onto the corrected branch. It preserves both sets of changes and restores the original nine free-listing regressions. Additional coverage checks a 65-listing free order through CartLens and settlement, and the token IDs returned from a free ERC721 mint.

## Recovery copies

`keegan/recovery-cart-before-reconciliation-20261027` preserves all original core tracked and nonignored untracked files. Every file was checked against a SHA-256 manifest before integration. Recovery refs also retain the commits from obsolete worktree registrations. Pruning removed invalid registrations only, without removing their remaining directories.

The local recovery directory is `/private/tmp/cart-reconciliation-20261027`. It contains the original file archive, manifest, patch, deployment artifacts, checkout inventory, and worktree metadata archive. Git recovery branches retain the source snapshots independently of this temporary directory.

The monorepo and SDK dirty checkouts were saved in named recovery commits before alignment. Each affected branch ref also has a recovery ref. The checkout manifest records the original and final branch, commit, and path for each repaired directory.

## Current integration checkouts

| Repository | Branch | Active directory |
| --- | --- | --- |
| Core | `keegan/cart-fixed-quote-currency-swap` | `/Users/keeganead/.codex/worktrees/278c/superrare-core` |
| Monorepo | `codex/prints-standalone-cart` | `/Users/keeganead/.codex/worktrees/cart-resource-policy/superrare-monorepo` |
| SDK | `keegan/sdk-cart-resource-policy` | `/private/tmp/rare-sdk-internal-auth-20261027` |
| CLI | `keegan/cli-v2/print-tooling` | `/private/tmp/rare-cli-internal-auth-20261027` |

Other repaired directories keep their current owner-layer branches or named integration aliases. Monorepo and SDK stack registrations have no rebase flags. The CLI migration layer retains a history-only ancestry flag: its current favorites implementation already matches the auth-fix blob, and its SDK dependency includes the SDK auth fix. No remote history was rewritten.

## Deployment preparation

The corrective upgrade replaces CartPayments, Cart, and CartLens. It preserves the proxy, route policy, configuration, approvals, listing state, replay state, and EIP-712 domain. No initializer runs. CartHashes remains compatible.

`script/cart/upgrade-free-listings.sh` simulates by default. Its checkout guard rejects detached HEAD, stale ancestry, and uncommitted deployment sources or tests. Existing Cart deployment wrappers use the same guard. Set `CART_EXPECTED_REF` when intentionally deploying from another reviewed branch.

Broadcasts require fresh live RPC gas estimates. The October 26 local simulator substantially underpriced Sepolia creation transactions. A percentage buffer over those local estimates does not repair the mismatch.

No corrective deployment is recorded here until its transaction receipts and runtime checks are confirmed. After deployment, update `NetworkConfig.s.sol` and the SDK CartLens address together, then propagate the SDK dependency through its consumers.
