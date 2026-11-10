# Per-listing split verification

Use the focused CartSplits suite to check allocation balances and events, rounding, callback reentry, rollback, exact-currency settlement, and seller authority.

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

Run the split stress fixture and advanced checkout against the revision under review.

```sh
FOUNDRY_PROFILE=cart forge test --offline --match-test testSplitOrderGasBenchmarks -vv
FOUNDRY_PROFILE=cart forge test --offline --match-contract CartAdvancedGasTest -vv
```

The split stress fixture uses direct native ETH, off-chain Listings, 16 shares per
Listing, distinct recipients, and one seller root per Listing. Record checkout-call
gas and calldata bytes separately. Call measurements include caller-side encoding
and exclude intrinsic transaction gas. Compare identical workloads when changing
payout grouping. Use the collision cases in `CartSplitsTest` to check full-key
comparison, transfer order, and first-line failure attribution.

The advanced fixture combines ERC-721 transfers, fee lines, two settlement
currencies, and shared split recipients. It uses a modeled router. Estimate the
exact signed payload against the target deployment and actual payer for production
admission.
