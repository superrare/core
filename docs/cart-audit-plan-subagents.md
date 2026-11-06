# Audit the Cart contracts

Use this plan to audit SuperRare's atomic Cart checkout before a release or
upgrade. Pin the source, deployed configuration, and build inputs first.
Report reproducible failures of authorization, inventory, fulfillment, settlement,
or recovery, with separate evidence for each deployment and integration claim.

The coordinator records the audited revision and any uncommitted changes when
the audit starts. Use the [Cart design](cart-contract-design.md),
[Commerce terminology](../CONTEXT.md), and the three Cart ADRs to establish
intent. Use the Solidity source to establish what a call does. Record
disagreements between the two as audit questions until resolved.

## Set the scope

| Component | What to follow |
| --- | --- |
| [Cart and ICart](../src/cart/Cart.sol) | Proxy entry points, two layers of authorization, Listing resolution and inventory, action execution, admin, and receipt semantics. Use [ICart](../src/cart/ICart.sol) for canonical tuples, errors, and events. |
| [CartStorage](../src/cart/CartStorage.sol) | Config, seller authorization and inventory, and replay namespaces. Compare inherited storage and the [committed baseline](../src/cart/Cart.storage-layout.json). |
| [CartPayments and ICartPayments](../src/cart/CartPayments.sol) | Delegatecalled `begin` and `finish`, custody snapshots, Fixed Quote, route execution, approvals, split allocation, grouped payouts, and Protocol Spread. Review the [handoff types](../src/cart/ICartPayments.sol) across the implementation boundary. |
| [CartRoutePolicy](../src/cart/CartRoutePolicy.sol) | Accepted commands, flags, paths, recipient aliases, supported V4 actions, decoded endpoint assets, and pinned router interpretation. Review the asset-list return ABI used by CartPayments. Compare the policy embedded in Cart with the one embedded in CartPayments. |
| [CartHashing and CartHashes](../src/cart/CartHashing.sol) | Canonical EIP-712, ordered arrays, Merkle leaf encoding, optimized Order Line buffer, and the [client helper](../src/cart/CartHashes.sol). |
| [CartLens and CartValidation](../src/cart/CartLens.sol) | Advisory Listing, envelope, and route checks. Compare overlapping behavior with Cart and trace intentional differences. Review [shared validation](../src/cart/CartValidation.sol) and [Lens result types](../src/cart/ICartLens.sol). |
| [Deployment and upgrades](../script/cart) | Initialization, owner and signer handoff, matching-bundle and dependency-rotation scripts, helper deployment, checkout guard, and [NetworkConfig](../script/NetworkConfig.s.sol). |
| [Test and proof projects](../src/test/cart) | Local, adversarial, fuzz, invariant, historical-upgrade, and gas suites. Use [Ethereum fork tests](../src/test/forks/ethereum/cart), the [SDK vectors](data/cart-split-sdk-vectors.json), and [Kontrol](../verification/cart/README.md) as separate evidence. |

Review the actual Universal Router, Permit2, WETH, and supported token interfaces
as Cart dependencies. The audit covers contract code, deployed configuration,
and the on-chain ABI, events, and errors. Backend transaction construction,
signing-service implementation and quote release, and downstream consumer
behavior belong to separate reviews. Use fixture signatures to exercise the
on-chain boundary, including deliberately unsafe signed inputs. Record where
security depends on trusted quote construction, route semantics, or collection
admission.
Keep unrelated markets, auction houses, token issuance, and the rest of Uniswap
outside the audit unless a concrete Cart call crosses that boundary.

### Identify the actors and trust boundaries

| Actor | Authority and audit assumptions |
| --- | --- |
| Cart owner | Pauses checkout, changes the platform signer, transfers ownership, and authorizes UUPS upgrades. Assume honest administration. Test missing authorization, initialization, bad inputs, interrupted rollout, and unsafe handoff. Deliberate owner installation of hostile code is outside scope. |
| Platform signer | Authorizes the Purchase Order, all lines, the exact route and actions, and the spread destination. Verify signature enforcement and signer rotation on-chain. Even a valid platform signature must satisfy independent seller authorization and contract invariants. |
| Seller | Signs reusable Listing Roots. Can revoke a root, exact Listing, or earlier nonce. Controls Listing proceeds and may operate a hostile ERC-1271 account or token contract. Authority to sign a Listing does not grant authority over another account's NFTs. |
| Payer or payment processor | Calls the proxy and funds the Fixed Quote. A party with a usable quote can try to submit it using its own assets. Test replay and order consumption even when the payer, action recipients, and spread recipient are different accounts. |
| Payout, spread, and NFT recipients | May be unrelated contracts. Treat callbacks, reverting recipients, and overlapping roles as adversarial inputs. Listing Split recipients have payout rights only. |
| Configured router, Permit2, and WETH | Assume the reviewed deployment code. Test its actual response to allowed programs, shared balances, stale routes, real allowance state, and integration mistakes. Use hostile stand-ins to probe stated invariants and identify the production assumptions needed to reach a failure. |
| NFT and currency contracts | Test ordinary supported behavior and deliberate lies at every external boundary. Track which claims require exact-transfer ERC-20 behavior, conforming NFT contracts, or explicit builder admission. |

### Keep deliberate choices visible during triage

| Design choice | What to verify |
| --- | --- |
| Caller-funded checkout without a payer field or buyer signature. | `msg.sender` is the only ERC-20 funding source. A copied quote cannot take the original payer's assets or change delivery. Verify which order and inventory state a successful competing submission consumes. |
| Every purchase fixes the buyer charge and seller payouts. | Slippage changes platform spread when the signed `spreadRecipient` is the platform. Unused input and excess output return through Cart to that recipient. A shortfall reverts; the buyer is not charged more. Router exact-input/output coverage does not imply two user-facing checkout modes. |
| Seller witnesses are separate from the Purchase Order. | An alternate valid root can authorize the same Listing. All paths still enforce the exact signed digest, live root, proof, seller, nonce, and cancellation, with one fill bucket per digest. |
| Zero totals, free Listings, and zero-as-uncapped inventory are supported. | Free checkout preserves replay and fulfillment checks. Uncapped inventory still records fills. Test unavailable underlying assets and the intended relisting behavior. |
| Fees and Currency Swaps are platform-authorized peer lines. | Enforce their Listing and action restrictions. Cart receives explicit charge amounts and does not calculate commercial fees. |
| Route protection checks destinations and custody. | Test recipients, paths, supported V4 actions, and decoded endpoint assets under valid fixture signatures. Reject wrong destinations and additional tracked funds left in the router even when seller obligations could be met. Pool selection and pricing remain construction assumptions. |
| ETH and WETH share incremental solvency. | Keep exact payout currencies, independent protected baselines, and currency-specific payout aggregation. |
| The builder controls order size. | Measure checkout gas and enforce on-chain structural rules and the per-Listing split cap. Treat backend admission as an external control. |
| NFT fulfillment uses supported external calls. | Confirm behavior for supported collections. A successful call or a returned ERC-721 token ID establishes the call result. Actual delivery depends on collection behavior. Record the collection behavior the contracts rely on. |
| Stable proxy, separately deployed helpers. | Compatible upgrades preserve approvals and domain. Schema migrations require explicit signature and client handling. Lens previews are advisory. |

## Verify the invariants

Use these IDs in findings, reproductions, and the final coverage table.

| ID | Required result |
| --- | --- |
| AUTH-1 | An executable order has a nonzero unused order ID, valid current platform signature, live deadline, and exact signed line, route, and action hashes. Signatures bind the chain and Cart proxy. A change to signed fields without a new valid signature, or replay of a consumed order, fails before funds move. |
| AUTH-2 | Every referenced Listing resolves to one supplied digest and a valid seller witness. Root verification caches remain seller-bound. A root can be reused while valid. A cancelled root, cancelled Listing, or stale seller nonce cannot authorize a purchase. |
| INV-1 | All Order Lines referencing one Listing contribute to one cumulative fill, even across alternate roots or different Orders. Finite capacity cannot be exceeded. Failed checkout leaves prior fills and replay state intact. |
| INV-2 | Seller-backed line kind, SKU, settlement currency, and primary recipient match the Listing. The full line amount meets the per-unit proceeds floor times quantity, without arithmetic truncation. |
| ACT-1 | Each supported on-chain line is covered exactly by valid actions. The action source, recipient, quantity, token ID, and mint selector follow the authenticated Listing and signed action. Non-NFT lines have zero actions. |
| ACT-2 | For conforming collections, success delivers every authorized NFT transfer or mint. ERC-721 mint results and fulfillment logs correspond to action and unit order. A failed later action rolls back earlier delivery. |
| PAY-1 | The caller supplies exactly the Fixed Quote. Cart enforces signed router value, validates supported route commands and inputs, and pays each obligation in its exact currency. For a split line, independent per-line allocations conserve its full amount. |
| PAY-2 | A purchase cannot spend tracked preexisting funds. Cart protects independent ETH, WETH, payment-token, named settlement-token, and decoded route endpoint-token balances. Endpoint tracking is not a token whitelist. ETH/WETH may fund each other only through incremental assets. Success restores every tracked balance exactly. |
| PAY-3 | ERC-20 routing grants access to the quoted payment token through the configured two-layer Permit2 path. Nonzero preexisting allowances for that path are rejected. Temporary allowance amounts are zero before NFT fulfillment and again at successful completion. |
| PAY-4 | Positive tracked residuals after obligations go to the nonzero signed `spreadRecipient` in their actual currencies. Grouped payouts use exact currency and recipient, preserve first-seen order, and retain the first contributing line for failure attribution. |
| PAY-5 | Routing cannot increase the shared router's ETH or tracked token balances. Compare against pre-execution balances rather than requiring zero. Final swap output and sweeps return to Cart; only supported intermediate funding and wrap/unwrap steps may use the router alias. |
| ATOM-1 | A revert at any stage leaves no purchase, partial payout, asset delivery, fill, order consumption, or purchase logs. A callback cannot execute another purchase or mutate seller invalidation state through guarded entry points. |
| ADMIN-1 | Only the configured owner can pause, rotate the signer, or authorize upgrade. Proxy initialization runs once, the implementation is locked, and a compatible upgrade preserves live storage, approvals, and EIP-712 identity. Seller invalidation stays available while paused. |
| OPS-1 | The deployed proxy, implementation, executor, policies, dependencies, Lens, Hashes, and on-chain signer configuration agree for each target chain. Migration preserves required state and coordinates incompatible signatures and Listing capacity. |
| EVENT-1 | Committed proxy logs identify the payer and Fixed Quote, original lines and their kinds, exact split allocations, individual fulfillment operations, and Protocol Spread. |
| SIZE-1 | On-chain structural limits hold across payload shapes. Characterize gas and calldata growth for checkout and identify any inputs that can impair unrelated purchases. |

### State the assumptions behind each claim

For each invariant, record the permitted attacker control, required dependency
behavior, and observable failure. Use these boundaries when designing tests.

| Invariants | Assumptions and attacker control | Failure to detect |
| --- | --- | --- |
| AUTH-1, AUTH-2, INV-1, INV-2 | Assume standard signature and hash security. Callers control witnesses and calldata. Use valid hostile platform signatures as well as invalid signatures. Sellers can sign adversarial roots and share leaves across roots. | Accepting altered signed fields, another seller's authority, cancelled authorization, under-floor terms, or excess finite fills. These checks must hold even with a valid platform signature. |
| ACT-1, ACT-2 | Callers control signed action recipients and quantities. Conforming collections perform their declared operation and revert on failure. Test dishonest collections separately to establish the limit of the delivery guarantee. | Incorrect action coverage or asset source, incorrect delivery for a conforming collection, or surviving delivery after transaction failure. A dishonest collection's successful no-op requires an explicit trust-assumption disposition. |
| PAY-1, PAY-2, PAY-4 | Exact-transfer currencies report truthful balances. Use the actual reviewed router and WETH. A valid signature can authorize adversarial routing and arbitrary nonzero spread destinations. Payout recipients can run callbacks or reject payment. | Wrong currency or allocation, spending protected baselines, residuals sent outside the signed destination by Cart, or a committed partial settlement. Report route-directed transfers separately from Cart's residual transfers. |
| PAY-5 | Use pinned router alias/action semantics, truthful tracked-token balances, and valid fixture signatures. Preload router balances independently from Cart. | Accepted wrong final destinations, additional tracked funds left in the router, or omitted endpoint custody accounting. Probe intermediate assets and hooks separately to establish the limits of endpoint tracking and balance comparisons. |
| PAY-3 | The reviewed token and Permit2 implement their allowance interfaces. Callers control the signed route. Test dishonest approval implementations as dependency-boundary probes. | Excess temporary authority, overwriting preexisting authority, or nonzero temporary allowances at the required checkpoints. |
| ATOM-1, ADMIN-1 | EVM revert semantics hold. Public callers and callback contracts are hostile. The owner administers honestly and may make mistakes. Test owner-authorized callback behavior with its required authority stated. | Unauthorized entry, nested protected mutation, partial committed state, initialization takeover, or incompatible preserved state. Deliberate hostile owner upgrades remain outside scope. |
| OPS-1 | Pin the target chain, artifact bundle, configuration, and prior implementation. Assume no compatibility until checked for that pair. | Unexplained artifact mismatch, wrong dependency or immutable, or lost state or unintended signature validity across migration. |
| EVENT-1, SIZE-1 | Derive expected logs and workload costs from fixture inputs and independent state observations. Backend admission and downstream consumers remain external assumptions. | Incorrect committed receipt fields, violated on-chain structural rules, or persistent interference with independent valid purchases. |

For nonconforming tokens and hostile dependency stand-ins, record the minimum
behavior needed to trigger the result. A mock that can arbitrarily rewrite
balances does not establish that the reviewed deployment can do so.

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
   Record the compiler input and EVM target for the release artifact. If a
   rebuild differs from the deployed runtime, recover the original inputs
   or review and test the new artifact as a separate build.
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

   The [mainnet fork guide](cart-mainnet-fork-verification.md) describes
   what the pinned fixture covers. Record results for the audited revision.
6. Compare the [fresh Sepolia record](cart-sepolia-fresh-2026-11-01.md) and
   [receipt ledger](data/cart-sepolia-fresh-2026-11-01.json) to the current
   target chain and addresses. Confirm both the intended proxy and the retired
   proxy state if a migration relies on it. Verify the configured signer and
   helper addresses against the release configuration.
7. Record each baseline failure as a reproducible test failure, environment
   blocker, or missing artifact. Assign each blocker an owner and continue
   independent source review. Keep historical proof, unit, fork, and receipt
   evidence distinct.

### Review the highest-impact guarantees first

Complete the first pass for AUTH-1, AUTH-2, INV-1, INV-2, ACT-1, ACT-2,
PAY-1 through PAY-5, and ATOM-1 before allocating remaining effort to
diagnostic polish and optional optimization. Review ADMIN-1 and OPS-1 early
enough to catch artifact or migration blockers.

Require an independent second pass on signature enforcement, seller inventory,
custody, payout conservation, temporary approvals, and rollback even when the
first reviewer reports no finding. Each reviewer derives expected behavior from
the signed inputs and trust model before comparing the other reviewer's results.
Record disagreements and the evidence that resolves them. A serial reread by the
same reviewer leaves the independent-review requirement open.

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
| 1 | Fulfillment | 6. NFT execution and collection behavior | Interface reviewer checks emitted receipts. |
| 1 | Callbacks | 7. Atomicity and failure paths | Payouts and fulfillment agents review the same late-failure cases. |
| 1 | Upgrade | 8. Proxy, configuration, and rollout | Authorization agent checks domain and signature migration. |
| 1 | Interfaces | 9. Lens, ABI, and receipts | Upgrade agent checks deployment drift. |
| 1 | Capacity | 10. On-chain gas and griefing | Routing, payouts, and fulfillment agents provide workload cases. |
| 2 | Verification | 11. Test and proof claims | Coordinator matches independently reviewed evidence to every invariant. |
| 2 | Independent review | Signature enforcement, seller inventory, custody, payout conservation, approvals, and rollback | Re-derive the claims and challenge the first pass even when it reports no finding. |
| 2 | Reproduction | Credible high and medium candidates | Assign a second reviewer who did not file the candidate. |

With four total execution slots, keep the coordinator in one slot. Run
authorization and inventory, custody and routing, and proxy and rollout in the
three agent slots first. Then run payouts and callbacks, fulfillment and
interfaces, and capacity and verification. Start a focused follow-up as a slot
opens if evidence could change a high- or medium-severity decision. With a
single reviewer, run the same workstreams serially and revisit the independent
cross-checks after reproductions. Record any second-review gap as an open completion requirement.

### Require evidence from each agent

Return the source SHA, files and functions reviewed, invariant IDs, commands,
and results. For each candidate include the attacker, preconditions, call order,
expected and observed results, impact, proposed severity, and confidence. Mark
which facts came from a mock, a pinned fork, or a live read. Identify existing tests and missing assertions. Include the minimal
reproduction, preferably a Foundry test, or the exact transaction sequence.

For a proposed finding that spans boundaries, provide both sides of the call.
Examples include the signed fixture payload and router trace, the seller witness and fill
state, or the implementation upgrade and old ABI decoding. Return review
gaps with a concrete next check. Mark a reviewed design choice as confirmed
when the evidence matches its documented behavior.

## Execute the workstreams

### 1. Verify signed data and seller witnesses

Own the evidence for CASE-01, CASE-02.

Review `ICart`, `CartHashing`, `CartHashes`, and `Cart._validateOrderHashes`
and `_resolveRootListings`. Compare `CartLens` and the independent typed-data vectors.
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
  the fixture. Put leaves from two sellers in one actual tree and prove
  caching a valid first signature cannot authorize the second seller.
- Swap valid witnesses for the same Listing digest. Reject a mismatched root
  index, wrong proof, missing or extra Listing, duplicate supplied digest,
  root/signature array mismatch, and wrong seller nonce. Check if redundant
  witness data can affect execution, diagnostics, or gas.
- Verify signer rotation with outstanding orders, including rotating away
  and back before expiry. Confirm a successful order ID remains consumed
  even when a new valid signature uses the same ID and different terms.

Start with `CartVerification.t.sol`, `CartMerkle.t.sol`,
`CartHashingBuffer.t.sol`, `CartAuditDuplicateDigest.t.sol`,
`CartAdversarial.t.sol`, `CartSpreadRecipient.t.sol`, and the SDK vectors.
Return independent payload and digest vectors for any mismatch.

### 2. Verify Listing terms and inventory

Own the evidence for CASE-03, CASE-04, CASE-05.

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
  conversion. Compare the emitted line kind with the asset movements.

Start with `CartMerkle.t.sol`, `CartListingIndex.t.sol`,
`CartVerification.t.sol`, and `CartFree.t.sol`. Return a compact inventory
state model and a test for any difference between the model and Cart.

### 3. Reconcile funding, custody, and Protocol Spread

Own the evidence for CASE-08, CASE-10, CASE-12.

Review `CartPayments.begin`, `finish`, `_fundPayment`, `_settlementTokens`,
`_verifySolvency`, `_prepareNativeFamily`, `_captureSupportedSpread`, and
`_verifyFinalBaselines`. Cover PAY-1, PAY-2, PAY-3, PAY-4, and PAY-5 with routing
and callbacks.

- Build a per-currency ledger for payer debit, router input and output,
  direct lines, each recipient credit, spread, and Cart's initial and final
  balances. Read balances independently of Cart's events.
- Exercise direct ETH, direct ERC-20, and mixed direct and routed lines.
  Check `msg.value` below, equal to, and above the signed amount. Include
  a contract payer with a different fulfillment recipient and treasury.
  A relayer with approval from somebody else cannot charge that account.
- Preload distinct nonzero ETH, WETH, payment-token, and named output
  balances. Include a decoded endpoint token absent from settlement lines.
  Verify its baseline, spread distribution, and final custody restoration. Route too little of one required token while overfunding another.
  Verify that a baseline or a surplus in another currency cannot fill the
  shortfall. Repeat with no actions, NFT callbacks, and payout callbacks.
- For ETH and WETH, cover a native shortfall filled by WETH, a WETH shortfall
  filled by native ETH, both exact forms funded, and combined shortfall.
  Check each individual baseline before and after conversions. Include the
  same recipient receiving ETH and WETH.
- Keep the buyer charge and line payouts fixed on every purchase. Compare
  router exact-input output excess and exact-output unused input; both become
  signed spread after settlement. For native exact-output routes, unused ETH
  must first return to Cart through a sweep. This is not a buyer refund. Test
  separate signed spread recipients on consecutive orders and spread to a
  contract. Check zero spread, a zero destination, a rejecting destination,
  and Cart itself as a destination when surplus is due.
- Test a zero-total order in native and ERC-20 currency with nonzero custody
  baselines. Confirm no zero-value transfers to recipients. Add a funded
  fee line beside a free Listing and check each stage independently.
- Exercise tokens that return no value, return false, revert, tax the
  transfer, charge the sender extra, rebase, or misreport balances. Distinguish
  a clean rejection from underpayment, overcharge, or access to preexisting
  assets. State which behavior requires a nonconforming currency.
- Test tracked assets sent back during final spread callbacks, and assets
  added or removed during earlier callbacks. Trace the order of token and ETH
  spread processing. For an unnamed intermediate asset, identify what the
  router can actually reach and what can become stranded.

Start with `CartOutcome.t.sol`, `CartSpreadRecipient.t.sol`,
`CartExternalBoundaries.t.sol`, `CartFree.t.sol`, and `CartInvariants.t.sol`.
Return balance and allowance snapshots for one valid mixed basket and one
late-failure case.

### 4. Trace the router and Permit2

Own the evidence for CASE-10, CASE-11, CASE-21, CASE-22, CASE-23.

Review `CartRoutePolicy.validate`, `CartPayments._validateRoute`,
`_executeRoute`, `_assertNoPreexistingApprovals`, `_assertAllowancesCleared`,
and [IPermit2Cart](../src/cart/IPermit2Cart.sol). Cover PAY-1, PAY-2, PAY-3,
PAY-5, and OPS-1 with custody and deployment.

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
- Require V2/V3 final output and sweeps to use `MSG_SENDER`, address `1`,
  which resolves to Cart. Reject other wallets, including a seller or an
  explicit Cart address. Wrap/unwrap may use caller or router aliases;
  Permit2 prefunding may use only the router alias, address `2`.
- Restrict V4 to one swap action, `0x06` through `0x09`, followed by
  `SETTLE_ALL` and `TAKE_ALL`. Reject arbitrary take recipients, extra actions,
  unsupported settlement forms, malformed arrays, and invalid V2/V3 paths.
  The router still validates swap payloads and executes pools and hooks.
- Sign a wrong-recipient route whose quote can still pay every seller.
  Require rejection before routing. Separately omit a native refund or leave
  tracked ERC-20 input/output behind. Require the post-execution balance check
  to reject and roll back the purchase. Probe hostile hooks and token side
  effects to identify transfers outside the supported route guarantees.
- Preload the shared router separately from Cart. Determine whether an
  existing router balance can fund a payout or spread under an admitted
  template. Identify exactly which account owned each unit of value before
  the route. Check malformed plans that strand an untracked intermediate
  asset even if every named obligation is met. Include a decoded endpoint
  absent from settlement lines. Verify independent router ETH/token snapshots
  immediately before execution and require no increase afterward. A shared
  balance comparison does not prove the provenance of individual funds.
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
`CartRouteProtection.t.sol`, `CartOutcome.t.sol`, and the Ethereum fork suites.
Use the [route protection specification](cart-route-protection.md) for accepted
forms and ABI compatibility. Return a per-template
trace with actual command bytes, token deltas, and allowance states.

### 5. Recompute splits and grouped payouts

Own the evidence for CASE-09, CASE-13.

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

### 6. Verify NFT fulfillment and collection behavior

Own the evidence for CASE-06, CASE-07.

Review `Cart._validateListing`, `_validateActions`,
`_executeFulfillment`, `CartValidation.isContractOwner`, and
`CartLens._assetAvailable`. Cover ACT-1, ACT-2, and EVENT-1 with inventory
and interfaces.

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
  actual state changes. Identify what the contract proves about delivery and
  what the receipt reports when the collection lies.
- Test supported collection implementations and representative
  upgradeable collections. Capture the concrete mint selector, return
  shape, approval rules, and receiver behavior for each supported family.
  Record where upgrades to admitted collection code invalidate assumptions.
- Check that split recipients cannot source assets and that NFT recipients
  do not become payers. Verify the exact action and unit data in events
  and that logs and return data agree on successful ERC-721 mints.

Start with `CartAdversarial.t.sol`, `CartExternalBoundaries.t.sol`,
`CartVerification.t.sol`, `CartFree.t.sol`, and `CartSplits.t.sol`.
Return the collection contracts tested, the behavior each claim assumes,
and evidence for each delivery claim.

### 7. Challenge callbacks, rollback, and revocation

Own the evidence for CASE-11, CASE-12, CASE-13, CASE-14, CASE-18.

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

Own the evidence for CASE-15, CASE-20, CASE-24.

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
  Verify that `validate(bytes,bytes[])` returns the asset list required by
  the executor even though its selector is unchanged. Detect a legacy policy
  paired with the new executor and regenerate affected policy ABI consumers.
  Compare Lens preview with execution on decoded inputs and payloads above
  historical command limits; report each stale configuration signal.
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

### 9. Verify Lens, ABI, and on-chain receipts

Own the evidence for CASE-16.

Review [CartLens](../src/cart/CartLens.sol), [CartHashes](../src/cart/CartHashes.sol),
and [ICart events and errors](../src/cart/ICart.sol). Cover AUTH-1, EVENT-1,
and OPS-1 with authorization, fulfillment, and deployment.

- Compare `listingStatus`, `validateListing`, `validatePurchaseEnvelope`,
  and `previewRoute` with checkout using the same state and payload.
  Include swapped witnesses, stale inventory, missing actions, invalid
  funding, wrong recipients, rejected V4 actions, and runtime failures that
  a static preview cannot establish. Preview must share policy input checks;
  it does not execute the router or perform before/after custody checks.
- Decode a receipt with the compiled ABI. Compare payer, quote, signed
  line kinds, split allocations, actual transfers, spread, and NFT action
  units. Confirm delegatecalled events come from the proxy. Include a
  zero rounded share, a free split Listing, and grouped transfers.
- Decode funding, routing, payout, spread, action, and baseline errors.
  Check line zero for order-wide failures, first contributing line for
  grouped payouts, and nested router or token reasons where present.
- Compare current and prior selectors, tuples, events, and mint return
  types. Check stale Lens behavior against the new implementation and
  record the external compatibility consequences of changed signatures.

Start with `CartLens.t.sol`, `CartSpreadRecipient.t.sol`, and the SDK
vectors. Return a decoded receipt and any contract-level ABI differences.

### 10. Measure gas and assess on-chain griefing

Own the evidence for CASE-17.

Measure the complete signed checkout. Cover SIZE-1, PAY-4, and ACT-2
with the routing and payout reviewers. Use the
[resource policy](cart-resource-policy.md) and
[split gas fixtures](cart-split-verification.md#split-order-gas-measurements)
to select workloads.

| Workload | Vary independently | Inspect |
| --- | --- | --- |
| Direct native and ERC-20 | Free, one line, repeated currency/recipient, distinct recipients and currencies | Funding and exact-transfer checks, currency deduplication, per-currency scans, payout grouping |
| Seller authorization | Shared versus distinct roots, repeated Listings, proof depth and bytes, EOA versus ERC-1271 | Signature cache reuse, witness bytes, digest index collisions, allocation cost |
| Listing Splits | 0, 1, or 16 recipients, zero rounded shares, shared versus distinct addresses, mixed currencies | Payout count, indexed probing, per-line events, temporary memory and calldata |
| Routed orders | Command/input sizes, V2/V3/V4, router exact input/output, partial spend, mixed native/WETH, endpoint count, native sweep | Input decoding, asset-list return encoding, deduplication, router and Cart snapshots, approval layers, refund and spread transfers |
| NFT fulfillment | ERC-721 versus ERC-1155 transfers, mint units, number of actions and distinct recipients | Per-action and per-unit calls, receiver work, mint return arrays and logs |
| Rejection | Bad proof, stale approval, late NFT or payout failure, reverting recipient | Work before rejection, nested revert data, estimate failure and retry cost |
| Full checkout | Payer types, fee-grouping shapes, and realistic combined workloads | Cold accounts, calldata bytes, and execution gas |

1. Record the toolchain, EVM rules, fixture funding, cold and warm
   accounts, route state, and calldata. Measure execution, intrinsic
   calldata cost, simulated estimate, and receipt gas separately where
   available. Report a local call benchmark as a local call benchmark.
2. Use `CartAdvancedGas.t.sol` and the current split stress cases as
   regression points. Include native V4 refund/spread benchmarks from
   `CartUniversalRouterTemplatesEthereum.t.sol`, with a separate signed
   platform spread recipient. Distinguish protection overhead on an unchanged
   route from the cost of adding a native cleanup instruction. Simple native
   and complex NFT checkout totals are not directly comparable. Recheck the assumptions in `CartGasCapacity.t.sol`,
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
5. Vary expanded ERC-721 mint operations, proof bytes, split allocations,
   route bytes, and wallet signature bytes independently. Check on-chain
   structural limits and trace where execution cost grows.
6. Separate one oversized or reverting purchase from persistent denial of
   service. Check whether an adversarial call can leave state that increases
   the cost or prevents execution of a separate valid checkout.
7. Keep optimizations subject to authorization, first-seen payout order,
   error attribution, exact settlement, and final custody checks. Require
   before-and-after traces for any proposed change to these paths.

Return gas and calldata measurements by workload and a reproducer for
any persistent effect on unrelated checkouts.

### 11. Audit the test and proof claims

Own the evidence for CASE-18, CASE-19.

Use the full baseline, [refactor verification guide](cart-cleanup-verification.md),
[split verification guide](cart-split-verification.md),
[fork verification guide](cart-mainnet-fork-verification.md), and
[Kontrol project](../verification/cart/README.md). Assign this workstream
to a reviewer who can compare tests across the other workstreams.

- Map each invariant to test names, assertions, input range, dependency
  type, and source fingerprint. Verify test discovery. Record a skipped
  suite, a fork setup failure, or an unreachable handler path as a
  coverage gap with a specific missing case.
- Distinguish an expected custom error from a generic revert. For
  rejection tests, prove the fixture would succeed without the targeted
  mutation. For late failures, seed and compare nonzero prior state.
- Complete CASE-18 with stateful sequences that include mixed split,
  routed, free, revocation, replay, and failed purchases. Inspect handler
  selectors, action distribution, amount and caller bounds, and unexpected
  reverts. Sample balances, allowances, inventory, and replay state after
  every step.
- Compare Listing and payout index implementations with simple reference
  models using ordered outputs, collision cases, and signed inputs.
  Compute expected values without calling the production hashing,
  allocation, or index helpers being tested. Compare payout amount and
  first-line attribution in addition to total gas. Complete CASE-19 to
  demonstrate that the critical assertions detect deliberately broken code.
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

### Require stateful sequences and effective test assertions

CASE-18 must exercise this sequence with an independent inventory and currency
ledger. Begin with nonzero custody baselines and more than one seller.

1. Partially fill a split Listing, then authorize the same digest through
   another root and fill it again.
2. Attempt overfill and replay. Reject both without changing the ledger.
3. Execute a routed purchase with NFT fulfillment and fail its final payout.
   Check all participants' balances, NFT ownership, approvals, fills, and
   replay state. Include the router's tracked balances and Cart's decoded
   endpoint assets in the independent ledger. Remove the transient failure
   and retry the original order.
4. Cancel a root, cancel an exact Listing, and invalidate a seller nonce in
   separate branches from the same prior state. Confirm each rejection and
   the continued validity of unaffected sellers and authorizations.
5. Rotate the platform signer with an unexecuted order outstanding. Check
   old and replacement signatures, then rotate back and test the still-live
   old authorization. A consumed order remains consumed.
6. Execute a free Listing and an independent valid purchase after failures.
   Compare model and contract state after each operation.

Keep a deterministic sequence as a reproducible witness and add generated
sequences with varied actors and operation ordering. Report successful and
expected-rejection counts per operation. An unreached operation remains a gap.

CASE-19 uses disposable source copies to introduce three faults independently.
Remove root-cache seller binding, allocate splits after aggregating line amounts,
and omit the final allowance check. For each fault, first run its positive
baseline, then identify the failing assertion that detects the changed behavior.
Use the allowance-restoring callback for the third case. Compilation failure,
setup failure, or an unrelated revert does not count as detection. If the fault
survives, strengthen the relevant test and repeat. Keep faulted code isolated
from proposed production changes.

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
   free NFT purchase. Decode each receipt with the release ABI.

### Rehearse the three release paths

| Release path | Required compatibility evidence |
| --- | --- |
| Compatible implementation-only upgrade | Preserve the proxy, all storage, ordinary approvals, domain, pending compatible Orders, and seller witnesses. Confirm the existing executor ABI and embedded policies are compatible. Rehearse the owner-authorized UUPS call on a fork. The checked-in implementation-only script always reverts. Test a pre-upgrade order after upgrade. |
| Dependency rotation on the same proxy | Deploy compatible route policy, executor, implementation, and helpers. Check both embedded policy addresses. Router, Permit2, and WETH are stored configuration with no routine setter. Verify that stored dependencies remain unchanged unless the release explicitly includes a reviewed migration. |
| Fresh proxy | Verify the new domain, approvals, signer configuration, and helper addresses. Old proxy fills, replay state, and cancellations remain on the old proxy. Retire the old entry point under the migration runbook and explicitly reconcile outstanding seller capacity. |

1. Test a storage-compatible but signature-incompatible release separately.
   In the spread-only change, rebuild Purchase Orders and checkout calldata.
   Seller signatures can survive on the same proxy where Listing types and
   domain are unchanged and the witness is still valid.
2. For the split-format change, rebuild the Listing tuple, digest, Merkle
   leaf, root, proof, platform order, and signatures, including empty splits.
   Seed a partially filled Listing before migration. Verify preserved
   historical storage and rejection of obsolete authorizations. Authorize
   only the seller-confirmed remaining quantity on the replacement digest.
3. For route-protection rotation, deploy matching policy, executor, and Cart
   implementation artifacts. Verify both embedded policies and the new asset-list
   return ABI. Test rejection of legacy mixtures. At the contract integration
   boundary, execute a signed native exact-output route with its final ETH sweep;
   require fixed buyer charge, fixed seller payouts, and signed platform spread.
   Missing cleanup must revert. Confirm the required builder route format before
   deployment; backend implementation review remains separate.
   For a matching replacement bundle that retains the route policy, rehearse
   `upgrade-cart-lens-and-hashes.sh`. For policy and executor rotation,
   rehearse `upgrade-with-dependency-rotation.sh`. Use simulation mode.
   Inspect the actual owner, proxy override, chain, previous implementation,
   configured dependencies, new helper addresses, and encoded UUPS call.
   Compare the checkout guard with the candidate source. For the planned
   release, test clean, dirty, detached, and stale checkout cases.
4. Rehearse the expected sequence of separate deployment and upgrade
   transactions on a fork. Stop after new helpers deploy, after the proxy
   upgrade. At each stop, identify the active contract bundle, whether
   checkout should be paused, how to resume safely, and which signature
   formats the proxy accepts.
5. Test going back to the previous implementation as its own migration.
   Compare storage, live dependencies, signature schemas, inventory buckets,
   and reactivation of old pending orders. Confirm how already executed
   replacement Listings affect old inventory before allowing rollback.
6. Record post-upgrade implementation and dependency fingerprints, proxy
   reads, the before-and-after state comparison, and sample checkout receipts.
   Verify pause, signer rotation, and seller
   invalidation again using the exact target bundle.

### Walk emergency and failure paths

| Trigger | Rehearse |
| --- | --- |
| Wrong or unavailable platform signer | Pause if needed, rotate to a fixture signer, and check rejection of old signatures and acceptance of new ones. Verify the consequences of rotating back. |
| Revoked seller authority | Recheck the exact cancellation, root, nonce, inventory, and token approvals. Rebuild only when the seller has issued fresh authorization where needed. |
| Rejecting payout or receiver | Reproduce the exact index and stage, repair the basket with the appropriate authority, and prove the failed order did not consume inventory or funds. |
| Unexpected route or stranded balance | Reproduce with the actual route and dependency code, inspect asset custody, and document available recovery. Cart exposes no general rescue entry point. |
| Stale helper or ABI | Verify deployed addresses and the compiled ABI. Simulate checkout with the matching contract bundle. |
| Interrupted upgrade or ownership handoff | Read confirmed on-chain state before retrying. Check who can pause, upgrade, or rotate the signer, and verify the active contract bundle against confirmed transactions. |

## Use this reproduction matrix

Start with the cited suite or record. Add a focused test when the current
assertions leave a gap. This table is the required-case register. Track each
case once by its stable ID, linking workstream evidence and findings to that
record. A case can require several tests. Workstream bullets describe additional
probes and do not create duplicate completion records.

| Case | Invariant | Setup and action | Assert | Starting evidence |
| --- | --- | --- | --- | --- |
| CASE-01 | AUTH-1 | Keep the signature and mutate each signed array or field. Repeat on a different chain and proxy. | Reject before funding and reservation. | `CartVerification`, `CartAdversarial`, `CartSpreadRecipient`, `CartHashingBuffer` |
| CASE-02 | AUTH-2 | Prove two valid leaves from different sellers in the same Merkle tree and reuse one root cache entry. | The first seller's signature cannot authorize the second. | `CartMerkle` |
| CASE-03 | AUTH-2, INV-1 | Partially fill a Listing, switch its root, cancel the exact digest, and attempt both roots. | Alternate root shares the fill bucket. Exact cancellation blocks both. | `CartMerkle`, `CartListingIndex` |
| CASE-04 | INV-1 | Two signed orders race for the last unit, with a late revert in one run. | Only a committed purchase consumes the unit and its order ID. | `CartVerification`, inventory proof model |
| CASE-05 | INV-2 | Valid platform signature overrides a seller term or signs an under-floor amount. Include an overflow input. | Reject before payment. | `CartAdversarial`, `CartSplits` |
| CASE-06 | ACT-1, ACT-2 | Several actions target different recipients, with a failing last mint unit. | Exact coverage, correct return order on success, full rollback on failure. | `CartExternalBoundaries`, `CartFree` |
| CASE-07 | ACT-2, EVENT-1 | Seller supplies a collection that returns success and fake delivery data. | Compare the committed receipt and token state to establish the collection trust assumption. | `CartAdversarial` |
| CASE-08 | PAY-1 | Use a processor as payer, a different NFT recipient, and a third spread recipient. | Exact debit, signed delivery, and signed spread. | `CartSpreadRecipient`, `CartOutcome` |
| CASE-09 | PAY-1, PAY-4 | Two 1-unit split lines, a shared collaborator across currencies, and colliding payout buckets. | Per-line rounding, exact-currency grouping, and stable transfer order. | `CartSplits` and mixed-currency fork case |
| CASE-10 | PAY-2 | Fund one output correctly and underfund another with nonzero Cart baselines. Repeat with ETH/WETH. | Reject cross-currency subsidy and preserve individual baselines. | `CartOutcome`, fork shortfall case |
| CASE-11 | PAY-3 | Partially spend the quote, then restore one allowance layer in a callback. | Immediate revocation and final failure if an allowance remains. | `CartOutcome`, `CartExternalBoundaries`, approval proof model |
| CASE-12 | PAY-4 | Route with unused input and excess output. Revert in the final recipient callback. | Spread belongs to the signed account. Failure rolls back earlier transfers and reservations. | `CartSpreadRecipient`, `CartExternalBoundaries` |
| CASE-13 | ATOM-1 | Reject the last ETH payment after real swaps and earlier split payouts. | Compare all participants' balances and allowance amounts. No fills, replay state, or logs survive. | Mixed-currency fork rollback case |
| CASE-14 | ATOM-1, ADMIN-1 | Attempt a second funded purchase and seller invalidation from a receiver. Invalidate separately while paused. | Guard nested calls and allow legitimate seller invalidation while paused. | `CartAdversarial`, `CartSplits`, `CartVerification` |
| CASE-15 | ADMIN-1, OPS-1 | Upgrade a seeded proxy from actual historical bytecode and test stale and fresh signatures. | Stable storage and approval target, with signature validity matching the migration. | `CartStorageLayout`, pre-split case in `CartSplits` |
| CASE-16 | EVENT-1 | Decode a receipt with mixed line kinds and delegatecalled settlement events. | Correct proxy, payer, line kind, allocation, spread, and mint attribution. | Fork receipt and compiled ABI |
| CASE-17 | SIZE-1 | Stress independent calldata and execution dimensions. Follow an oversized or reverted purchase with a valid independent checkout. | Structural limits hold and a failed call leaves no persistent effect. | Cart gas fixtures and rollback suites |
| CASE-18 | AUTH-1, AUTH-2, INV-1, PAY-1 through PAY-5, ATOM-1 | Execute the required stateful sequence and varied generated histories. | Independent ledgers match after every successful and rejected operation. | Stateful-sequence requirements in workstream 11 |
| CASE-19 | AUTH-2, PAY-1, PAY-3 | Introduce each specified fault in an isolated copy. | A targeted assertion detects each fault after its unchanged baseline succeeds. | Test-assertion requirements in workstream 11 |
| CASE-20 | OPS-1 | Run the broadcast branches of the Cart wrappers against a disposable RPC node. | Deployment and upgrade transactions use node gas estimates with the configured multiplier and confirm sequentially. Required preflight checks still run. | Cart shell wrappers, Python sender, RPC request and receipt logs |
| CASE-21 | PAY-1, PAY-5, ATOM-1 | Sign a wrong output or sweep recipient while leaving enough quote to pay all sellers. | Reject before router execution. Restore payer funds, fills, and replay state. | `CartRoutePolicy`, `CartRouteProtection`, fork third-party recipient cases |
| CASE-22 | PAY-4, PAY-5, ATOM-1 | Omit native cleanup from an exact-output V4 route, then repeat with a sweep and distinct platform spread recipient. | Missing cleanup reverts despite sufficient seller output. With cleanup, the buyer pays the fixed quote, sellers receive signed amounts, and unused ETH becomes platform spread. | `CartRouteProtection`, native V4 refund/spread fork cases |
| CASE-23 | PAY-2, PAY-5 | Leave additional tracked tokens in a preloaded router; include a decoded endpoint absent from settlement lines. | Compare against existing router balances, reject increases, and include endpoint assets in Cart custody and spread accounting. | `CartRouteProtection`, `CartRoutePolicy`, custody and fork fixtures |
| CASE-24 | OPS-1 | Pair the new executor with a legacy policy or mismatched embedded policies. | Detect the incompatible asset-list return ABI and bundle configuration before deployment. Verify matching bundles preserve checkout hashing and storage. | Artifact verification, deployment rehearsal, Lens and routing fixtures |

### Combine the required cases in one checkout

Combine CASE-08 through CASE-13. Use a caller funded in a supported ERC-20,
a different NFT recipient, and a third signed spread recipient. Start with
nonzero Cart ETH, WETH, payment
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

## Apply completion criteria

Maintain one coverage record per invariant with these fields.

| Field | Required evidence |
| --- | --- |
| Scope | Audited source SHA, artifact fingerprint, configuration, assumptions, and attacker-controlled inputs |
| Review | Owner, code paths and external-call boundaries reviewed, independent reviewer, and resolved disagreements |
| Execution | Required case IDs, test names, commands, result locations, and independent expected values |
| Limits | Unsupported dependency behavior, unexecuted paths, environment blockers, and open questions |
| Disposition | Confirmed findings, fix and retest evidence, or the reason the claim holds within its stated assumptions |

Mark an invariant complete only when its applicable cases and review requirements
are satisfied. An excluded case needs a concrete applicability reason. A blocked
case stays open. For each unresolved finding, record severity, impact, owner,
and either remediation evidence or explicit acceptance by the release owner.
A passing suite alone does not close a finding.

Source-review completion requires coverage records for every invariant, completion
of CASE-18 and CASE-19, the required independent reviews, and dispositions for
all candidates. If any requirement is missing, report the review as partial.

Release-artifact verification additionally requires a reproducible candidate
build, verified dependencies and immutables, and execution against the exact
candidate bundle on the target chain's recorded state. For an existing proxy,
require the applicable seeded-state upgrade and rollback rehearsal. For a fresh
proxy, require initialization, domain, approval, and configuration checks.
Complete CASE-20 on a disposable node with the candidate toolchain. Capture
RPC estimation requests, configured gas margins, transaction order, and receipt
confirmation for each changed broadcast path. Dry-run simulation covers a
different script branch.

Record source-review completion and release-artifact verification separately.
Identify which evidence a new source change, compiler setting, dependency, or
configuration invalidates and rerun those checks before updating either status.
Backend transaction construction and signing-service review remain outside both
completion criteria.

## Triage findings and close the audit

1. Log each candidate once. Record the workstream, invariant, affected SHA
   and deployment, attacker capabilities, prerequisites, reproducer,
   observed effect, severity, confidence, and owner. Link duplicate
   discoveries as corroborating evidence.
2. Separate confirmed vulnerabilities, integration and operational risks,
   documentation mismatches, and coverage blockers. Keep modeled dependency
   failures distinct from confirmed production behavior.
3. Require a deterministic test or exact transaction sequence and a second
   review for every proposed high or medium finding. If a case depends on a particular route or dependency, establish which
   signed input and deployment make it reachable.
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
