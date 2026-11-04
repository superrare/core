# Audit the Cart contracts

Use this plan to audit SuperRare's atomic Cart checkout before a release or
upgrade. Pin the source, deployed configuration, and client versions first.
Report reproducible failures of authorization, inventory, fulfillment, settlement,
or recovery, with separate evidence for each deployment and integration claim.

The starting reference is commit `d91c1d9be9d5ddba07cc29b9be92a2d1a4c3c891`
on the Cart branch. The coordinator records the actual audit SHA and any
changes since this reference. Use the [Cart design](cart-contract-design.md),
[Commerce terminology](../CONTEXT.md), and the three Cart ADRs to establish
intent. Use the Solidity source to establish what a call does. Record
disagreements between the two as audit questions until resolved.

## Set the scope

| Component | What to follow |
| --- | --- |
| [Cart and ICart](../src/cart/Cart.sol) | Proxy entry points, two layers of authorization, Listing resolution and inventory, action execution, admin, and receipt semantics. Use [ICart](../src/cart/ICart.sol) for canonical tuples, errors, and events. |
| [CartStorage](../src/cart/CartStorage.sol) | Config, seller authorization and inventory, and replay namespaces. Compare inherited storage and the [committed baseline](../src/cart/Cart.storage-layout.json). |
| [CartPayments and ICartPayments](../src/cart/CartPayments.sol) | Delegatecalled `begin` and `finish`, custody snapshots, Fixed Quote, route execution, approvals, split allocation, grouped payouts, and Protocol Spread. Review the [handoff types](../src/cart/ICartPayments.sol) across the implementation boundary. |
| [CartRoutePolicy](../src/cart/CartRoutePolicy.sol) | The exact accepted command bytes, flag mask, array shape, and pinned router interpretation. Compare the policy embedded in Cart with the one embedded in CartPayments. |
| [CartHashing and CartHashes](../src/cart/CartHashing.sol) | Canonical EIP-712, ordered arrays, Merkle leaf encoding, optimized Order Line buffer, and the [client helper](../src/cart/CartHashes.sol). |
| [CartLens and CartValidation](../src/cart/CartLens.sol) | Advisory Listing, envelope, and route checks. Compare overlapping behavior with Cart and trace intentional differences. Review [shared validation](../src/cart/CartValidation.sol) and [Lens result types](../src/cart/ICartLens.sol). |
| [Deployment and upgrades](../script/cart) | Initialization, owner and signer handoff, implementation-only and dependency-rotation scripts, helper deployment, checkout guard, and [NetworkConfig](../script/NetworkConfig.s.sol). |
| [Test and proof projects](../src/test/cart) | Local, adversarial, fuzz, invariant, historical-upgrade, and gas suites. Use [Ethereum fork tests](../src/test/forks/ethereum/cart), the [SDK vectors](data/cart-split-sdk-vectors.json), and [Kontrol](../verification/cart/README.md) as separate evidence. |

Review the actual Universal Router, Permit2, WETH, and supported token interfaces
as Cart dependencies. Review transaction-builder, signer, payer processor, SDK,
wallet, indexer, and fulfillment worker behavior where they rely on Cart's
contract. Pin external repos and deployments when access is available. Where
access is missing, record the consumer, assumption, and evidence still required.
Keep unrelated markets, auction houses, token issuance, and the rest of Uniswap
outside the audit unless a concrete Cart call crosses that boundary.

### Identify the actors and trust boundaries

| Actor | Authority and audit assumptions |
| --- | --- |
| Cart owner | Pauses checkout, changes the platform signer, transfers ownership, and authorizes UUPS upgrades. Assume honest administration. Test missing authorization, initialization, bad inputs, interrupted rollout, and unsafe handoff. Deliberate owner installation of hostile code is outside scope. |
| Platform signer and builder | Authorize the Purchase Order, all lines, the exact route and actions, and the spread destination. The signer cannot replace seller authorization for a Listing. Test ordinary bugs, input manipulation, stale state, misconfigured integrations, and compromised release gates. Treat deliberate abuse of authorized commercial choices as a trust assumption. |
| Seller | Signs reusable Listing Roots. Can revoke a root, exact Listing, or earlier nonce. Controls Listing proceeds and may operate a hostile ERC-1271 account or token contract. Authority to sign a Listing does not grant authority over another account's NFTs. |
| Payer or payment processor | Calls the proxy and funds the Fixed Quote. A party with a usable quote can try to submit it using its own assets. Test replay and order consumption even when the payer, action recipients, and spread recipient are different accounts. |
| Payout, spread, and NFT recipients | May be unrelated contracts. Treat callbacks, reverting recipients, and overlapping roles as adversarial inputs. Listing Split recipients have payout rights only. |
| Configured router, Permit2, and WETH | Assume the reviewed deployment code. Test its actual response to allowed programs, shared balances, stale routes, real allowance state, and integration mistakes. Use hostile stand-ins to probe stated invariants and identify the production assumptions needed to reach a failure. |
| NFT and currency contracts | Test ordinary supported behavior and deliberate lies at every external boundary. Track which claims require exact-transfer ERC-20 behavior, conforming NFT contracts, or explicit builder admission. |
| Consumers | Attribute receipts and fulfill off-chain Orders using the configured chain, Cart proxy, ABI, and event data. Test mistaken attribution, duplicate processing, and inconsistent rollout. |

### Keep deliberate choices visible during triage

| Design choice | What to verify |
| --- | --- |
| Caller-funded checkout without a payer field or buyer signature. | `msg.sender` is the only ERC-20 funding source. A copied quote cannot take the original payer's assets or change delivery. Determine whether another caller consuming the quote breaks a documented processor or user flow. |
| The Fixed Quote is the exact signed charge. | Underfunding fails. Unused input and tracked surplus go to the signed `spreadRecipient`. Check processor receipts and retry logic for refund assumptions. |
| Seller witnesses are separate from the Purchase Order. | An alternate valid root can authorize the same Listing. All paths still enforce the exact signed digest, live root, proof, seller, nonce, and cancellation, with one fill bucket per digest. |
| Zero totals, free Listings, and zero-as-uncapped inventory are supported. | Free checkout preserves replay and fulfillment checks. Uncapped inventory still records fills. Test unavailable underlying assets and the intended relisting behavior. |
| Fees and Currency Swaps are platform-authorized peer lines. | Enforce their Listing and action restrictions. Check fee consolidation and routing policy in the signer. Cart receives explicit charge amounts and does not calculate commercial fees. |
| The route policy is a command allowlist. | Treat allowed command inputs as attacker-controlled at the signer boundary. Prove which invariants Cart enforces through balance and allowance checks, and which outcomes require correct route templates. |
| ETH and WETH share incremental solvency. | Keep exact payout currencies, independent protected baselines, and currency-specific payout aggregation. |
| The builder controls order size. | Confirm bounded admission and gas estimation of the exact payload. On-chain structural rules and the per-Listing split cap still apply. |
| NFT fulfillment uses supported external calls. | Confirm behavior for supported collections. A successful call or a returned ERC-721 token ID establishes the call result. Actual delivery depends on collection behavior, so review admission and consumer claims separately. |
| Stable proxy, separately deployed helpers. | Compatible upgrades preserve approvals and domain. Schema migrations require explicit signature and client handling. Lens previews are advisory. |

## Verify the invariants

Use these IDs in findings, reproductions, and the final coverage table.

| ID | Required result |
| --- | --- |
| AUTH-1 | An executable order has a nonzero unused order ID, valid current platform signature, live deadline, and exact signed line, route, and action hashes. Signatures bind the chain and Cart proxy. A mutation or replay fails before funds move. |
| AUTH-2 | Every referenced Listing resolves to one supplied digest and a valid seller witness. Root verification caches remain seller-bound. A root can be reused while valid. A cancelled root, cancelled Listing, or stale seller nonce cannot authorize a purchase. |
| INV-1 | All Order Lines referencing one Listing contribute to one cumulative fill, even across alternate roots or different Orders. Finite capacity cannot be exceeded. Failed checkout leaves prior fills and replay state intact. |
| INV-2 | Seller-backed line kind, SKU, settlement currency, and primary recipient match the Listing. The full line amount meets the per-unit proceeds floor times quantity, without arithmetic truncation. |
| ACT-1 | Each supported on-chain line is covered exactly by valid actions. The action source, recipient, quantity, token ID, and mint selector follow the authenticated Listing and signed action. Non-NFT lines have zero actions. |
| ACT-2 | For conforming collections, success delivers every authorized NFT transfer or mint. ERC-721 mint results and fulfillment logs correspond to action and unit order. A failed later action rolls back earlier delivery. |
| PAY-1 | The caller supplies exactly the Fixed Quote. Cart enforces signed router value, validates supported route commands, and pays each obligation in its exact currency. For a split line, independent per-line allocations conserve its full amount. |
| PAY-2 | A purchase cannot spend tracked preexisting funds. Cart protects independent ETH, WETH, payment-token, and named settlement-token balances. ETH/WETH may fund each other only through incremental assets. Success restores every tracked balance exactly. |
| PAY-3 | ERC-20 routing grants access to the quoted payment token through the configured two-layer Permit2 path. Nonzero preexisting allowances for that path are rejected. Temporary allowance amounts are zero before NFT fulfillment and again at successful completion. |
| PAY-4 | Positive tracked residuals after obligations go to the nonzero signed `spreadRecipient` in their actual currencies. Grouped payouts use exact currency and recipient, preserve first-seen order, and retain the first contributing line for failure attribution. |
| ATOM-1 | A revert at any stage leaves no purchase, partial payout, asset delivery, fill, order consumption, or purchase logs. A callback cannot execute another purchase or mutate seller invalidation state through guarded entry points. |
| ADMIN-1 | Only the configured owner can pause, rotate the signer, or authorize upgrade. Proxy initialization runs once, the implementation is locked, and a compatible upgrade preserves live storage, approvals, and EIP-712 identity. Seller invalidation stays available while paused. |
| OPS-1 | The deployed proxy, implementation, executor, policies, dependencies, Lens, Hashes, bindings, and signer agree for each target chain. Migration preserves required state and coordinates incompatible signatures and Listing capacity. |
| EVENT-1 | Consumers can reconstruct the payer and Fixed Quote, original lines, exact split allocations, individual fulfillment operations, and Protocol Spread from committed logs. Off-chain fulfillment runs once per applicable line under the consumer's reorg policy. |
| SIZE-1 | The signer releases only payloads that pass configured work, gas, and byte admission. The measured payload, actual payer, value, deployment, and authorization witnesses match the released checkout. |

## Coordinate the audit

### Capture the baseline

1. Record `git rev-parse HEAD`, `git status --short`, `git submodule status`,
   `forge --version`, the effective Foundry profile, and the compiler version.
   Use a checkout with pinned dependencies already installed. If a linked
   worktree attempts automatic submodule setup, use an isolated scratch Foundry
   root with the same source, pinned dependencies, and explicit remappings.
   Record any remapping overrides and keep shared Git metadata out of the run.
2. Record chain, proxy, block number and hash, implementation slot, deployed
   code hashes, owner, signer, pause state, dependencies, and helpers.
   Derive the embedded executor and both policy addresses from verified build
   artifacts or deployment evidence. The proxy's `routePolicy()` only exposes
   the policy embedded in Cart.
3. Run the local suite and collect test counts, fuzz settings, invariant calls,
   handler reverts, and skipped cases. Save full output for any failure. Run a
   separate gas report and storage/ABI inspection.

   ```sh
   export FOUNDRY_PROFILE=cart
   forge test --offline
   forge test --offline --gas-report
   forge build --offline --sizes
   forge inspect --offline src/cart/Cart.sol:Cart storageLayout
   forge inspect --offline src/cart/Cart.sol:Cart abi
   forge inspect --offline src/cart/CartPayments.sol:CartPayments abi
   forge inspect --offline src/cart/CartLens.sol:CartLens abi
   forge inspect --offline src/cart/CartHashes.sol:CartHashes abi
   ```

   Compare linear storage to compiler output. Inspect the three namespaced
   structs and their assembly slot accessors separately. Check the deployed
   size for Cart and the executor with the release optimizer settings.
4. Run the independent ethers vectors and the native verification fixtures.
   Use the [split verification commands](cart-split-verification.md) and the
   [proof project commands](../verification/cart/README.md). Keep native
   verification output outside the Kontrol artifact root.
5. Run the live-dependency tests against the pinned archive block, then
   simulate representative payloads at an explicitly recorded release block.
   Supply the archive RPC URL through `ETH_MAINNET_RPC_URL`. Record dependency code
   fingerprints and pool availability. Use a local fork or a read-only call.

   ```sh
   FOUNDRY_PROFILE=cart FOUNDRY_TEST=src/test/forks/ethereum/cart forge test --offline -vv
   ```

   The [mainnet fork report](cart-mainnet-fork-verification.md) records 17
   passing tests at block 25,800,000. That run deploys Cart locally on the
   fork. Treat it as evidence for the recorded source and dependency state.
6. Compare the [fresh Sepolia record](cart-sepolia-fresh-2026-11-01.md) and
   [receipt ledger](data/cart-sepolia-fresh-2026-11-01.json) to the current
   target chain and addresses. Confirm both the intended proxy and the retired
   proxy state if a migration relies on it. Capture SDK, builder, signer, and
   worker revisions separately.
7. Record each baseline failure as a reproducible test failure, environment
   blocker, or missing artifact. Assign each blocker an owner and continue
   independent source review. Keep historical proof, unit, fork, and receipt
   evidence distinct.

### Assign subagents and cross-checks

The coordinator owns the audit baseline, workstream assignments, finding log,
and final severity. Assign each agent a scope, invariant IDs, expected tests,
and cross-check partner. Use a separate scratch root or checkout for each
agent that needs to edit tests or produce artifacts. Keep primary review
read-only and retain repro changes separately from proposed fixes.

| Wave | Agent | Workstream | Independent cross-check |
| --- | --- | --- | --- |
| 1 | Authorization | 1. Signed data and seller witnesses | Inventory agent checks alternate roots and digest identity. |
| 1 | Inventory | 2. Listing terms and fill state | Authorization agent checks root cache and cancellation. |
| 1 | Custody | 3. Funding, balances, and spread | Routing agent traces token access and intermediate currencies. |
| 1 | Routing | 4. Router and Permit2 | Custody agent verifies quote, baseline, and approval invariants. |
| 1 | Payouts | 5. Splits and grouped transfers | Callback agent checks transfer order and failure attribution. |
| 1 | Fulfillment | 6. NFT execution and collection behavior | Integration agent checks admission and receipts. |
| 1 | Callbacks | 7. Atomicity and failure paths | Payouts and fulfillment agents review the same late-failure cases. |
| 1 | Upgrade | 8. Proxy, configuration, and rollout | Authorization agent checks domain and signature migration. |
| 1 | Integration | 9. Lens, signing, and reconciliation | Upgrade agent checks deployment drift. |
| 1 | Capacity | 10. Gas and transaction admission | Routing, payouts, and fulfillment agents provide workload cases. |
| 2 | Verification | 11. Test and proof claims | Coordinator matches independently reviewed evidence to every invariant. |
| 2 | Reproduction | Credible high and medium candidates | Assign a second reviewer who did not file the candidate. |

With four total execution slots, keep the coordinator in one slot. Run
authorization and inventory, custody and routing, and proxy and rollout in the
three agent slots first. Then run payouts and callbacks, fulfillment and
integration, and capacity and verification. Start a focused follow-up as a slot
opens if evidence could change a high- or medium-severity decision. With a
single reviewer, run the same workstreams serially and revisit the independent
cross-checks after reproductions. Record any second-review gap.

### Require evidence from each agent

Return the source SHA, files and functions reviewed, invariant IDs, commands,
and results. For each candidate include the attacker, preconditions, call order,
expected and observed results, impact, proposed severity, and confidence. Mark
which facts came from a mock, a pinned fork, a live read, or a consumer source
file. Identify existing tests and missing assertions. Include the minimal
reproduction, preferably a Foundry test, or the exact transaction sequence.

For a proposed finding that spans boundaries, provide both sides of the call.
Examples include the signer payload and router trace, the seller witness and fill
state, or the implementation upgrade and old consumer decoding. Return review
gaps with a concrete next check. Mark a reviewed design choice as confirmed
when the evidence matches its documented behavior.

## Execute the workstreams

### 1. Verify signed data and seller witnesses

Review `ICart`, `CartHashing`, `CartHashes`, and `Cart._validateOrderHashes`
and `_resolveRootListings`. Compare `CartLens` and the transaction builder.
Cover AUTH-1 and AUTH-2 with the inventory reviewer.

- Reconstruct all struct hashes and digests independently. Include empty and
  nonempty `Split[]`, ordered lines and actions, dynamic router `bytes[]`,
  signed `routerValue`, and `spreadRecipient`. Verify type strings, field
  widths, enum encoding, array order, and proxy domain name and version.
- Differential-test the optimized Order Line memory buffer against canonical
  EIP-712 encoding. Mutate each field, reorder elements, repeat elements,
  vary lengths, and follow the next memory allocation. Test empty and
  boundary-size arrays even where an empty order would later revert.
- Mutate each Order field and each signed payload while keeping the original
  signature. Repeat for Listing fields and root nonce, deadline, and Merkle
  root. Assert the failure happens before funding and preserves all state.
- Verify EOA recovery, including malformed and high-s signatures. Exercise
  ERC-1271 revert, wrong magic value, truncated data, and changing wallet
  policy between quote and execution. Confirm a malicious seller wallet
  cannot bypass the independent platform signature.
- Test order and seller root deadlines at one second before, exactly at, and
  one second after expiry. Test chain ID changes, a second proxy, and
  implementation-address signatures. Prove that cross-domain signatures
  fail even when the same keys and payload are used.
- Build a Merkle tree independently with singleton, multi-leaf, odd-size, and
  deep cases. Verify the leaf hashing and sorted pair construction used by
  the builder. Put leaves from two sellers in one actual tree and prove
  caching a valid first signature cannot authorize the second seller.
- Swap valid witnesses for the same Listing digest. Reject a mismatched root
  index, wrong proof, missing or extra Listing, duplicate supplied digest,
  root/signature array mismatch, and wrong seller nonce. Check if redundant
  witness data can affect execution, diagnostics, or admission.
- Verify signer rotation with outstanding orders, including rotating away
  and back before expiry. Confirm a successful order ID remains consumed
  even when a new valid signature uses the same ID and different terms.

Start with `CartVerification.t.sol`, `CartMerkle.t.sol`,
`CartHashingBuffer.t.sol`, `CartAuditDuplicateDigest.t.sol`,
`CartAdversarial.t.sol`, `CartSpreadRecipient.t.sol`, and the SDK vectors.
Return independent payload and digest vectors for any mismatch.

### 2. Verify Listing terms and inventory

Review `Cart._validateListing`, `_indexListingDigest`, `_findListingDigest`,
`_validateLineTerms`, and `_reserveListings`. Cover AUTH-2, INV-1, and INV-2
with authorization and fulfillment.

- Model the remaining capacity of one Listing across multiple successful and
  rejected orders. Repeat with multiple lines in one order and multiple
  valid roots for the same leaf. Compare fill counts by full digest after
  each step.
- Test two separately signed orders racing for the final unit. Run both
  orderings and a late failure of the first transaction. Check that a retry
  after rollback and restored approvals can use the same authorized quote.
- Force digest index bucket collisions, including wraparound and missing
  lookups. Check full-digest comparison, duplicates, the singleton fast
  path, repeated SKUs, and zero as the platform-only sentinel.
- Vary each seller term independently under a valid platform signature.
  Exercise the floor just below, exactly at, and above the required amount,
  including zero and overflow boundaries. Test large aggregate quantities
  across repeated lines and near-limit accumulated uncapped fills.
- Check finite and uncapped ERC-721 transfers against underlying ownership
  and approval. Give a returned asset a fresh `listingSalt`. Confirm when
  an old uncapped authorization can become usable again, and distinguish
  contract behavior from a client promise of a one-time sale.
- Cancel a root, cancel an exact Listing across all roots, and increment
  the seller nonce. Verify the other sellers stay live. Test revocation
  before and after a partial fill, repeated cancellation, pause, and a
  replacement root reusing the same leaf.
- Verify that platform-only `NONE` and `CURRENCY_SWAP` lines never reserve
  seller inventory. Check that `CURRENCY_SWAP` requires a different
  settlement currency and cannot use a seller Listing or NFT action.
  Try a zero-amount Currency Swap and an empty route with ETH/WETH
  conversion. Determine which cases the builder and indexer classify as
  conversions and whether that agrees with the value actually exchanged.

Start with `CartMerkle.t.sol`, `CartListingIndex.t.sol`,
`CartVerification.t.sol`, and `CartFree.t.sol`. Return a compact inventory
state model and a test for any difference between the model and Cart.

### 3. Reconcile funding, custody, and Protocol Spread

Review `CartPayments.begin`, `finish`, `_fundPayment`, `_settlementTokens`,
`_verifySolvency`, `_prepareNativeFamily`, `_captureSupportedSpread`, and
`_verifyFinalBaselines`. Cover PAY-1, PAY-2, PAY-3, and PAY-4 with routing
and callbacks.

- Build a per-currency ledger for payer debit, router input and output,
  direct lines, each recipient credit, spread, and Cart's initial and final
  balances. Read balances independently of Cart's events.
- Exercise direct ETH, direct ERC-20, and mixed direct and routed lines.
  Check `msg.value` below, equal to, and above the signed amount. Include
  a contract payer with a different fulfillment recipient and treasury.
  A relayer with approval from somebody else cannot charge that account.
- Preload distinct nonzero ETH, WETH, payment-token, and named output
  balances. Route too little of one required token while overfunding another.
  Verify that a baseline or a surplus in another currency cannot fill the
  shortfall. Repeat with no actions, NFT callbacks, and payout callbacks.
- For ETH and WETH, cover a native shortfall filled by WETH, a WETH shortfall
  filled by native ETH, both exact forms funded, and combined shortfall.
  Check each individual baseline before and after conversions. Include the
  same recipient receiving ETH and WETH.
- Compare exact-input output excess and exact-output unused input. Test
  separate signed spread recipients on consecutive orders and spread to a
  contract. Check zero spread, a zero destination, a rejecting destination,
  and Cart itself as a destination when surplus is due.
- Test a zero-total order in native and ERC-20 currency with nonzero custody
  baselines. Confirm no zero-value transfers to recipients. Add a funded
  fee line beside a free Listing and check each stage independently.
- Exercise tokens that return no value, return false, revert, tax the
  transfer, charge the sender extra, rebase, or misreport balances. Distinguish
  a clean rejection from underpayment, overcharge, or access to preexisting
  assets. State which behavior can occur with a currency admitted by the
  builder.
- Test tracked assets sent back during final spread callbacks, and assets
  added or removed during earlier callbacks. Trace the order of token and ETH
  spread processing. For an unnamed intermediate asset, identify what the
  router can actually reach and what can become stranded.

Start with `CartOutcome.t.sol`, `CartSpreadRecipient.t.sol`,
`CartExternalBoundaries.t.sol`, `CartFree.t.sol`, and `CartInvariants.t.sol`.
Return balance and allowance snapshots for one valid mixed basket and one
late-failure case.

### 4. Trace the router and Permit2

Review `CartRoutePolicy.validate`, `CartPayments._validateRoute`,
`_executeRoute`, `_assertNoPreexistingApprovals`, `_assertAllowancesCleared`,
and [IPermit2Cart](../src/cart/IPermit2Cart.sol). Cover PAY-1, PAY-2, PAY-3, and
OPS-1 with custody and deployment.

- Compare the accepted byte values with the dispatcher in the pinned
  Universal Router. Test all 256 byte values against the expected set.
  Check both flag bits on accepted commands, forbidden families, empty
  commands, command/input mismatch, and value with an empty route.
- Trace each supported V2, V3, and V4 exact-input and exact-output template
  through the real router. Capture path direction, recipient encoding,
  payer flags, V4 nested actions, wrap or unwrap, sweep, and the final
  destination of unused input. Include native value and ERC-20 input.
- Combine multiple swap families with direct payment currency obligations
  and a Listing Split. Compare all actual outputs to the signed lines.
  Include mixed ETH/WETH, an ordinary intermediate token, and a signed
  `CURRENCY_SWAP` line.
- Try allowed commands with wrong recipient aliases, malformed path bytes,
  unsafe V4 actions, missing sweeps, or hostile pool hooks where production
  policy permits them. Observe whether the router rejects, Cart rejects for
  insufficient deltas, or the order succeeds with an unintended movement.
  A successful wrong-recipient route with all signed obligations met still
  requires an attribution and custody analysis.
- Preload the shared router separately from Cart. Determine whether an
  existing router balance can fund a payout or spread under an admitted
  template. Identify exactly which account owned each unit of value before
  the route. Check malformed plans that strand an untracked intermediate
  asset even if every named obligation is met.
- Trace spender, owner, token, amount, and expiry for both temporary
  allowance layers. Exercise exact spend, partial spend, zero spend, a
  revert, and `uint160` amount and `uint48` deadline boundaries. Check
  preexisting approval at either layer by itself, including a nonzero
  expired Permit2 amount.
- Verify revocation before the first NFT action, and recheck after the
  last spread transfer. Test an external contract that restores one layer
  during an NFT or payout callback. Inspect the payer's ordinary allowance
  separately from Cart's two temporary allowances.
- Try a different token, source account, spender, and route deadline.
  Check if any accepted command can reach an existing Cart asset beyond
  the intended quote using real dependencies. Separate a mock's ability to
  move arbitrary funds from a reproducible router or Permit2 path.

Start with `CartRoutePolicy.t.sol`, `CartRoutePolicyVerification.t.sol`,
`CartOutcome.t.sol`, and the Ethereum fork suites. Return a per-template
trace with actual command bytes, token deltas, and allowance states.

### 5. Recompute splits and grouped payouts

Review `CartValidation.validSplits`, `CartHashing.hashSplits`, and
`CartPayments._payLines`, `_allocateLine`, `_addPayout`, and
`_transferExact`. Cover AUTH-2, INV-2, PAY-1, PAY-4, and EVENT-1.

- Validate the zero-entry single-recipient case and split counts of 1, 16,
  and 17. Try a zero or Cart recipient, duplicate address, zero share,
  incorrect basis-point total, and first recipient different from the
  Listing's `paymentRecipient`.
- Reorder or replace split entries while keeping the old witness. Require
  failure even if total basis points and primary recipient are unchanged.
  Test an old-format Listing with no split field and a new-format Listing
  with an empty array separately.
- Compute a reference allocation with full-precision arithmetic. For each
  positive line, floor each secondary share independently and give the
  primary the remainder. Compare small amounts with zero secondary
  allocations, exactly divisible amounts, and values near `uint256`
  boundaries. Calculate the floor check using the full final line amount.
- Compare repeated lines of one Listing against splitting the combined
  amount. Use two 1-unit lines with a 50/50 split. Each line pays one unit
  to the primary and zero to the secondary. Verify the result stays the
  same when grouped transfers reduce the number of calls.
- Put the same collaborator on two Listings in different currencies, an
  unsplit line, and a fee line. Ensure only the authorized Listing terms
  allocate splits. Confirm each currency has its own payout, even for ETH
  and WETH or for tokens with the same decimals.
- Compare indexed aggregation against a simple ordered reference model.
  Generate colliding buckets, wrap from the last slot to the first, and
  merge an existing key after probing. Check that zero allocations create
  no transfer group and the first nonzero contribution retains failure
  attribution.
- Exercise callbacks in first-seen payout order, including the secondary
  entries processed before the primary for a split line. Make a later
  grouped recipient reject. Verify funding, NFT delivery, earlier recipient
  balances, Listing fills, the order ID, and logs all roll back.
- Compare `ListingSplitPaid` allocations with `OrderLineSettled` totals
  and actual grouped transfers. Expect zero-amount allocation logs for a
  positive split line when rounding produces zero. A free line has no
  monetary split events.

Start with `CartSplits.t.sol`, `CartAdvancedGas.t.sol`, and the two
mixed-currency split cases in the fork suite. Return the reference model and
a comparison of balances, allocation events, call order, and error index.

### 6. Verify NFT fulfillment and collection admission

Review `Cart._validateListing`, `_validateActions`,
`_executeFulfillment`, `CartValidation.isContractOwner`, and
`CartLens._assetAvailable`. Cover ACT-1, ACT-2, and EVENT-1 with inventory
and integration.

| Kind | Execute these cases |
| --- | --- |
| `ERC721_TRANSFER` | Exercise one-unit single-action delivery from the Listing seller. Try multiple actions, stale ownership, revoked token or operator approval, and an incompatible receiver. |
| `ERC1155_TRANSFER` | Split quantity across action recipients. Test repeated token IDs, insufficient balance after an earlier action, and a receiver rejecting a later action. |
| `ERC721_MINT_TO` | Exercise one `mintTo(address)` call per unit, multiple actions, and ordered `MintResult[]`. Try 0–31 bytes of return data, a dishonest token ID, and a revert on a later unit. |
| `ERC1155_MINT_TO` | Exercise one `mintTo(address,uint256,uint256)` call per action. Check quantity, token ID, owner and minter authority, and failure on a later action. |
| `NONE`, `OFF_CHAIN`, and `CURRENCY_SWAP` | Reject NFT actions. Verify the Listing requirements for `OFF_CHAIN` and platform-only shape for Currency Swaps. |

- Mutate action index, recipient, quantity, and action order under an
  existing signature. With a new valid signature, exercise out-of-range
  indices, zero recipients or quantities, missing actions, and quantity
  over- or under-coverage.
- Check code presence and collection owner at validation. Test reverting,
  absent, short, and malformed `owner()` results. Change ownership or
  minter authority after signing and after Lens preflight. Probe state
  changes during routing or an earlier action before a later mint call.
- Re-run the dishonest collection cases. Compare successful no-op
  transfers, mints to a different recipient, and false return data with
  actual state changes. Trace whether the real signing service admits the
  collection and how receipts represent the call.
- Test supported collection implementations and representative
  upgradeable collections. Capture the concrete mint selector, return
  shape, approval rules, and receiver behavior for each supported family.
  Record where upgrades to admitted collection code invalidate assumptions.
- Check that split recipients cannot source assets and that NFT recipients
  do not become payers. Verify the exact action and unit data in events
  and that logs and return data agree on successful ERC-721 mints.

Start with `CartAdversarial.t.sol`, `CartExternalBoundaries.t.sol`,
`CartVerification.t.sol`, `CartFree.t.sol`, and `CartSplits.t.sol`.
Return a table of supported collection contracts, admission criteria,
and test evidence for each delivery claim.

### 7. Challenge callbacks, rollback, and revocation

Trace the entire `executePurchase` sequence from validation through final
allowance checks. Cover ATOM-1, PAY-2, PAY-3, and ADMIN-1. Cross-check with
custody, payouts, fulfillment, and deployment.

- List each external call and whether it can mutate state. Include ERC-1271
  and owner checks, token balance and allowance reads, transfer and approve
  calls, router, WETH conversion, NFT safe receivers, payout recipients,
  and spread recipients.
- At each mutable boundary, attempt nested checkout with the same order ID
  and a separate valid funded order. Try each seller invalidation function.
  Verify state and recipient balances whether the callback catches the
  nested failure or bubbles it to the outer purchase.
- Check what callbacks can read after reservation and before payment.
  Trace any external reliance on provisional fill or execution state.
  For an owner contract that also receives a callback, review authorized
  admin operations separately from public reentrancy and state the
  required ownership or delegation.
- Fail at funding, route validation, router execution, allowance revocation,
  the last NFT action, the last split payout, spread, and final balance or
  allowance checks. Preload nonzero state so a regression cannot pass by
  resetting storage to zero.
- For each late failure, compare payer, recipient, router, token, Cart,
  approval, fill, replay, and log state before and after. Prove the same
  signed order can succeed if the transient cause is removed and
  authorization is still valid.
- Measure an admitted recipient or token returning large data, reverting
  with large data, consuming gas, or rejecting ETH. Distinguish a signed
  basket failing atomically from a lasting effect on other valid orders.
- While paused, verify checkout fails, reads still work, and sellers can
  invalidate. Exercise revoked approvals, changed contract-wallet policy,
  expired deadlines, and signer rotation between estimate and submission.
  Verify the right party can recover without weakening seller protection.

Start with `CartAdversarial.t.sol`, `CartExternalBoundaries.t.sol`,
`CartVerification.t.sol`, `CartOutcome.t.sol`, and the rejecting split
recipient cases. Return a call-boundary and rollback matrix.

### 8. Verify the proxy, executor, and rollout

Review `Cart.initialize`, `_authorizeUpgrade`, `_beginPayment`,
`_finishPayment`, `CartStorage`, both executor entry points, the
OpenZeppelin UUPS base, and the deployment scripts. Cover ADMIN-1 and OPS-1.

- Verify proxy initialization in the creation transaction. Try direct
  implementation initialization, a second proxy initialization, unauthorized
  admin calls and upgrades, and direct calls to both CartPayments entry
  points. Verify the actual owner and signer after deployment.
- Confirm the proxy supplies storage, caller, value, and log address through
  both delegatecalls. Check selector and struct encoding across matching and
  mismatched Cart and executor artifacts. Exercise an empty-code executor
  or incompatible return shape as an honest configuration error.
- Compare OpenZeppelin linear layout, gaps, and namespaces across the
  actual prior and target releases. Check the ERC-7201 constants, field
  packing, offsets, mapping keys, reentrancy state, and
  `__deprecatedProtocolRecipient` reservation.
- Seed nonzero fills, both cancellation maps, seller nonces, an executed
  order, a pending order, pause state, and live approval state. Upgrade
  through the proxy. Verify expected compatibility and repeat a purchase
  using the supported signatures and preexisting approvals.
- Verify dependency rotation with matching Cart and executor policy
  immutables. Simulate a stale executor alongside a new Cart policy.
  Compare Lens preview with execution on payloads above historical
  command limits and report each stale configuration signal.
- Exercise explicit owner transfer and signer rotation. Test the retiring
  owner and signer afterward. Include a wrong chain, unexpected proxy
  override, stale script checkout, absent code, and mismatched dependency
  fingerprint.
- Walk the deployment and recovery procedures below. Compare scripts with
  the actual owner wallet. If a script expects an EOA but the target owner
  is a multisig, validate the proposed multisig call on a fork.

Start with `CartStorageLayout.t.sol`, `CartAdversarial.t.sol`,
the pre-split bytecode fixture in `CartSplits.t.sol`, and the historical
deployment records. Return a storage, selector, and dependency comparison
tied to the exact implementation pair.

### 9. Verify client preflight, signing, and reconciliation

Review [CartLens](../src/cart/CartLens.sol), [CartHashes](../src/cart/CartHashes.sol),
[ICart events and errors](../src/cart/ICart.sol), and the
[transaction-builder handoff](cart-transaction-builder-handoff.md).
Cover AUTH-1, EVENT-1, OPS-1, and SIZE-1 with authorization, fulfillment,
and deployment.

- Compare `listingStatus`, `validateListing`, `validatePurchaseEnvelope`,
  and `previewRoute` with checkout using the same state and payload.
  Document what each preflight actually checks. Include swapped witnesses,
  stale inventory, missing actions, invalid funding, and opaque bad route
  inputs that pass the earlier preview.
- Inspect the signer entry point. Verify the service constructs canonical
  payloads or validates every client-provided field before signing. Test
  unauthorized fee or spread destinations, mutable SKU metadata, unsupported
  tokens and collections, inconsistent fee consolidation, and route inputs
  with undesired recipients or refund behavior.
- Check that the signer and builder bind the admission result to the exact
  payload and intended payer used for simulation. Change payer, value,
  witnesses, signed fields, or deployment between admission and release.
  Verify failed admission never releases a usable signature.
- Decode a real or fixture receipt using generated bindings. Reconcile the
  transaction payer, signed quote, line amounts, split allocations, router
  movement, tracked spread, and all NFT action units. Filter logs by the
  intended chain and proxy, including logs emitted through the executor.
- Verify that `OrderLineSettled.paymentRecipient` is interpreted as the
  primary recipient for split lines. Use `ListingSplitPaid` for allocation
  details and avoid treating each allocation as an independent transfer.
  Handle a zero rounded share, a free split Listing, and grouped transfers
  across repeated lines.
- Verify only `OFF_CHAIN` lines trigger external fulfillment. Process
  duplicate, out-of-order, and reorged receipts, as well as the same order ID
  on separate proxies or chains. Check the idempotency key
  `(chainId, cartProxy, orderId, lineIndex)` and actual reorg handling.
- Decode funding, routing, payout, spread, action, and baseline errors.
  Check line zero when the stage is order-wide, first contributing line
  for grouped payouts, and nested router or token reasons. Confirm the
  builder repairs a failed basket and obtains a new signature when signed
  terms change.
- Test a stale SDK paired with new Cart or stale Lens paired with a new
  implementation. Test old Orders, old Listing tuples including no splits,
  missing mint result decoding, and consumers expecting obsolete resource
  caps. Record the exact release order and fallback when client updates lag.

Start with `CartLens.t.sol`, `CartSpreadRecipient.t.sol`, the SDK vectors,
and the documented event schemas. Return a consumer inventory with versions,
an example receipt and decoded allocations, and any missing integration access.

### 10. Measure gas and verify transaction admission

Measure the complete signed checkout. Cover SIZE-1,
PAY-4, and ACT-2 with the builder, routing, and payout reviewers. Use the
[resource policy](cart-resource-policy.md) and
[split gas measurements](cart-split-verification.md#split-order-gas-measurements)
to select workloads.

| Workload | Vary independently | Inspect |
| --- | --- | --- |
| Direct native and ERC-20 | Free, one line, repeated currency/recipient, distinct recipients and currencies | Funding and exact-transfer checks, currency deduplication, per-currency scans, payout grouping |
| Seller authorization | Shared versus distinct roots, repeated Listings, proof depth and bytes, EOA versus ERC-1271 | Signature cache reuse, witness bytes, digest index collisions, allocation cost |
| Listing Splits | 0, 1, or 16 recipients, zero rounded shares, shared versus distinct addresses, mixed currencies | Payout count, indexed probing, per-line events, temporary memory and calldata |
| Routed orders | Command/input sizes, V2/V3/V4, exact input/output, partial spend, mixed native/WETH | Delegatecall encoding, router work, both approval layers, balance snapshots |
| NFT fulfillment | ERC-721 versus ERC-1155 transfers, mint units, number of actions and distinct recipients | Per-action and per-unit calls, receiver work, mint return arrays and logs |
| Rejection | Bad proof, stale approval, late NFT or payout failure, reverting recipient | Work before rejection, nested revert data, estimate failure and retry cost |
| Integration | Exact production payload across payer types, fee-grouping shapes, and wallet or relayer envelopes | Submitted limit, cold accounts, calldata and envelope bytes, provider acceptance |

1. Record the toolchain, EVM rules, fixture funding, cold and warm
   accounts, route state, and calldata. Measure execution, intrinsic
   calldata cost, simulated estimate, and receipt gas separately where
   available. Report a local call benchmark as a local call benchmark.
2. Use `CartAdvancedGas.t.sol` and the current split stress cases as
   regression points. Recheck the assumptions in `CartGasCapacity.t.sol`,
   `CartQuoteCapacity.t.sol`, `CartListingGas.t.sol`,
   `CartERC721Gas.t.sol`, and `CartRareERC1155Gas.t.sol` before applying
   historical results to the current implementation.
3. Trace the costs that grow with input shape. Include the Order Line
   hash buffer, Listing index probing, token deduplication, repeated
   settlement-currency scans, payout index probing, split logs, and
   copying dynamic data across delegatecalls.
4. Construct colliding Listing digests and payout keys at a known table
   size. Measure full execution, including the cost of producing admissible
   inputs. Distinguish ordinary expected probe growth from worst-case
   behavior and identify which actors control the keys.
5. Exercise resource limits before expensive decode, hashing, signing,
   or RPC. Count expanded ERC-721 mint operations, proof bytes, split
   allocations, route bytes, and wallet signature bytes independently.
   Verify an order above historical count caps can execute if admitted,
   and a small order with expensive components can be declined.
6. Confirm the current builder's policy and operator overrides. If it
   uses the handoff's starting limits, verify the ceiling calculation
   `(estimateGas * 125 + 99) / 100` against a 12,000,000 gas budget.
   Check both sides of the gas and byte boundaries with the actual sender,
   deployed proxy, funding, route, and seller witnesses.
7. Check retry behavior when relevant state moves between signing and
   inclusion. For a proposed split checkout, recompute fees, split
   rounding, routes, and separate order IDs. Verify receipts and partial
   completion when one of multiple checkouts fails.
8. Keep optimizations subject to authorization, first-seen payout order,
   error attribution, exact settlement, and final custody checks. Require
   before-and-after traces for any proposed change to these paths.

Return gas and byte measurements by workload, practical chain and provider
constraints, and a reproducer for any admission bypass or unbounded server work.

### 11. Audit the test and proof claims

Use the full baseline, [cleanup report](cart-cleanup-verification.md),
[split report](cart-split-verification.md),
[fork report](cart-mainnet-fork-verification.md), and
[Kontrol project](../verification/cart/README.md). Assign this workstream
to a reviewer who can compare tests across the other workstreams.

- Map each invariant to test names, assertions, input range, dependency
  type, and source fingerprint. Verify test discovery. Record a skipped
  suite, a fork setup failure, or an unreachable handler path as a
  coverage gap with a specific missing case.
- Distinguish an expected custom error from a generic revert. For
  rejection tests, prove the fixture would succeed without the targeted
  mutation. For late failures, seed and compare nonzero prior state.
- Inspect invariant handler selectors, action distribution, amount and
  caller bounds, and unexpected reverts. Add mixed split, routed, free,
  revocation, and replay sequences if current handlers omit them. Check
  that balances and allowances are sampled after both success and failure.
- Compare Listing and payout index implementations with simple reference
  models using ordered outputs, collision cases, and signed inputs.
  Compare payout amount and first-line attribution in addition to total gas.
- Rebuild the real pre-split bytecode fixture if auditing migration.
  Compare the source and bytecode hash against its recorded revision.
  Keep modeled old storage, historical artifact upgrade, and live
  deployed-proxy rehearsal as distinct checks.
- For current symbolic claims, rerun `verification/cart/prove.sh` in the
  pinned tool environment and retain the acceptance check output. Compare
  initial program bytes, tool and arithmetic module provenance, and
  source versions. Exercise the documented negative control and confirm
  it fails the deliberate assertion after successful settlement.
- Keep the proof scope explicit. The maintained specifications use
  fixed shapes, bounded amounts, modeled dependencies, and modeled
  signature behavior. Record pending paths, failed setup, resource limits,
  and unsupported claims separately. Native execution of a proof
  fixture is runtime coverage.

Return the invariant coverage table, exact missing tests, and any claim
that the currently available evidence cannot establish.

## Rehearse deployment, migration, and recovery

Perform rehearsals on a disposable chain or pinned fork with controlled
accounts. Use read-only calls to validate existing deployments. Treat
broadcast execution as a separate release operation. Cross-check the
[admin runbook](cart-runbook.md) and current [deployment scripts](../script/cart).

### Bring up a new suite

1. Identify the target chain in `NetworkConfig`. Verify code at WETH,
   Permit2, and Universal Router and record all three code hashes.
   Exercise the deployment script's optional Permit2 and router hash
   checks. Use the actual reviewed dependency versions and supported pools.
2. Confirm the owner and signer inputs. Test an unexpected deployer-owned
   proxy, an unusable signer, and a signer whose ERC-1271 policy rejects
   the intended digest.
3. Rehearse `CartDeploy.s.sol` and `deploy.sh`. Follow route policy,
   executor, implementation, and proxy creation in order. Confirm the
   ERC1967 proxy creation passes `initialize` calldata. Verify both
   embedded policy addresses and direct executor protection.
4. Verify separately deployed Lens and Hashes addresses and code.
   Read implementation, owner, pause, signer, router, Permit2, WETH,
   policy, and domain from the intended proxy. Compare the observed values
   with the recorded suite before exposing new checkout addresses.
5. Generate bindings and fresh vectors against the new domain. Approve the
   new proxy from test buyers, NFT holders, and collection owners. Execute
   a direct purchase, a routed purchase with spread and splits, and a
   free NFT purchase. Decode each receipt through the target client versions.

### Rehearse the three release paths

| Release path | Required compatibility evidence |
| --- | --- |
| Compatible implementation-only upgrade | Preserve the proxy, all storage, ordinary approvals, domain, pending compatible Orders, and seller witnesses. Check the configured executor and policy are still appropriate. Test a pre-upgrade order after upgrade. |
| Dependency rotation on the same proxy | Deploy compatible route policy, executor, implementation, and helpers. Check both embedded policy addresses. Router, Permit2, and WETH are stored configuration with no routine setter. Verify that stored dependencies remain unchanged unless the release explicitly includes a reviewed migration. |
| Fresh proxy and client cutover | Verify the new domain, approvals, signer configuration, and off-chain version switch. Old proxy fills, replay state, and cancellations remain on the old proxy. Retire the old entry point under the migration runbook and explicitly reconcile outstanding seller capacity. |

1. Test a storage-compatible but signature-incompatible release separately.
   In the spread-only change, rebuild Purchase Orders and checkout calldata.
   Seller signatures can survive on the same proxy where Listing types and
   domain are unchanged and the witness is still valid.
2. For the split-format change, rebuild the Listing tuple, digest, Merkle
   leaf, root, proof, platform order, and signatures, including empty splits.
   Seed a partially filled Listing before migration. Verify preserved
   historical storage and rejection of obsolete authorizations. Authorize
   only the seller-confirmed remaining quantity on the replacement digest.
3. Rehearse `upgrade-with-dependency-rotation.sh` in simulation mode.
   Inspect the actual owner, proxy override, chain, previous implementation,
   configured dependencies, new helper addresses, and encoded UUPS call.
   Compare the checkout guard with the candidate source. For the planned
   release, test clean, dirty, detached, and stale checkout cases.
4. Rehearse the expected sequence of separate deployment and upgrade
   transactions on a fork. Stop after new helpers deploy, after the proxy
   upgrade, and after an individual client cutover. At each stop, identify
   the active contract bundle, whether checkout should be paused, how to
   resume safely, and which signatures the builder may release.
5. Test going back to the previous implementation as its own migration.
   Compare storage, live dependencies, signature schemas, inventory buckets,
   and reactivation of old pending orders. Confirm how already executed
   replacement Listings affect old inventory before allowing rollback.
6. Record post-upgrade implementation and dependency fingerprints, proxy
   reads, the before-and-after state comparison, sample checkout receipts,
   and client revisions. Verify pause, signer rotation, and seller
   invalidation again using the exact target bundle.

### Walk emergency and failure paths

| Trigger | Rehearse |
| --- | --- |
| Wrong or unavailable platform signer | Pause if needed, rotate to the tested signer, rebuild outstanding quotes, simulate from the actual payer, and resume. Verify the consequences of rotating back. |
| Revoked seller authority | Recheck the exact cancellation, root, nonce, inventory, and token approvals. Rebuild only when the seller has issued fresh authorization where needed. |
| Rejecting payout or receiver | Reproduce the exact index and stage, repair the basket with the appropriate authority, and prove the failed order did not consume inventory or funds. |
| Unexpected route or stranded balance | Stop releasing affected quotes, reproduce with the actual route and dependency code, inspect asset custody, and document available recovery. Cart exposes no general rescue entry point. |
| Stale helper or ABI | Stop quote release for the mismatched suite, verify all deployed addresses and generated bindings, and re-simulate end-to-end before resuming. |
| Interrupted upgrade or ownership handoff | Read confirmed on-chain state before retrying. Check who can pause, upgrade, or rotate the signer, and reconcile current client configuration with confirmed transactions. |

## Use this reproduction matrix

Start with the cited suite or record. Add a focused test when the current
assertions leave a gap. The cases in this table are audit requirements.

| Invariant | Setup and action | Assert | Starting evidence |
| --- | --- | --- | --- |
| AUTH-1 | Keep the signature and mutate each signed array or field. Repeat on a different chain and proxy. | Reject before funding and reservation. | `CartVerification`, `CartAdversarial`, `CartSpreadRecipient`, `CartHashingBuffer` |
| AUTH-2 | Prove two valid leaves from different sellers in the same Merkle tree and reuse one root cache entry. | The first seller's signature cannot authorize the second. | `CartMerkle` |
| AUTH-2, INV-1 | Partially fill a Listing, switch its root, cancel the exact digest, and attempt both roots. | Alternate root shares the fill bucket. Exact cancellation blocks both. | `CartMerkle`, `CartListingIndex` |
| INV-1 | Two signed orders race for the last unit, with a late revert in one run. | Only a committed purchase consumes the unit and its order ID. | `CartVerification`, inventory proof model |
| INV-2 | Valid platform signature overrides a seller term or signs an under-floor amount. Include an overflow input. | Reject before payment. | `CartAdversarial`, `CartSplits` |
| ACT-1, ACT-2 | Several actions target different recipients, with a failing last mint unit. | Exact coverage, correct return order on success, full rollback on failure. | `CartExternalBoundaries`, `CartFree` |
| ACT-2, EVENT-1 | Seller supplies a collection that returns success and fake delivery data. | Determine what Cart records and whether the target builder admits the collection. | `CartAdversarial` and builder policy |
| PAY-1 | Use a processor as payer, a different NFT recipient, and a third spread recipient. | Exact debit, signed delivery, and signed spread. | `CartSpreadRecipient`, `CartOutcome` |
| PAY-1, PAY-4 | Two 1-unit split lines, a shared collaborator across currencies, and colliding payout buckets. | Per-line rounding, exact-currency grouping, and stable transfer order. | `CartSplits` and mixed-currency fork case |
| PAY-2 | Fund one output correctly and underfund another with nonzero Cart baselines. Repeat with ETH/WETH. | Reject cross-currency subsidy and preserve individual baselines. | `CartOutcome`, fork shortfall case |
| PAY-3 | Partially spend the quote, then restore one allowance layer in a callback. | Immediate revocation and final failure if an allowance remains. | `CartOutcome`, `CartExternalBoundaries`, approval proof model |
| PAY-4 | Route with unused input and excess output. Revert in the final recipient callback. | Spread belongs to the signed account. Failure rolls back earlier transfers and reservations. | `CartSpreadRecipient`, `CartExternalBoundaries` |
| ATOM-1 | Reject the last ETH payment after real swaps and earlier split payouts. | Compare all participants' balances and allowance amounts. No fills, replay state, or logs survive. | Mixed-currency fork rollback case |
| ATOM-1, ADMIN-1 | Attempt a second funded purchase and seller invalidation from a receiver. Invalidate separately while paused. | Guard nested calls and allow legitimate seller invalidation while paused. | `CartAdversarial`, `CartSplits`, `CartVerification` |
| ADMIN-1, OPS-1 | Upgrade a seeded proxy from actual historical bytecode and test stale and fresh signatures. | Stable storage and approval target, with signature validity matching the migration. | `CartStorageLayout`, pre-split case in `CartSplits` |
| EVENT-1 | Feed committed, duplicate, and reorged receipts with mixed line kinds to consumers. | Correct payer, allocation, spread, and mint attribution. External fulfillment only for applicable lines. | Fork receipt, SDK bindings, fulfillment worker |
| SIZE-1 | Change witnesses, payer, value, or route between estimation and release. Stress independent resource dimensions. | Admission matches the actual payload and releases no usable signature after a failed check. | Builder tests, Cart gas fixtures |

### Build one checkout for cross-workstream review

Use a caller funded in a supported ERC-20, a different NFT recipient, and a
third signed spread recipient. Start with nonzero Cart ETH, WETH, payment
token, and output token balances. Include a seller-signed split Listing with
two lines referencing one digest, a direct fee line, a routed ERC-20 output,
and a final native ETH payout funded by the route. Deliver one NFT action
and one off-chain line in the same Order. Use a partial-spend route that
returns unused input to Cart.

1. Record the canonical digests, seller witnesses, prior fills, payer
   allowance, exact calldata, router trace, and expected currency ledger.
2. Execute successfully and compare each signed obligation to its final
   allocation, balance, and receipt log. Verify replay, per-digest
   inventory, allowance cleanup, and custody restoration.
3. From the same initial state, make the last payable recipient reject.
   Compare all pre- and post-state, including NFT ownership and router
   state. Keep the original signature and repeat after restoring the
   recipient's ability to receive payment.
4. Repeat the route and settlement portion with the actual dependencies
   on a pinned fork. Record any controlled test substitution, including
   collection or receiver behavior.

## Triage findings and close the audit

1. Log each candidate once. Record the workstream, invariant, affected SHA
   and deployment, attacker capabilities, prerequisites, reproducer,
   observed effect, severity, confidence, and owner. Link duplicate
   discoveries as corroborating evidence.
2. Separate confirmed vulnerabilities, integration and operational risks,
   documentation mismatches, and coverage blockers. Keep modeled dependency
   failures distinct from confirmed production behavior.
3. Require a deterministic test or exact transaction sequence and a second
   review for every proposed high or medium finding. If a case depends on a
   target client or route, establish that the actual release can reach it.
   Mark incomplete cases as needing reproduction or missing access.
4. Assign severity by reachability and impact. Use the release's audit
   rubric when one exists. At minimum distinguish unauthorized loss,
   fulfillment or settlement bypass, persistent denial of service,
   failure of an individual signed basket, and diagnostics or test gaps.
   State the assets, actors, and number of purchases that can be affected.
5. For each accepted finding, define a remediation condition and the
   regression test that will demonstrate it. Rerun the smallest reproduction
   on the fix, then retest the neighboring invariant and deployment path
   affected by the change.
6. Deliver the findings by severity, a separate deployment and integration
   risk list, the invariant coverage table, gas and proof limitations,
   and unresolved blockers. Tie the report to the reviewed source and
   verified deployment configuration. If the release head changes, identify
   the affected workstreams and refresh their evidence before sign-off.
