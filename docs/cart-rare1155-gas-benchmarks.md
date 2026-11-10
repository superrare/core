# Benchmark Cart with RareERC1155

> Source update, October 26, 2026: Cart, CartLens, and CartRoutePolicy now have no numerical resource caps. Cap-specific results below describe the earlier measured source. The current real-token benchmark runner tests every listed size without changing contract constants; `--expanded` is retained as a compatibility flag. See [Cart resource policy](cart-resource-policy.md) and the [backend handoff](cart-transaction-builder-handoff.md#admit-checkouts-in-the-backend).

The [RareERC1155 Cart benchmark](../src/test/cart/CartRareERC1155Gas.t.sol) executes complete purchases using the repository's [RareERC1155](../src/token/ERC1155/RareERC1155.sol). It deploys the real [factory](../src/token/ERC1155/RareERC1155ContractFactory.sol) and creates an EIP-1167 clone through its normal creation method. No NFT mock substitutes for the collection.

The matrix covers 9, 18, 32, 62, and 64 sales, both transfers and mint-on-purchase. Every order has two additional fee lines. The 62-sale case fills the current 64-line allowance. The 64-sale case needs 66 lines and is an experimental capacity case, not a currently supported order.

Each case uses distinct token IDs in one collection, one seller, one seller root with balanced inclusion proofs, one EOA collector, native payment, and two aggregate fee lines. All seller proceeds share one recipient, and both fee types share another. There are no swaps or NFT receiver callbacks. Transfers start with two seller units and move one unit, leaving a nonzero balance to avoid zero-balance refunds. Mints start with token definitions but no prior supply or collector balance. Collection deployment, token definition, initial inventory, approvals, signatures, and proof construction occur before gas measurement.

Cart's minter authority comes from the factory's default-minter initialization. Transfers use the seller's real ERC-1155 approval. After successful settlement, assertions verify buyer and seller NFT balances, total supply, lifetime minted quantities, each listing's filled quantity, seller proceeds, fee proceeds, and the executed-order flag.

## Reproduce the runs

The [runner](../tools/benchmarkCartRareERC1155.py) creates a separate temporary project using the workspace's contract sources, complete test fixtures, compiler configuration, and library dependencies. It does not edit or deploy workspace contracts.

Run against the current caps:

```sh
python3 tools/benchmarkCartRareERC1155.py
```

Run the proposed larger cases:

```sh
python3 tools/benchmarkCartRareERC1155.py --expanded
```

The expanded mode changes only its temporary Cart and CartLens copies to 66 lines and 64 operations. It does not change proof or route limits. In ordinary current-cap mode, the six cases above 20 operations assert rejection instead of emitting gas measurements. A source cap of 64 lines and 64 operations would admit at most 62 sales with the two fees in this matrix. The extra two experimental line slots exist only to measure the requested 64-sale point.

The runner prints a comparison table and saves the full Forge log and JSON in its displayed temporary directory. Gas events report gross purchase-call gas, ordinary intrinsic calldata gas, calldata floor, bytes, and sale count. Approximate transaction gas is `max(grossCallGas + intrinsicGas, calldataFloorGas)`. The JSON's buffered number is `ceil(1.25 * approximateTransactionGas)`. This is an illustration of the reserve policy, not a node's `eth_estimateGas` response.

You can also run the current-cap tests directly in the repository:

```sh
CART_BENCH_EXPANDED=false FOUNDRY_PROFILE=cart forge test --offline --match-contract CartRareERC1155GasTest --match-test '^testRare' -vvvv
```

## Current-cap results

All ten current-cap tests pass: four successful purchases and six expected capacity rejections. The initial targeted run used the same isolated fixture setup as the prior benchmarks, with unrelated inherited test methods omitted. The runner retains complete fixtures for reproduction.

| Sales | Total lines | Transfer approximate gas | Mint approximate gas |
| ---: | ---: | ---: | ---: |
| 9 | 11 | 1,017,751 | 1,471,098 |
| 18 | 20 | 1,872,664 | 2,774,123 |

The [saved current-cap results](data/cart-rare1155-current-caps-2026-10-26.json) retain the component figures. Larger purchases remain rejected by the current source's 20-operation cap.

## Expanded-cap results

All ten expanded-cap tests passed using the runner's complete, unmodified inherited test fixtures. The 9- and 18-sale measurements match the current-cap run exactly. The [saved expanded-cap measurements](data/cart-rare1155-expanded-caps-2026-10-26.json) include component gas costs, buffered illustrations, exact copied source hashes, and the experimental caps.

| Sales | Total lines | Transfer approximate gas | Mint approximate gas |
| ---: | ---: | ---: | ---: |
| 9 | 11 | 1,017,751 | 1,471,098 |
| 18 | 20 | 1,872,664 | 2,774,123 |
| 32 | 34 | 3,192,483 | 4,800,264 |
| 62 | 64 | 6,075,540 | 9,203,339 |
| 64 | 66 | 6,271,554 | 9,498,951 |

At 62 sales, the illustrative 25% buffered limits are 7,594,425 for transfers and 11,504,174 for mints. Both are below the proposed 12 million operating budget in this local model. At 64 sales, they are 7,839,443 and 11,873,689, but those purchases require 66 lines and would not fit a 64-line execution policy.

The 62-sale result supports evaluating 64 fulfillment operations with the existing 64-line allowance for this token implementation. The production source still has a 20-operation cap. This investigation did not change any production constant or deploy a contract. Confirm real quotes through the target RPC before treating the illustrative buffered figures as submission limits.

## Interpretation

These measurements exercise an actual repository token implementation through its normal clone, so they answer a broader question than the off-chain listing benchmark. They still describe one collection and one workload shape. Different collections, seller inventories, preexisting buyer balances, contract recipients, and swap routes can have different costs.

The local gross-call measurement also differs from a top-level transaction in fixture warmth, outer CALL overhead, compiler context, refunds, and potentially chain fork rules. It is not a receipt. The earlier Sepolia sale used a different collection address and an older Cart implementation without these gas optimizations, so its difference from this benchmark cannot be attributed to one change.

Use these results to select capacity tests and candidate bounds. Before offering a real purchase, simulate its actual signed payload, caller, recipients, collection code, route, and current state. Apply the gas budget and actual serialized-byte limit to that order.
