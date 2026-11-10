# Cart audit, November 6, 2026

One operational Low finding is confirmed. No new unauthorized asset movement,
signature bypass, finite-inventory bypass, or split-conservation defect was
identified in the reviewed source and executed tests under the documented trust
assumptions.

Overall completion remains partial. The preserving-policy upgrade finding is
open, and real-dependency fork and target-chain verification remain blocked.
The long-running symbolic proof runs were canceled at the user's request. Passing local tests does
not establish those remaining claims.

## Audited inputs

The audit follows the current [Cart audit plan](cart-audit-plan-subagents.md).
It includes the uncommitted route protection and four diagnostic fixes in the
working tree over HEAD `c0ad811919d14a8b81de3684705fd66abc510feb`. HEAD alone
cannot identify the audited code. The SHA-256 fingerprint of the scoped contract,
script, configuration, and remapping manifest is
`63517931eacb7e1773b70caa6bc74fe1cdbb4e7a78a37024bbf189fd45aa2838`.
Individual hashes and execution evidence are in the
[audit evidence](data/cart-audit-2026-11-06.json).

Source was copied into an isolated snapshot before execution. Dependencies were
copied from the installed files and hashed. Native commands used an explicit
`ds-test` remapping and read access to the snapshot. Unrelated dirty submodules
were recorded and left intact. Production files were unchanged by this audit.

The retained run directory is
`/private/tmp/cart-audit-20261106-5c01rzvk`. It contains the frozen inputs,
reviewer reports, supplemental harnesses, mutation copies, logs, and local-node
RPC records. The local dependency fixtures and disposable node are distinct from
the actual Universal Router, Permit2, and WETH deployments.

Backend construction, signing-service implementation, quote release, and
consumer behavior remain outside scope. Dishonest collection delivery and
nonconforming currencies remain explicit trust boundaries. Deliberate hostile
owner upgrades remain outside scope.

## Confirmed finding

### L-2. Preserving-policy upgrades can retain an incompatible legacy policy

The new executor consumes `validate(bytes,bytes[])` as an `address[]`. The
legacy policy has the same selector and returns no data. Matching Cart and
executor policy pointers therefore do not establish return-ABI compatibility.

The following preserving-policy paths check code presence or state preservation
and then retain the old policy while deploying the new executor.

- `script/cart/CartImplementationLensAndHashesUpgrade.s.sol`
- `script/cart/CartFreeListingUpgrade.s.sol`
- `tools/upgradeCartFreeListings.py`, including the broadcast path used by
  `upgrade-free-listings.sh`

An honest operator can complete an upgrade through one of these paths and make
all nonempty-route checkouts revert during return decoding. Empty direct routes
remain usable. Funds, inventory, and order consumption roll back on failure.
The owner can recover by rotating to a matching policy and executor bundle.

The recorded Sepolia policy predates the return-ABI change, so this is a relevant
starting configuration. The route-protection document does instruct operators to
co-rotate components, and the dedicated dependency-rotation script does so.
Those instructions limit severity. The preserving paths still lack an executable
compatibility check before they commit the upgrade.

The isolated witness
`AuditAuthorizationTest.testLegacyPolicyBundleUpgradeSucceedsButRoutedCheckoutFailsUntilRotation`
executes a UUPS upgrade with equal legacy policy pointers, observes failed
routed checkout with payer funds and fills unchanged, then rotates to a matching
bundle and succeeds with the same signed order. The preserving-script control
flow was inspected independently by two reviewers. The failing legacy bundle
was reproduced through the UUPS call, while actual shell-wrapper broadcasts were
rehearsed separately with matching current components.

Require a pre-broadcast probe that consumes and checks the policy's returned asset
array, or block the preserving paths for this migration. A zero-amount
`WRAP_ETH` sample with the `MSG_SENDER` alias can exercise the current return ABI.
Ignoring the return value does not establish compatibility. Verify the reviewed
policy code hash and run a routed checkout after the upgrade as well.

**Disposition** remains open. This is an operational availability issue. No
unauthorized loss is demonstrated. It differs from merely embedding unequal
policy addresses because both pointers can be equal and incompatible.

## Execution results

| Check | Result and scope |
| --- | --- |
| Frozen Cart baseline | 293 passed, zero failed or skipped across 26 suites. Both stateful invariants completed 256 runs and 128,000 calls each with zero handler reverts. |
| Independent SDK vectors | Fresh ethers 6.15.0 check reproduced the frozen vectors. The workspace package was incomplete, so pinned dependencies were installed in an isolated directory with lifecycle scripts disabled. |
| Native verification fixtures | All 67 runtime checks passed, including Settlement and Approval. These executions use modeled dependencies and establish runtime evidence. |
| Supplemental authorization and boundary witnesses | 19 passed. Includes envelope mutations, ERC-1271 failures and policy changes, alternate-root cancellation, last-unit rollback, signer revival, NFT action negatives, expired Permit2 amounts, width bounds, and direct executor rejection. |
| Supplemental settlement witnesses | Four passed. Includes all 256 command bytes, preloaded router delta rejection, decoded endpoint surplus, an independent follow-up purchase, and exact per-line penny rounding. |
| Focused gas report | All 30 advanced-checkout, split, and route-protection checks passed with gas reporting enabled. Measurements remain local fixture measurements. |
| CASE-18 | Deterministic stateful ledger and generated histories passed. Three mutation positive controls passed in the same focused suite. |
| CASE-19 | All three executable faults were detected by their targeted assertions. |
| CASE-16 | Mixed receipt witness passed. It checks proxy emitter and every field for purchase, spread, NFT action, split allocations, and three line events against balances and NFT ownership. |
| CASE-20 | Four actual wrappers passed on a disposable local node. Their 16 deployment and upgrade transactions used RPC gas estimates with a 150% limit and receipt confirmation before the next transaction. |
| Artifact checks | All six runtimes reproduce byte-for-byte from captured compiler input and match the local candidate deployment after checking named immutable values. Both embedded policies, executor addresses, and ERC-1967 implementation slot match. |
| Rollback rehearsal | Seeded Listing fill, root and Listing cancellation, seller nonce, replay state, pause, domain, owner, signer, and dependencies survived rollback and forward upgrade. A fresh checkout succeeded after resumption. |
| Checkout guards | Clean, dirty, detached, stale-reference, and restored cases behaved as expected using a local bare Git remote. |
| Mainnet fork | Blocked. No archive RPC was configured. Read-only probes to PublicNode and LlamaRPC returned HTTP 403. |
| Native negative control | Two checks passed. The positive witness pays 18, and the deliberately wrong 19 assertion fails with Panic(0x01) after successful settlement. This is runtime evidence. |
| Current Kontrol selection | Canceled at the user's request after arithmetic checks and setup work. The strict acceptance checker did not complete. Checkpoints are retained and formal coverage remains open. |

The wrapper rehearsal used `deploy.sh`, `deploy-lens.sh`,
`upgrade-cart-lens-and-hashes.sh`, and
`upgrade-with-dependency-rotation.sh`. It used fixture dependency code at the
configured Sepolia addresses on an isolated chain with chain ID 11155111.
Successful local broadcasts establish wrapper behavior and artifact consistency.
They do not establish real pool behavior or a live target proxy's state.

The script build records Solidity `0.8.18+commit.87f61d96`, via IR, optimizer
100, and compiler EVM target `paris`. Runtime sizes are 18,936 bytes for Cart,
11,961 for CartPayments, 2,809 for CartRoutePolicy, 10,267 for CartLens, and
2,591 for CartHashes. Each fits the 24,576-byte limit. These values belong to
this exact script build, whose artifact hashes are in the evidence file.

## Stateful and mutation evidence

CASE-18 independently tracks payer funding, recipient allocations, native and
ERC-20 spread, Cart and router custody baselines, Listing fills, order IDs, and
temporary allowances. Generated histories vary amounts, payer, NFT recipient,
and revocation branch order. Each history has eight mainline successes and six
expected rejections, plus three snapshot branches that each reject revoked
authorization and accept an unaffected seller's free purchase.

The sequence includes partial fills through alternate roots, replay and overfill,
root and exact-Listing cancellation, nonce invalidation, signer rotation away
and back, a routed NFT purchase failing at its final payout and succeeding on
retry, ERC-20 partial spend, a free purchase, and an independent later checkout.
Shares and state expectations are calculated independently of production payout
and inventory helpers. A hard assertion check precedes snapshot restoration so
restoring the VM cannot hide a soft assertion failure.

The generated run reports 257 histories, comprising the configured 256 runs and
a retained harness counterexample. These shapes and amount ranges do not
establish arbitrary-history induction.

| Isolated fault | Baseline control | Detection |
| --- | --- | --- |
| Remove root-cache seller binding | Both leaves have real membership proofs, with one seller signature. | Unauthorized second-seller authorization succeeds, so the expected rejection assertion fails. |
| Allocate splits after combining repeated line amounts | Two one-unit lines with 50/50 shares pay the primary two units and secondary zero. | Faulted execution pays one unit each and fails both independent balance assertions. |
| Disable the final allowance check for a valid signer | A callback restores a nonzero modeled allowance during NFT fulfillment. | Faulted checkout commits instead of rejecting. |

Literal deletion of the final allowance block triggered a compiler exception.
That attempt was excluded. The accepted executable mutation gates the check on
an impossible-for-the-witness zero signer, then fails the targeted behavioral
assertion. Mutation copies remain isolated from production source.

## Independent review

The authorization reviewer first examined hashing, seller witnesses, inventory,
and fulfillment, then independently derived custody, split, allowance, and
rollback expectations. The settlement reviewer first examined payments,
routing, splits, callbacks, and growth, then independently reviewed signatures
and inventory. Both completed these second passes before reading the peer's
report. Neither identified an additional violation of those claims.

A separate reviewer checked upgrade/storage/executor and Lens/receipt behavior
and challenged the operational finding. Another reviewer executed CASE-18 and
CASE-19. The coordinator checked actual wrapper broadcasts, node gas estimation,
artifact identity, guards, and seeded rollback. Clean review is bounded by these
paths, assumptions, and executed inputs.

## Case disposition

| Cases | Current disposition |
| --- | --- |
| CASE-01 through CASE-07 | Covered by baseline and supplemental local witnesses, including the actual two-seller tree, alternate-root fill/cancel sequence, finite-cap competition, ERC-1271 negatives, and dishonest-mint receipt versus token state. |
| CASE-08 and CASE-09 | Covered locally by the distinct-role checkout, independent ETH/WETH ledger, mixed receipt, penny rounding, split vectors, and collision fixtures. |
| CASE-10 | Local shortfall and custody witnesses passed. Real-router repetition remains open. |
| CASE-11 and CASE-12 | Local approval, callback, residual, retry, and rollback witnesses passed. Real-router repetition remains open. |
| CASE-13 | Modeled late-failure composition passed. Required real-swap rollback remains open because the fork did not run. |
| CASE-14 | Guarded callbacks, pause, and seller invalidation covered locally. Owner-authorized callbacks retain their documented authority assumption. |
| CASE-15 | Storage canary and actual pre-split bytecode migration passed. Current-bundle seeded rollback passed on the disposable node. The intended live target still requires its own verification. |
| CASE-16 | Complete for the mixed native receipt witness and its independent state assertions. |
| CASE-17 | Gas fixtures and independent valid checkout after rejection passed. Measurements do not replace chain transaction limits. |
| CASE-18 and CASE-19 | Executed as described above. |
| CASE-20 | Passed for the four actual wrappers and their clean/error checkout guards on the disposable node. The Python sender was source-reviewed but was not independently broadcast in this rehearsal. |
| CASE-21 | Signed wrong-recipient rejection passed locally before router execution. Real deployed-router repetition remains open. |
| CASE-22 | Local retention checks passed. Actual native V4 missing-cleanup, refund, and signed-spread repetition remains open. |
| CASE-23 | Preloaded-router deltas and endpoint custody/spread passed locally. Real dependency confirmation remains open. |
| CASE-24 | Matching current bundles and their immutables verified. Legacy return incompatibility reproduced. The preserving scripts' required compatibility detection is the open Low finding. |

## Prior findings and remaining limits

The earlier L-1 zero-owner finding is resolved. The initializer guard,
ERC-20 balance-mismatch stage, bounded native
revert reasons, and dedicated line-coverage error are present and pass their
regressions. SafeERC20 reverts continue to bubble directly as documented.

Collection call success still depends on collection honesty. That accepted trust
boundary is retained. The earlier unrestricted route-recipient behavior has
changed. Current local checks reject third-party destinations and constrain V4
actions. The new endpoint and router-balance assertions were reviewed and tested,
while their exact deployed-router pairing still needs fork verification.

The optional hostile-WETH subtraction panic remains outside conforming WETH
behavior. Lens root-expiry naming and the unreachable empty-route fallback are
minor diagnostics already identified. Neither establishes an asset-loss path.

Before release, resolve or explicitly accept L-2, supply an accessible archive
RPC, execute the outstanding real-dependency cases, and verify the intended
chain/proxy/artifact pairing. The same-ABI rollback exercised here uses two
current compatible bundles. It does not certify rollback to an arbitrary older
implementation or automatically reconcile replacement Listing identities.

The positive selection and the formal negative control were canceled. Native
negative-control checks passed, but no current symbolic property or full formal
acceptance is claimed. Backend construction and signing-service review remain outside this
report's completion criteria.
