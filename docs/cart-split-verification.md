# Per-listing split verification

The focused CartSplits suite passes 24 tests, including 256 runs each for two-recipient and arbitrary 1–16-recipient fuzzing. Tests check every allocation balance and event, secondary-recipient reentry rejection, rollback after an earlier callback, exact-currency settlement, and seller authority.

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
| 1 | 16 | 884,973 | 3,108 |
| 8 | 128 | 6,447,266 | 17,220 |
| 32 | 512 | 25,821,285 | 65,604 |
| 64 | 1024 | 52,202,125 | 130,116 |

The 32- and 64-listing cases deliberately execute beyond ordinary transaction budgets in the local test environment. The 16-recipient cap applies per listing. It is not a bound on the total order. Aggregation now uses a memory hash index keyed by exact currency and recipient. It preserves the first-seen payout array and resolves collisions by comparing both fields and probing the next slot. Occupancy stays at or below one half. Expected grouping work is near linear for ordinary keys; deliberately colliding keys can still degrade probing, so this is not a worst-case linear guarantee. The builder must estimate the exact complete signed payload against the target chain's current transaction/block limits and configured headroom. Historical listing-count benchmarks do not establish capacity for split orders. Machine-readable measurements and the measured test source hash are in `docs/data/cart-split-gas.json`.

The indexed implementation uses the same split semantics and ABI. The initial scan baseline is preserved as `baselineCases` in the data file. For 64 listings, measured gas falls from 284,594,133 to 52,202,125. The fixture asserts that doubling from 32 to 64 stays below 2.3 times the call gas; the old scan violates that threshold. A separate test forces all payout keys into the last bucket, wraps across zero, merges a repeated recipient, and checks first-line failure attribution.

## Advanced checkout

`CartAdvancedGasTest` uses six ERC-721 transfers, two fee lines, USD-fixture and WETH settlement, and collaborator shares on two listings. The collaborator receives both currencies independently. A deterministic router fixture consumes input via Permit2 and supplies exact WETH output. All NFT ownership, inventory fills, recipient balances, custody balances and input allowance cleanup are checked. The fixture uses six seller roots. It is not a live router, production USD token, market exchange rate, or receipt estimate.

The same test on baseline `a682234` uses 1,147,031 checkout-call gas. With indexed aggregation it uses 1,138,982, a reduction of 8,049 gas, about 0.7%. Both payloads are 8,676 bytes with 83,292 intrinsic gas. Fixture preparation warms accounts; these numbers are useful for a controlled before/after comparison, not cold production admission limits.

The current focused run passes 24 split tests and one advanced-checkout test. Historical formal proof results do not establish arbitrary split correctness. Broader runtime validation and its scope are recorded in the PR description.

## Current validation

The indexed implementation passes 234 main regression checks, including both stateful invariants at 256 runs and 128,000 calls each with zero reverts. This run excludes the historical CartGasCapacity, CartQuoteCapacity, CartERC721Gas, CartListingGas, and CartRareERC1155Gas harnesses. It includes the current split stress benchmarks, advanced checkout, authorization, inventory, callbacks, collision handling, storage layout, and routing regressions. All 67 executable verification checks also pass. The 25 focused checks are included in the regression count, not additional tests. CartPayments runtime is 11,059 bytes under Solidity 0.8.18, via IR, optimizer runs 100.

The optimization changes no storage slots or public ABI. Deployment still requires a new executor and a Cart implementation referencing it. The earlier split-format migration remains necessary when upgrading from pre-split contracts.
