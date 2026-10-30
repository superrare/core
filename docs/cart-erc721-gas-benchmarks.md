# Benchmark Cart with LazySovereignNFT

> Source update, October 26, 2026: Cart, CartLens, and CartRoutePolicy now have no numerical resource caps. Cap-specific results below describe the earlier measured source. The current real-token benchmark runner tests every listed size without changing contract constants; `--expanded` is retained as a compatibility flag. See [Cart resource policy](cart-resource-policy.md) and the [backend handoff](cart-transaction-builder-handoff.md#admit-checkouts-in-the-backend).

The [ERC-721 Cart benchmark](../src/test/cart/CartERC721Gas.t.sol) uses the repository's [LazySovereignNFT](../src/token/ERC721/sovereign/lazy/LazySovereignNFT.sol). That implementation supports Cart's `mintTo(address)` selector directly. No mint adapter or NFT mock is involved.

The fixture deploys the real implementation and an OpenZeppelin minimal-proxy clone, then calls its normal initializer. This matches the base-token clone and initialization sequence in LazySovereignNFTFactory, without deploying the factory's unused royalty-guard variants. The measured token calls include the clone's delegatecall. The collection owner is the seller, and `prepareMintWithMinter` authorizes Cart before the purchase. Royalty-guard collection variants are not measured.

The matrix mirrors the [RareERC1155 benchmark](cart-rare1155-gas-benchmarks.md): 9, 18, 32, 62, and 64 distinct merchandise listings, plus two aggregate fee lines. All NFTs belong to one collection and go to one EOA collector. Payments are native, all seller proceeds share one recipient, and the two fee purposes share another. There are no swap routes or receiver callbacks. Transfers use tokens preminted to the seller and real operator approval. Mint-on-purchase starts with no tokens minted, so ownership and per-token royalty records are created during checkout. Setup, approvals, metadata preparation, signatures, and proofs occur outside the purchase measurement.

Both modes assert exact ownership, collector and seller balances, collection supply, each listing's filled quantity, seller proceeds, fee proceeds, and order execution. Mint cases also decode Cart's returned MintResult array, verify action indexes and token IDs, and check per-token royalties.

## Reproduce

The [ERC-721 runner](../tools/benchmarkCartERC721.py) selects the ERC-721 variant of the shared real-token benchmark runner. It copies contract sources and complete fixtures to a temporary project and never changes workspace contracts.

Current caps:

```sh
python3 tools/benchmarkCartERC721.py
```

Expanded experimental caps:

```sh
python3 tools/benchmarkCartERC721.py --expanded
```

Expanded mode changes only the copied Cart and CartLens caps to 66 lines and 64 operations. That permits the 64-sale point with two fee lines. Under a 64-line policy, 62 such sales is the largest line-count case. Current-cap mode expects orders above 20 operations to revert; only the 9- and 18-sale cases emit measurements. The runner prints results and saves raw logs and JSON in its displayed temporary directory.

For a direct current-cap run:

```sh
CART_BENCH_EXPANDED=false FOUNDRY_PROFILE=cart forge test --offline --match-contract CartERC721GasTest --match-test '^testERC721' -vvvv
```

## Results

All ten current-cap tests passed, including six expected large-order rejections. All ten expanded-cap cases completed successfully. The current-cap and expanded measurements agree exactly for 9 and 18 sales. As with prior runs, the current-cap project omits unrelated inherited test methods to reduce compilation; the expanded project uses complete fixtures. Neither changes the measured token code.

| Sales | Total lines | Transfer approximate gas | Mint approximate gas |
| ---: | ---: | ---: | ---: |
| 9 | 11 | 855,069 | 1,476,033 |
| 18 | 20 | 1,522,224 | 2,735,977 |
| 32 | 34 | 2,556,326 | 4,694,476 |
| 62 | 64 | 4,825,185 | 8,947,795 |
| 64 | 66 | 4,980,595 | 9,234,702 |

For 62 sales, illustrative buffered limits are 6,031,482 for transfers and 11,184,744 for mints. Both fit the proposed 12 million budget in this local model. The 64-sale figures also fit that gas policy, but their 66 total lines exceed a 64-line execution policy.

The [current-cap measurements](data/cart-erc721-current-caps-2026-10-26.json) and [expanded-cap measurements](data/cart-erc721-expanded-caps-2026-10-26.json) retain component figures and exact source hashes. The shared result parser was checked against both ERC-721 logs and the earlier ERC-1155 log, reproducing the ERC-1155 saved measurements.

These results support testing a 64-operation policy for this implementation alongside the existing 64-line allowance. They do not establish a universal NFT cost or change the current 20-operation source cap. The 62-sale boundary leaves room for the two aggregate fee lines.

## Measurement scope

The event records gross purchase-call gas, ordinary intrinsic calldata gas, calldata floor, bytes, lines, and mode. Approximate transaction gas is `max(grossCallGas + intrinsicGas, calldataFloorGas)`. Illustrative buffered gas is `ceil(1.25 * approximateTransactionGas)`. Neither value is a chain receipt or an RPC estimate.

Fixture warmth, outer CALL overhead, refunds, compiler configuration, and fork rules can differ from an actual transaction. Transfer mode empties the seller's collection balance, and its potential refund is not subtracted from the gross approximation. Other collections, token metadata implementations, approval states, contract recipients, and routes can cost more or less. Simulate the actual signed order before applying a checkout budget.

No Cart, token, or helper deployment forms part of this investigation. Production source caps remain 64 lines and 20 fulfillment operations.
