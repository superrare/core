# Per-listing split verification

The focused CartSplits suite passes 23 tests, including 256 runs each for two-recipient and arbitrary 1–16-recipient fuzzing. Tests check every allocation balance and event, secondary-recipient reentry rejection, rollback after an earlier callback, exact-currency settlement, and seller authority.

The migration test deploys actual creation bytecode from pre-split commit `a33db9aa71eb700378789c3d58551cc2720949b8`. It fills one of three units, cancels that old listing, upgrades the proxy, and checks preserved fill/cancellation/order state. The old root cannot authorize the new listing schema. The seller explicitly signs a replacement for the remaining two units. Remaining quantities are a migration decision; the new digest does not inherit the old fill count automatically.

`docs/data/cart-pre-split-bytecode.json` is a generated historical fixture, not a deployment artifact. Rebuild it with `python3 tools/buildCartPreSplitFixture.py` using local Solidity 0.8.18 and the pinned Git revision. This requires no RPC. The test deploys a matching new Cart/payment bundle and keeps the proxy address stable.

SDK vectors in `docs/data/cart-split-sdk-vectors.json` come from ethers 6.15.0. The Solidity test compares CartHashes with SDK digests for empty and populated split arrays. Regenerate or verify them with:

```sh
npm ci --prefix tools/cart-split-vectors --ignore-scripts
node tools/cart-split-vectors/generate.mjs
npm run check --prefix tools/cart-split-vectors
```

Run the local contract checks with:

```sh
FOUNDRY_PROFILE=cart forge test --offline --match-contract CartSplitsTest -vv
```

## Split-order gas measurements

These are checkout-call measurements for direct native ETH, off-chain listings, sixteen equal shares per listing, fresh distinct EOA recipients, and one seller root per listing. Setup and signatures are prepared before measurement. Measurements include caller-side ABI encoding and exclude transaction intrinsic calldata gas. They are not chain simulations or safe admission limits. The fixtures contain no swaps, NFTs, contract-wallet signatures, or receiver contract work.

| Listings | Distinct recipients | Checkout-call gas | Calldata bytes |
| --- | --- | --- | --- |
| 1 | 16 | 923,274 | 3,108 |
| 8 | 128 | 9,954,762 | 17,220 |
| 32 | 512 | 83,611,303 | 65,604 |
| 64 | 1024 | 284,594,133 | 130,116 |

The 32- and 64-listing cases deliberately execute beyond ordinary transaction budgets in the local test environment. The 16-recipient cap applies per listing. It is not a bound on the total order. Aggregation scans accumulated payout groups, so distinct-recipient growth is quadratic. The builder must estimate the exact complete signed payload against the target chain's current transaction/block limits and configured headroom. Historical listing-count benchmarks do not establish capacity for split orders. Machine-readable measurements and the measured test source hash are in `docs/data/cart-split-gas.json`.

Production contract code is unchanged by this coverage update. The focused suite and SDK vector check were run for these changes; previously recorded broad Cart and verification-suite results are separate historical evidence.
