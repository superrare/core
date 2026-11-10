# Cart route protection

Cart accepts routes that return swap output and refunds to Cart. Cart then distributes
funds according to the signed order. An unsupported route reverts before funding, or
fails the post-execution custody checks and rolls back the purchase.

## Supported instructions

- V2 and V3 swaps may deliver to the calling Cart, Universal Router's `MSG_SENDER`
  alias, address `1`, or the router alias, address `2`, for temporary custody.
- `SWEEP` returns funds to Cart or `MSG_SENDER`. It cannot pay an order recipient
  directly, even when that address appears in a signed line.
- Wrap and unwrap may deliver to Cart, `MSG_SENDER`, or the router alias.
  Intermediate router custody must be cleared before the complete route returns.
- `PERMIT2_TRANSFER_FROM` may only prefund the router alias. Cart's temporary
  allowances constrain the token and amount the router can pull.
- V4 accepts exactly one swap action, `0x06` through `0x09`, followed by either
  `SETTLE` or `SETTLE_ALL`, then either `TAKE` or `TAKE_ALL`. `TAKE` must return
  output to Cart or `MSG_SENDER`; `TAKE_ALL` returns output to the caller.
  Other action families, extra actions, arbitrary recipients, and partial-failure
  command flags remain rejected. Amount sentinels and payer flags retain their
  router-defined meaning.

Pool paths, price bounds, and V4 swap payload execution remain the router's responsibility.
The policy decodes V2/V3 paths and V4 settlement endpoints to identify assets for custody
checks. It does not maintain an independent price oracle or approve individual pools/hooks.

## Execution assertions

The executor snapshots router ETH and tracked token balances immediately before routing.
Execution must not increase any of those balances. Existing router balances need not be
zero. Tracking includes WETH, payment and settlement tokens, and decoded route endpoints.
V2/V3 multi-hop swaps move intermediate assets between pools. Supported V4 actions settle
pool-manager deltas within the router call.

Route endpoint tokens also join Cart's custody snapshots and residual distribution. This
prevents an otherwise untracked endpoint from remaining in Cart after settlement.
These checks cover supported asset flows, not arbitrary tokens transferred by malicious
hooks or unusual token side effects. A pre/post balance comparison cannot distinguish
individual coins in a shared balance.

A native exact-output V4 route must return its unused ETH. A compiler that emits only `V4_SWAP` can retain that surplus. Append a native
`SWEEP` to `MSG_SENDER`, or the new executor will reject purchases that leave surplus.
The contract does not rewrite the signed route automatically.

A router refund returns funds to Cart. It is not a refund to the buyer. After paying
signed line obligations, Cart sends the remaining tracked assets to the order's signed
`spreadRecipient`. When that address is the platform, unused input from an exact-output
swap and extra output from an exact-input swap belong to the platform. The buyer pays
the full signed `paymentAmount` in either case. The order fixes payout amounts; swap
mode controls execution inside the router and does not change spread ownership.

## Deployment and client compatibility

`validate(bytes,bytes[])` returns the decoded asset list and binds explicit Cart
recipients to `msg.sender`. CartPayments calls this entry point from the proxy's
execution context. Lens calls `validateFor(cart,commands,inputs)` to preview that
same recipient context without making Lens an allowed payout destination. The
preview entry point is advisory; it cannot change execution's caller context.

The existing execution selector and return ABI are unchanged by this expansion.
The context-aware preview entry point is new. Deploy a matching Lens with the
replacement policy, executor, and Cart implementation. The new Lens cannot use a
legacy policy that lacks `validateFor`. A legacy policy that returns no asset
array remains incompatible with the current executor. Checkout argument tuples,
hashing, events, and proxy storage layouts are unchanged.

Provider routes still fail validation when they use unrelated recipients or
unsupported V4 action sequences. Update and simulate backend routes against
the replacement contracts before deployment. The CLI live Cart swap cases use deployed
contracts; they do not validate this local implementation until their deployment changes.

## Verification

`CartRouteProtection.t.sol` exercises wrong recipients, retained ETH, and retained tokens
through checkout. Rejected purchases restore payer funds, router and Cart balances,
recipient balances, and order replay state. `CartRoutePolicy.t.sol` covers recipient and
V4 action decoding. The Ethereum fork regression executes a native exact-output V4 swap,
checks rejection without a refund, and checks success with a refund. The V4 refund,
V3 exact-output refund, and WETH-prefunding cases were also verified in a disposable
copy at mainnet block 26,351,190. The repository's default block 25,800,000 requires an
archive RPC; public endpoints refused those archive reads. The disposable copy changes
only the fork block. These three tests reactivate the fork within the test call so the
deployed router's Cancun instructions remain available with the older Solidity target.

The pinned Sepolia provider regressions execute the two captured routes through
signed checkout, including seller authorization, exact payouts, spread, protected
Cart balances, allowance cleanup, fills, and replay state. They also reject a V3
route that leaves WETH in the router and a V4 route paying a signed line recipient
directly. Run them locally with an archive-capable Sepolia RPC:

```sh
ETH_SEPOLIA_RPC_URL=<endpoint> FOUNDRY_PROFILE=cart FOUNDRY_TEST=src/test/forks/sepolia/cart forge test --offline -vv
```

The fixture pins block 12,078,702 and stores public provider calldata in
`src/test/fixtures/cart-provider-sepolia.json`. Upgrades and signer changes happen
only in fork state. The tests do not broadcast transactions.

Use `CartAdvancedGasTest.testAdvancedCheckoutGas` for the existing complex checkout
benchmark. It contains six NFT purchases, two fee lines, grouped splits, and a routed
ERC-20 payment. Its deterministic router models settlement; it is not a live exchange
pricing benchmark. Compare its logged checkout call gas with the same compiler settings.

### Gas comparison

With the Cart profile, Solidity 0.8.18, via IR, and optimizer runs 100, the existing
advanced checkout fixture logs the following call gas:

| Version                 | Checkout call gas |
| ----------------------- | ----------------: |
| Before route protection |         1,138,982 |
| With route protection   |         1,152,392 |
| Increase                |  13,410, or 1.18% |

Calldata remains 8,676 bytes and intrinsic gas remains 83,292. This compares the same
checkout and signed route. Fixture setup warms accounts and storage, so the percentage
is not a universal estimate for live purchases. Additional endpoint tokens require
additional balance reads. A native refund instruction also adds its own execution and
calldata cost, which this existing ERC-20 fixture does not measure.

The payment executor's deployed bytecode is 11,786 bytes and the policy is 2,809 bytes,
both below the 24,576-byte limit.

### Native checkout with platform spread

The native V4 fork benchmarks include the final ETH sweep, Cart settlement, and payment
to a separate signed platform `spreadRecipient`. Both modes reject a missing sweep and
succeed with it. At mainnet block 26,355,410, the measured cases are:

| Router mode  | Checkout call gas | Intrinsic gas | Calldata bytes |
| ------------ | ----------------: | ------------: | -------------: |
| Exact input  |           308,683 |        35,200 |          2,404 |
| Exact output |           273,795 |        35,188 |          2,404 |

These are complete simple checkouts with one 1-USDC payout, not increases over the
complex ERC-20 benchmark above. The fixtures warm state during setup and the rejected
purchase, so these figures are not production transaction gas estimates or an isolated
measurement of the sweep instruction.

Each case collects the full signed 0.01-ETH quote from the payer. The exact-input case
swaps 0.001 ETH, deliberately overfunding the router to exercise cleanup. It verifies
that the platform receives the remaining 0.009 ETH and any USDC above the signed payout.
The exact-output case obtains exactly 1 USDC and sends unused input to the platform.
Both restore Cart's balances and leave no additional ETH in the router.

The inspected rare-api planner requests exact-output routes. The SDK's local compiler
supports both router modes. Contract tests for both modes do not establish that both
user-facing quote modes are exposed by that API planner.
