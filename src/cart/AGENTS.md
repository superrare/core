# Cart source standards

Apply these instructions to files under `src/cart/`. Use the
[Cart design](../../docs/cart-contract-design.md) for behavior and
[Commerce terminology](../../CONTEXT.md) for names. Use the
[audit plan](../../docs/cart-audit-plan-subagents.md) for review coverage and
the [runbook](../../docs/cart-runbook.md) for deployment and administration.

## Interfaces and types

- Keep Cart interfaces next to their implementations in `src/cart/`. Use
  `I<ContractName>` for new interfaces. Declare new supported entry points in
  the existing interface when the component has one. Keep interface additions
  tied to a caller or integration.
- Use [ICart.sol](ICart.sol) as the canonical checkout ABI. Put shared
  checkout structs, enums, events, and errors there. Keep route-policy and
  Lens declarations in their own interfaces. Use [ICartPayments.sol](ICartPayments.sol)
  for the delegatecall boundary, including the `PaymentState` handoff.
  Keep execution-only structs in the component that owns them.
- Keep any local declaration of a Cart receipt event in `CartPayments`
  identical to `ICart`, including field order and indexing. The executor
  emits those logs at the proxy address during delegatecall.
- Expose a new getter deliberately when consumers need it. Prefer an explicit
  camelCase getter for new API. Preserve established names such as
  `DOMAIN_SEPARATOR()` and `routePolicy()` for compatible changes.
- Review public and external functions for a supported use when cleaning up
  a component. Trace callers through interfaces, scripts, generated bindings,
  and deployed integrations before proposing removal. Treat removal of a
  published selector as an API change.
- Treat selectors, tuple order, enum ordinals, event layouts, and custom error
  payloads as client contracts. If a change requires a new ABI, name the
  affected bindings and consumers and document the cutover.

## NatSpec, comments, and names

- Give new and changed contracts, interfaces, public and external functions,
  exposed state, events, and custom errors complete NatSpec. Use `@notice`
  for observable behavior and `@dev` for invariants, trust assumptions, and
  implementation details. Document parameters and return values where applicable.
  Inherit interface docs where appropriate. Document security-sensitive
  constructors, modifiers, and internal functions. Fill gaps in the affected
  flow as part of cleanup.
- Comment each logical security-sensitive step where it occurs. Cover
  authorization and validation, state transitions and writes, admin handoffs,
  and external effects such as transfers and mints. State why the step
  belongs at that point. For example, reservation precedes mutable external
  calls and routing allowances are cleared before NFT fulfillment. Keep one
  short comment per logical step and update it when the code changes.
- Use the established protocol terms in code, tests, and docs. A Fixed Quote
  is the exact signed payment, a Listing sets a Seller Proceeds Floor, and
  Protocol Spread goes to the signed `spreadRecipient`. The payer and
  Fulfillment Action recipients can be different accounts.
- Match nearby naming and formatting. Use `SCREAMING_SNAKE_CASE` for new
  private immutables. Keep unrelated formatting and NatSpec cleanup out of
  behavioral changes.

## Events and errors

- Name new events for completed transitions. For singleton settings, include
  the previous and effective new values when both help operators, as in
  `PlatformSignerUpdated`. For seller-scoped state, include the seller and
  affected digest or resulting nonce. Log the value that actually took
  effect. Cache a previous or derived value before mutation when the check,
  write, and log need to refer to the same value. Index fields that
  consumers use to look up records.
- Preserve receipt semantics and ordering. `PurchaseExecuted` identifies the
  caller and Fixed Quote. `OrderLineSettled` reports the signed line and
  primary recipient. `ListingSplitPaid` reports individual allocations,
  including rounded zero amounts for positive split lines. Grouped transfers
  may combine those allocations across lines. Keep `ProtocolSpreadCaptured`
  separate. Only `OFF_CHAIN` lines trigger off-chain fulfillment.
- Prefer custom errors for new contract-specific failures. Use the checked
  state snapshot in the error payload. Preserve stage, line, action, and
  nested revert data where the existing API exposes them. Keep the first
  contributing line as the failure index for a grouped payout.

## Authorization and fulfillment

- Keep EIP-712 hashing in [CartHashing.sol](CartHashing.sol). Reuse it in
  Cart, Lens, and Hashes. Preserve ordered array hashing, Listing leaf
  encoding, and the chain and proxy domain. Compare changed encodings with
  independent vectors and identify which signatures, roots, proofs, and
  clients need to be rebuilt.
- Keep platform authorization, seller authorization, and caller funding
  separate. A valid platform signature cannot substitute for a valid
  seller witness. Bind cached root validation to the seller and check
  membership for each Listing. Aggregate inventory by exact Listing
  digest across lines and roots.
- Keep replay consumption and inventory reservation ahead of mutable external
  settlement calls. Preserve rollback of both on any failure and the
  reentrancy guard on checkout and seller invalidation. Pause gates checkout
  while seller revocation stays available.
- Preserve exact Fulfillment Action coverage, supported NFT selectors, and
  the order and meaning of ERC-721 mint results. Check ownership and approval
  boundaries at execution. Actual delivery depends on the token contract's
  behavior. Use full checkout simulation for integration validation. Lens
  provides advisory checks and may use different check order and diagnostics.

## Payments and routing

- Collect the exact signed amount from the caller. Preserve zero-total
  checkout, zero-value transfer skipping, and all authorization, inventory,
  fulfillment, and custody checks for free purchases.
- Keep the order-wide route bound by the signature. CartRoutePolicy checks
  command families, forbidden flags, recipients, paths, and supported V4 settlement
  actions. CartPayments rejects increases in tracked router balances and includes
  decoded endpoint assets in custody checks. See the [route protection rules](../../docs/cart-route-protection.md).
  Universal Router executes swaps and validates their remaining parameters. The transaction builder owns route construction
  and gas, byte, and workload admission. Preserve on-chain structural and
  custody checks and the per-Listing split cap. See the
  [resource policy](../../docs/cart-resource-policy.md).
- Preserve independent ETH, WETH, payment-token, and named settlement-token
  baselines. ETH and WETH share incremental solvency and retain distinct
  payout currencies. Use only incremental funds to pay obligations and send
  tracked residuals to the signed `spreadRecipient`.
- For routed ERC-20 payments, limit both temporary approval layers to the
  configured payment path. Reject preexisting nonzero approval amounts for
  that path, clear both layers before NFT fulfillment, and verify cleanup
  again at completion.
- Allocate the signed final line amount before grouping transfers. Round
  secondary shares down and give the remainder to the first recipient.
  Group by exact currency and recipient, compare full keys on collision,
  and preserve first-seen transfer order and failure attribution.

## Upgrade and configuration safety

- Preserve the UUPS proxy as the approval target and verifying contract.
  Keep implementation initialization disabled and upgrade authorization
  owner-only. Rehearse proxy initialization and configuration through
  `script/cart/`. Apply the same configuration invariants at initialization
  and in any setter for the same field. Cart currently validates dependency
  addresses in deployment tooling, and both initialization and signer
  rotation accept an unavailable signer. Treat stricter on-chain checks as
  a deliberate behavior change.
- Keep inherited storage and all Cart ERC-7201 namespaces compatible.
  Append new fields within the appropriate namespace and preserve existing
  slots, offsets, and mappings. Leave `__deprecatedProtocolRecipient`
  reserved. Compare the [storage baseline](Cart.storage-layout.json) and
  exercise the upgrade canary when storage changes.
- Keep the Cart implementation, payment executor, and embedded policies
  compatible. Review `begin` and `finish` together when changing their
  shared types or custody assumptions. Keep executor entry points protected
  against direct calls. Coordinate replacement Lens and Hashes artifacts
  and ABI consumers where applicable.
- Treat changes to owner powers, recovery, or dependency rotation as
  explicit design changes. Document the effect on outstanding signatures,
  inventory, approvals, and operational recovery. If a reviewed design
  introduces privileged asset recovery, emit an explicit event recording
  the asset, recipient, and amount recovered.

## Verify source changes

- From the repository root, use the Cart Foundry profile and installed
  pinned dependencies. Run the relevant focused tests first, then the
  Cart suite for contract behavior changes.

  ```sh
  FOUNDRY_PROFILE=cart forge test --offline
  ```

- Put focused regressions in [src/test/cart](../test/cart). Reuse the
  shared fixtures and assert the intended error and post-state for rejected
  purchases. For late failure, verify rollback of balances, approvals,
  fulfillment, fills, and replay state. Use the audit plan to find the
  workstream and existing coverage.
- When changing ABI, hashing, storage, or gas-sensitive code, compare the
  relevant artifacts, signing vectors, upgrade canary, or gas fixtures.
  Check deployed bytecode size with the Cart profile when adding runtime
  logic. For routing changes, use the [mainnet fork procedure](../../docs/cart-mainnet-fork-verification.md).
  Record which checks ran and any environment blockers. Keep fork, modeled,
  and formal evidence distinct.
