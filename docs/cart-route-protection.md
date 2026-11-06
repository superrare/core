# Cart route protection

Cart accepts routes that return swap output and refunds to Cart. Cart then distributes
funds according to the signed order. An unsupported route reverts before funding, or
fails the post-execution custody checks and rolls back the purchase.

## Supported instructions

- V2 and V3 swaps must use Universal Router's `MSG_SENDER` recipient, address `1`.
  The router resolves that alias to the calling Cart proxy. Explicit wallet addresses,
  including a seller address, are rejected.
- `SWEEP` must return funds to `MSG_SENDER`.
- Wrap and unwrap may deliver to `MSG_SENDER` or the router alias, address `2`.
  The router alias supports intermediate funding before another swap.
- `PERMIT2_TRANSFER_FROM` may only prefund the router alias. Cart's existing temporary
  allowances constrain the token and amount that the router can pull.
- V4 accepts exactly one swap action, `0x06` through `0x09`, followed by `SETTLE_ALL`
  and `TAKE_ALL`. `TAKE_ALL` returns output to the caller. Arbitrary take recipients,
  other settlement forms, extra actions, and partial-failure command flags are rejected.

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

A native exact-output V4 route must return its unused ETH. The local SDK compiler inspected
during this change emits only `V4_SWAP`, which can retain that surplus. Append a native
`SWEEP` to `MSG_SENDER`, or the new executor will reject purchases that leave surplus.
The contract does not rewrite the signed route automatically.

A router refund returns funds to Cart. It is not a refund to the buyer. After paying
signed line obligations, Cart sends the remaining tracked assets to the order's signed
`spreadRecipient`. When that address is the platform, unused input from an exact-output
swap and extra output from an exact-input swap belong to the platform. The buyer pays
the full signed `paymentAmount` in either case. The order fixes payout amounts; swap
mode controls execution inside the router and does not change spread ownership.

## Deployment and client compatibility

`validate(bytes,bytes[])` now returns the decoded asset list. Its selector is unchanged,
but the return ABI has changed. Deploy the policy and payment executor together with a
compatible Cart implementation that embeds the same policy. A legacy policy does not
provide the return data required by the new executor. Regenerate policy ABI consumers.
Checkout order hashing and proxy storage layouts are unchanged.

Provider-generated routes can now fail validation because they use explicit recipient
addresses or unsupported V4 action sequences. Update and simulate backend routes against
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

Use `CartAdvancedGasTest.testAdvancedCheckoutGas` for the existing complex checkout
benchmark. It contains six NFT purchases, two fee lines, grouped splits, and a routed
ERC-20 payment. Its deterministic router models settlement; it is not a live exchange
pricing benchmark. Compare its logged checkout call gas with the same compiler settings.

### Gas comparison

With the Cart profile, Solidity 0.8.18, via IR, and optimizer runs 100, the existing
advanced checkout fixture logs the following call gas:

| Version | Checkout call gas |
| --- | ---: |
| Before route protection | 1,138,982 |
| With route protection | 1,152,392 |
| Increase | 13,410, or 1.18% |

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

| Router mode | Checkout call gas | Intrinsic gas | Calldata bytes |
| --- | ---: | ---: | ---: |
| Exact input | 308,683 | 35,200 | 2,404 |
| Exact output | 273,795 | 35,188 | 2,404 |

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
