# Cart source-review audit

**Date:** 5 November 2026\
**Reviewed source:** `c0ad811919d14a8b81de3684705fd66abc510feb`\
**Plan reference:** `d91c1d9be9d5ddba07cc29b9be92a2d1a4c3c891`\
**Plan:** [cart-audit-plan-subagents.md](cart-audit-plan-subagents.md)\
**Completion:** partial source review. Release-artifact verification is open.

No Critical or High finding was confirmed. Authorization, seller inventory, custody baselines, temporary approvals, split conservation, and atomic rollback hold in the reviewed source under the stated assumptions. The remaining items are operational handoff mistakes, documented trust boundaries, diagnostics, and incomplete cases.

This review does not close CASE-18, CASE-19, CASE-20, the Ethereum fork suite, or current Kontrol proofs.

## Scope

Reviewed contracts under `src/cart/`, deployment scripts under `script/cart/`, Cart tests under `src/test/cart/`, native proof fixtures under `verification/cart/`, and the Cart design, ADRs, runbook, and Sepolia deployment record.

Out of scope, as the plan requires: backend transaction construction, signing-service policy, quote release, and downstream indexer or SDK behavior. Deliberate hostile owner upgrades are out of scope. Uniswap internals are out of scope except where a Cart call crosses Universal Router, Permit2, or WETH.

`src/cart` at this head matches the 1 November 2026 Sepolia deploy commit `593f13bf`. The plan-to-audit delta is documentation plus `c0ad811` (live RPC gas estimates on broadcast wrappers).

## Method

1. Pin SHA, Foundry 1.4.3-stable, profile `cart`, Solidity 0.8.18, via IR, optimizer 100.
2. Reconstruct EIP-712 types, storage layout, and the `executePurchase` sequence from source, then compare to the design and ADRs.
3. Run the local Cart suite and isolated native proof fixtures.
4. Assign the eleven workstreams to separate first-pass reviewers, then challenge the clean claims on signature enforcement, inventory, custody, payout conservation, approvals, and rollback.
5. Map evidence to AUTH-1 through SIZE-1 and CASE-01 through CASE-20.

The first-pass reviewers did not edit production files. This report is the coordinator disposition.

## Baseline

| Item | Result |
| --- | --- |
| `git rev-parse HEAD` | `c0ad811919d14a8b81de3684705fd66abc510feb` |
| `src/cart` dirty? | No. `src/cart/AGENTS.md` is untracked. Docs and lib submodules are dirty. |
| Forge | 1.4.3-stable (`fa9f934b`), profile `cart` |
| Compiler | Solidity 0.8.18, `viaIR = true`, `optimizer_runs = 100` |
| Local suite | `FOUNDRY_PROFILE=cart forge test --offline`: **285 passed**, 0 failed, 0 skipped |
| Invariants | 2 properties, 256 runs, 128000 calls each, 0 handler reverts. Handlers: `stepNative`, `stepErc20`, `stepNativeFamily`, `failed` |
| Native proofs | From `verification/cart` with isolated `FOUNDRY_OUT`: **49 passed** (Authorization 20, Revocation 18, Inventory 11) |
| Cart runtime | 18,880 B (EIP-170 margin 5,696 B) |
| CartPayments runtime | 11,059 B |
| CartLens / Hashes / policy | 10,125 B / 2,591 B / 697 B |
| Linear storage | OpenZeppelin Initializable, Ownable, ReentrancyGuard, EIP712, UUPS gaps. Cart state is only in the three ERC-7201 namespaces. |
| Namespaces | Locations and packing match `Cart.storage-layout.json`, including `paused` at config slot 3 offset 20 and reserved `__deprecatedProtocolRecipient` at slot 4 |
| Fork suite | Not executed. Needs archive `ETH_MAINNET_RPC_URL` at block 25,800,000 |
| Kontrol | Not executed. Saved APR results predate the signed-spread ABI |

Worktree submodule auto-install failed when Foundry was invoked with `--root verification/cart` from the repository root. That is an environment blocker, not a test failure. The isolated retry from `verification/cart` succeeded.

Sepolia (1 November 2026) proxy `0xB08876F9c661667Af22e85859357bB31c4e11741` is recorded in `NetworkConfig` and [cart-sepolia-fresh-2026-11-01.md](cart-sepolia-fresh-2026-11-01.md). Owner `0xba68422a…`, signer `0xf7885c18…`, unpaused. That rollout did not submit a signed end-to-end checkout. Mainnet and Base have no Cart addresses.

## Trust model

Two signatures and the caller protect a purchase.

- The platform signer binds the Purchase Order, including line, route, and action hashes, the Fixed Quote, and `spreadRecipient`.
- The seller binds each Listing through a reusable Merkle root. A valid platform signature cannot replace a seller witness.
- `msg.sender` is the only ERC-20 and ETH funding source. There is no payer field and no buyer signature.

A valid signed route is still an opaque Universal Router program. Cart checks command families, then custody outcomes over the named currencies. Collection delivery is the collection's behavior. Exact-transfer ERC-20 and truthful `balanceOf` are required for the payment invariants.

## Findings

No unauthorized loss or settlement bypass was demonstrated against the reviewed source and the documented assumptions.

### Low

#### L-1. `initialize` can set the owner to the zero address

`transferOwnership` rejects `address(0)`. `initialize` calls `_transferOwnership(owner_)`, which does not.

A broadcast with `CART_OWNER=0x0` (or equivalent init calldata) permanently removes pause, signer rotation, and UUPS authorization. Checkout can continue until an incident needs admin. `renounceOwnership` is a separate, documented brick.

**Invariant:** ADMIN-1 (handoff)\
**Reachability:** operator mistake at deploy, not a public caller\
**Tests:** missing\
**Remediation:** reject `owner_ == address(0)` in `initialize`, or treat a zero-owner rehearsal as a required deploy-script check. Add a proxy init test.

### Informational

#### I-1. NFT delivery is call success, not token state

Cart treats fulfillment as done when `tokenContract.call` succeeds. For `ERC721_MINT_TO` it also requires 32 bytes of return data and logs that word as the token ID. It does not read `ownerOf` or `balanceOf` afterward.

`CartDishonestCollection` shows the result. A no-op transfer or a mint to the seller or to Cart still consumes the order, pays the seller, and emits `FulfillmentActionExecuted` for the signed recipient.

This matches the design. The native call is authoritative. Actual delivery depends on the collection. Platform admission of `tokenContract` is the control. Indexers that treat the fulfillment log as proof of delivery will be wrong when the collection lies.

**Invariant:** ACT-2, EVENT-1, CASE-07\
**Reachability:** seller-chosen collection plus a platform-signed order

#### I-2. Cart and CartPayments can embed different route policies

Each constructor takes its own policy address. `Cart.routePolicy()` is public. The executor policy is private. Lens previews Cart's policy. Execution uses the executor's.

Deploy scripts pass the same address today. A mismatched bundle makes preview and checkout disagree. Execution still enforces the executor policy.

**Invariant:** OPS-1

#### I-3. A valid signed route can redirect Universal Router leftovers

The policy allows `SWEEP` (`0x04`) and does not decode recipients. The pinned fork fixture `testCartRealRouterSweepCannotSpendUnnamedCartToken` shows UR-held DAI swept to `0xBAD` while Cart's DAI baseline stays put and the signed USDC line still pays.

Wrong-recipient swaps that starve Cart revert on solvency. Cart tracked baselines are not spent. Quote construction owns sweep and swap recipients.

**Invariant:** PAY-1 / PAY-2 residual, ADR 0001

#### I-4. ERC-20 spread failures are labeled `PAYOUT`

`_captureSupportedSpread` sends leftover ERC-20 through `_transferExact(..., lineIndex = 0)`, which always uses `FailureStage.PAYOUT`. Native leftover uses `FailureStage.SPREAD`.

The funds still go only to the signed `spreadRecipient`, or the transaction reverts. Clients that switch on `FailureStage` will mis-label ERC-20 spread.

**Invariant:** EVENT-1 diagnostics, CASE-12

#### I-5. ETH payout and ETH spread drop nested revert data

The native `call` paths revert `OrderLineFailed(..., "")`. ERC-20 and router paths keep the inner bytes. `ICart` NatSpec says nested failures retain revert data.

**Invariant:** EVENT-1 diagnostics, CASE-13

#### I-6. Coverage failures reuse `InvalidFulfillmentAction` with a line index

In the action loop the argument is the action index. In the coverage loop it is the line index. An empty action list reverts `InvalidFulfillmentAction(0)` for line 0, even though action 0 does not exist.

**Invariant:** EVENT-1 diagnostics

#### I-7. `_prepareNativeFamily` can panic if a callback drains ETH or WETH

`current - baseline` uses checked subtraction. A fulfillment callback that reduces Cart ETH or WETH below the begin snapshot panics (`0x11`) instead of `PreexistingBalanceConsumed`.

Cart does not approve the NFT target for WETH. Canonical WETH cannot be pulled. ETH cannot be pulled. ATOM-1 still holds. A mock that burns Cart WETH can hit the panic. Non-WETH named tokens already take the custom error.

**Invariant:** PAY-2 error shape\
**Reachability:** mock or hostile WETH only

### Coverage gaps

These are missing witnesses, not production defects.

| ID | Gap |
| --- | --- |
| C-1 | CASE-03 sequence: fill listing L via root A, fill again via live root B, `cancelListing(digest)`, both roots fail |
| C-2 | CASE-04 sequence: last-unit order 1 fails late, order 2 then consumes the unit |
| C-3 | CASE-05 SKU mismatch under a valid platform signature |
| C-4 | Envelope mutations of `orderId`, `paymentCurrency`, and `deadline` with the original platform signature |
| C-5 | Signer rotate-away, reject, rotate-back, accept the still-live old quote. Consumed `orderId` stays consumed under a new signature and new terms |
| C-6 | ERC-1271 revert, wrong magic, truncated return, policy change between quote and execute. Seller wallet that returns magic for the order digest |
| C-7 | CASE-18 combined stateful ledger |
| C-8 | CASE-19 isolated fault copies |
| C-9 | CASE-07 receipt vs `ownerOf` for a fake mint return ID |
| C-10 | CASE-16 decode of `ProtocolSpreadCaptured` on a mixed-kind receipt |
| C-11 | CASE-17 follow-up: oversized or reverted purchase, then an unrelated valid checkout |
| C-12 | Direct `finish` call, second proxy `initialize`, expired nonzero Permit2 amount, `uint160`/`uint48` bounds |

## Confirmed design choices

These match the source. They are not vulnerabilities.

- Caller-funded checkout. A copied quote cannot spend the original payer's tokens.
- The Fixed Quote is the exact charge. Unused input and tracked surplus go to the signed `spreadRecipient`.
- Alternate valid roots may authorize the same Listing. One fill bucket per domain-bound digest.
- Zero totals, free Listings, and zero-as-uncapped inventory are supported. Uncapped listings record fills and can become purchasable again if the asset returns.
- Fees and Currency Swaps are platform-only lines. They do not reserve seller inventory. `CURRENCY_SWAP` cannot be a seller Listing.
- Route policy is a command allowlist. Universal Router decodes inputs.
- ETH and WETH share incremental solvency and remain distinct payout currencies.
- The builder admits order size. On-chain structural rules and the 16-recipient split cap still apply.
- Temporary Permit2 authority is only the payment-token path, rejected if preexisting, cleared after the router, and checked again at `finish`.
- Seller invalidation stays available while paused. Checkout does not.
- Same-proxy upgrade keeps the EIP-712 domain. A fresh proxy changes it. The split-format change invalidates seller authorizations.
- `initialize` and `setPlatformSigner` accept an unavailable signer.
- Immediate Ownable transfer. `renounceOwnership` bricks admin.
- No general rescue for stranded untracked intermediates.
- The implementation-only upgrade script always reverts.

## Deployment and integration risks

| Risk | Why it matters | Control |
| --- | --- | --- |
| Mismatched Cart / executor / policy bundle | Lens preview disagrees with execution | Deploy scripts pair one policy. OPS-1 needs bytecode comparison of both immutables. There is no public executor getter. |
| Empty-data `upgradeToAndCall` | Foundry and the Python sender force-call empty calldata. That succeeds because Cart has `receive()` | Keep `receive` on any implementation used with that path, or switch to `upgradeTo` |
| Broadcast wrapper drift after `c0ad811` | `deploy.sh`, `deploy-lens.sh`, and `upgrade-cart-lens-and-hashes.sh` now use `--slow --skip-simulation` and multiplier 150. `upgrade-cart-implementation.sh` still uses 130 and always reverts | CASE-20 rehearsal on a disposable node |
| Sepolia owner is a deployer EOA | Scripts assume `PRIVATE_KEY`. A production multisig needs a separate call-encoding rehearsal | Runbook |
| No signed Sepolia checkout on the 1 November suite | Configuration was read, not exercised | Execute a direct, routed-split, and free purchase against the live proxy |
| Compiler input not pinned in the Sepolia record | `src/cart` matches `593f13bf`, but a rebuild is a new artifact until the original input is recovered | Recover solc input or treat a rebuild as a separate release |
| Checkout guard default ref | `check-checkout.sh` expects `origin/keegan/cart-fixed-quote-currency-swap` | Set `CART_EXPECTED_REF` for the release head |
| Collection admission | ACT-2 is only as honest as the admitted `tokenContract` | Review mint selectors (`mintTo(address)` and `mintTo(address,uint256,uint256)`). Sovereign and Rare Space mint shapes are incompatible |
| Quote construction | A signed route can sweep UR leftovers or send swap output off Cart | Builder templates must return outputs to Cart. Simulate the full checkout |
| Signing-service policy | The signer chooses any nonzero spread recipient and the entire route | Treasury allowlist and route templates are off-chain |
| Rotate-back | Restoring a prior signer reactivates unexpired, unexecuted quotes | Runbook already states this |
| Owner contract as payout or NFT recipient | `setPaused`, `setPlatformSigner`, and upgrade are not `nonReentrant` | Stated-authority path. Current frame keeps the old Cart bytecode and the immutable executor |
| Fee-on-transfer / rebasing / lying tokens | Funding and payout reject non-exact transfers when balances are truthful. A lying `balanceOf` can panic or mint phantom spread | Admit exact-transfer currencies only |
| Untracked intermediates | Cart has no rescue | Do not leave unnamed tokens on Cart or UR |

## Invariant coverage

Each row is complete only when applicable cases, independent review, and execution evidence exist. None of these rows is closed for release.

| ID | Source disposition | Execution | Limits |
| --- | --- | --- | --- |
| AUTH-1 | Holds. Domain is name `SuperRare Cart`, version `1`, chain, proxy. Envelope hashes and current platform signer are checked before funding. | Local mutation, replay, deadline, high-s, cross-proxy, one-way signer rotation. Native auth proofs 20/20. | Envelope field mutations, rotate-back, 1271 negatives, CASE-01 partial |
| AUTH-2 | Holds. Root cache binds seller. Merkle membership is per listing. Cancel root, cancel listing, and nonce are seller-scoped. | `CartMerkle`, `CartListingIndex`, `testOneRootCannotAuthorizeListingsFromDifferentSellers`, native auth/revocation proofs | CASE-03 combined sequence missing |
| INV-1 | Holds. One `filledQuantity[digest]` across lines and roots. Failed checkout reverts the reservation. | Finite overfill, multi-line cap, inventory proofs | Alternate-root fill + cancel not one witness. CASE-04 race+retry missing |
| INV-2 | Holds. Kind, SKU, currency, and primary recipient must match. Floor is `price * qty` with overflow reject. | Under-floor, overflow, recipient, currency, kind, split floor | SKU override untested |
| ACT-1 | Holds in source. Exact coverage. Non-NFT lines cannot carry actions. Token ID and mint selector come from the Listing, not the action. | Positive 721/1155 transfer and mint, 21 actions, NONE + actions | Several negatives untested (zero recipient, over-coverage, 721 qty 2, swap + actions) |
| ACT-2 | Holds for conforming collections. Does not hold if the collection returns success without the state change. Later failure rolls back. | Rollback of later mint/action/payout. Dishonest collection commits payment | CASE-07 receipt vs state incomplete. Fork collections not run |
| PAY-1 | Holds. Exact Fixed Quote. Signed `routerValue`. Policy allowlist. Per-line split conservation before grouping. | Local direct/routed, split fuzz, SDK vectors | Fork mixed basket not run this pass |
| PAY-2 | Holds. Independent ETH, WETH, payment, and named settlement baselines. ETH/WETH share incremental solvency only. | Preexisting-balance tests, ETH/WETH shortfall, 128000 invariant calls | Combined CASE-08–13 basket missing. Fork not run |
| PAY-3 | Holds for the payment-token path. | Preexisting reject, revoke before NFT, finish re-check, callback restore, ignore-revoke mocks | Expired Permit2 amount and uint bounds untested. Approval proofs not in the native filter |
| PAY-4 | Holds. Tracked leftovers go to the signed nonzero recipient. Grouping is exact currency and recipient, first-seen order, first contributing line. | Spread recipient tests, colliding payouts, 16-recipient events | ERC-20 spread stage is I-4. Fork surplus not re-run |
| ATOM-1 | Holds on conforming tokens. Reservation and replay write after validation and before settlement. `nonReentrant` on checkout and seller invalidation. | Nested purchase from NFT and ETH payout, late payout/mint/spread rollback | CASE-18 sequence missing. Owner-callback admin untested |
| ADMIN-1 | Holds except L-1. Implementation init locked. Owner-only pause, signer, upgrade. Seller invalidation while paused. | Non-owner admin, impl init, pause + invalidation, storage canary, pre-split fixture | Zero-owner init. Live proxy upgrade not rehearsed |
| OPS-1 | Partial. NetworkConfig matches the 1 November Sepolia record. `src/cart` matches that deploy SHA. | Source and recorded addresses | Fork fingerprints, both embedded policies from bytecode, CASE-20, compiler-input rebuild |
| EVENT-1 | Holds in source. `ICart` and `CartPayments` split/spread events match field order and indexing. Delegatecall emits at the proxy. | `OrderLineSettled`, `FulfillmentActionExecuted`, `ListingSplitPaid` decoded in tests | `ProtocolSpreadCaptured` never decoded. Mixed receipt missing. I-4, I-5, I-6 |
| SIZE-1 | Structural rules hold. No persistent griefing of unrelated checkouts from Cart storage. One-tx gas is uncapped except 16 split recipients. | Capacity, listing, 721, 1155, quote, split, advanced gas fixtures passed | CASE-17 follow-up missing. Collision-chain gas unmeasured. Backend admission out of scope |

## Case register

| Case | Status | Notes |
| --- | --- | --- |
| CASE-01 | Partial | Strong mutation coverage. Missing envelope fields, rotate-back, 1271 negatives |
| CASE-02 | Covered | Shared tree, cached first seller, second seller rejected |
| CASE-03 | Partial | Pieces exist. Combined A then B then exact cancel missing |
| CASE-04 | Partial | Sequential overfill and late-fail rollback exist. Race-then-retry missing |
| CASE-05 | Partial | Under-floor and term swaps covered. SKU missing |
| CASE-06 | Mostly covered | Split 721 mint rollback and `MintResult` order exist. 1155 split and several negatives missing |
| CASE-07 | Partial | Dishonest success commits. Receipt vs token state not decoded |
| CASE-08 | Partial | Roles are tested in separate fixtures, not one processor / NFT / spread triad |
| CASE-09 | Covered in source | Per-line rounding, grouping, collisions, 16-cap. Exact two 1-unit 50/50 is implied by the repeated-line test |
| CASE-10 | Strong locally | Fork shortfall not re-run |
| CASE-11 | Covered | Restore-in-callback and ignore-revoke mocks fail at finish. Same quote retries |
| CASE-12 | Covered | Destination and rollback hold. ERC-20 stage is I-4 |
| CASE-13 | Covered on fixture | Fork last-ETH-payout rollback exists in source. Not re-run this pass |
| CASE-14 | Covered for tested entry points | Nested purchase blocked. Nested `cancelListing` and owner-callback admin untested |
| CASE-15 | Covered in test | Pre-split bytecode `a33db9aa` upgrades, keeps history, rejects old roots. Not a live-proxy rehearsal |
| CASE-16 | Partial | Proxy events decoded except `ProtocolSpreadCaptured` |
| CASE-17 | Partial | Gas fixtures passed. Independent checkout after oversize missing |
| CASE-18 | Open | Required sequence is not one ledger-backed witness |
| CASE-19 | Open | No isolated fault copies in the tree |
| CASE-20 | Source-reviewed only | Wrappers request live estimates. Not broadcast on a disposable node |

## Gas and proof limits

Cart runtime has 5,696 bytes of EIP-170 headroom at optimizer 100. That is enough for small fixes, not a large in-proxy feature.

Local call gas grows with lines, distinct listings, proof depth, ERC-721 mint units, split recipients, and route bytes. The 64-listing × 16-recipient split fixture stays within 2.3× the 32-listing point. These are local `call` numbers. They omit intrinsic transaction gas.

Listing and payout indexes live in memory. A failed purchase does not leave Cart storage that makes a later valid checkout more expensive. Filling a shared listing, cancelling a root, or incrementing a nonce is intended competition, not griefing.

Invariant handlers only walk successful opaque-route purchases with empty listings. They do not replace CASE-18.

Native Authorization, Revocation, and Inventory proofs passed at this SHA. Settlement and Approval concrete suites were outside that filter. Kontrol 29-property results are historical. The README says they predate the signed-spread ABI. `prove.sh` was not run. The documented negative control was not run.

## Completion

**Source review: partial.**

Closed for this pass: first-pass coverage of AUTH-1 through SIZE-1 in source, local suite 285/285, native auth/revocation/inventory proofs 49/49, storage-layout match, dispositions for every candidate above.

Open, and required by the plan before source-review completion:

1. CASE-18 stateful sequence with an independent ledger
2. CASE-19 isolated fault copies
3. A second reviewer who did not file the clean first-pass claims, assigned to reproductions of any High or Medium candidate (none filed)
4. Combined CASE-08 through CASE-13 checkout

**Release-artifact verification: not started.**

Needs a reproducible candidate build, live reads of owner, signer, pause, domain, ERC-1967 slot, both policy immutables, and executor bytecode, fork execution at the pinned block, CASE-20 on a disposable node, and a seeded upgrade/rollback if the release uses the existing proxy.

A new source change, compiler setting, dependency, or configuration invalidates the matching rows above. Backend and signing-service review remain outside both completion states.

## Recommended next work

1. Add the cheap CASE-03, CASE-04, CASE-05 SKU, rotate-back, and ERC-1271 negative tests. They lock claims the source already makes.
2. Decide whether `initialize` should reject `address(0)` so it matches `transferOwnership`.
3. Point indexers at token state, not only `FulfillmentActionExecuted`, until collection admission is an allowlist.
4. Extract Cart and CartPayments immutables from the candidate runtime before the next broadcast.
5. Run the Ethereum fork suite and `verification/cart/prove.sh` against this SHA, then refresh OPS-1 and the formal row.
6. Rehearse CASE-20 on a disposable node with the `c0ad811` wrappers.

Do not treat the passing local suite as sign-off.
