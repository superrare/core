# Cart gas capacity

> Source update, October 26, 2026: Cart, CartLens, and CartRoutePolicy now have no numerical resource caps. Cap-specific results below describe the earlier measured source. The current real-token benchmark runner tests every listed size without changing contract constants; `--expanded` is retained as a compatibility flag. See [Cart resource policy](cart-resource-policy.md) and the [backend handoff](cart-transaction-builder-handoff.md#admit-checkouts-in-the-backend).

Policy update, October 26, 2026: Cart and CartLens no longer impose a proof-depth cap. The observations below describe the earlier implementation. See [current resource policy](cart-resource-policy.md).

Research date: October 24, 2026. This note separates Sepolia receipts from experiments against the current working tree. The checkout has uncommitted Cart changes, so a local benchmark does not identify deployed behavior by itself.

The evidence supports 32 lines as a provisional capacity bound, with a gas estimate for each complete order. It does not establish a universal maximum for every NFT contract and swap route. The deployed Cart also enforces a 32-line bound, independently checked below. No production limits were changed for this investigation.

## What the limits control

The working-tree [Cart implementation](../src/cart/Cart.sol) accepts up to 32 order lines, 20 fulfillment operations, 64 Merkle siblings per listing, and 32 route commands and inputs. [CartLens](../src/cart/CartLens.sol) still rejects orders with more than 20 lines. These are independent checks. The fulfillment counter counts each ERC-721 mint unit, but one ERC-1155 transfer or mint call counts as one operation regardless of its quantity. See `_validateActions` in [Cart](../src/cart/Cart.sol). The receipt sample does not independently establish the deployed contract's line cap because its largest order contains 19 lines.

Line count does not describe all the work in an order. Cart checks listing signatures and proofs, reserves listing inventory, executes the router, calls NFT contracts, and pays recipients. Some checks scan earlier listings or lines. [CartPayments](../src/cart/CartPayments.sol) groups payouts by token, recipient, and native payment form with nested scans. Repeating one recipient and currency is cheaper than paying every line separately.

## Deployment and historical evidence

The configured Sepolia proxy is [`0x1EBF35b3A76caEf60a009d2786A66A91D42A38Bc`](https://eth-sepolia.blockscout.com/address/0x1EBF35b3A76caEf60a009d2786A66A91D42A38Bc), as recorded in [NetworkConfig](../script/NetworkConfig.s.sol). The public explorer history contains 229 transactions between August 18 and October 23, 2026, including 182 successful `executePurchase` calls. The public RPC returned 150 of the 229 receipts, including 140 of the 182 purchases. Explorer values supply the older records whose RPC receipts were unavailable.

The latest implementation is [`0x6A667afBCa403de9b2C5876534383C9C73c0DB40`](https://eth-sepolia.blockscout.com/address/0x6A667afBCa403de9b2C5876534383C9C73c0DB40), installed in [the October 23 upgrade transaction](https://sepolia.etherscan.io/tx/0x88c31cdd0c9547bfd973eee4664591681188b7ea792fdb148911bb350a5fa14f) at block 11,978,986. Fifty-four purchases followed that upgrade, and all 54 have RPC-verified receipts. Their median gas use was 545,108, their nearest-rank p95 was 1,029,918, and their maximum was 1,855,705.

The snapshot is Sepolia block 11,983,573. At that block, the ERC-1967 implementation slot contains the address above. Four read-only `eth_call` probes supply correctly encoded arrays but deliberately incorrect order hashes. Arrays of 20, 21, and 32 lines pass the length check and revert with `InvalidOrderLinesHash()`, selector `0x7dad9c05`. An array of 33 lines instead reverts with `InvalidArrayLength()`, selector `0x9d89020a`. These probes verify the deployed count check, not successful purchase execution at those sizes. The [saved probe responses](data/cart-gas-2026-10-24/deployed-cap-probes.json) record those results.

The [purchase ledger](data/cart-gas-2026-10-24/purchases.csv), [decoded purchase records](data/cart-gas-2026-10-24/purchases.json), [summary](data/cart-gas-2026-10-24/summary.json), and [methodology](data/cart-gas-2026-10-24/methodology.json) preserve the sample. The history includes 120 purchases on October 23. Implementation assignments use the four successful upgrade calls, with receipt-event checks where the RPC serves those receipts. For each available purchase receipt, gas used, block, success status, settled-line count, and fulfillment-operation count match the decoded history.

| Current implementation workload | Purchases | Minimum gas | Maximum gas |
| --- | ---: | ---: | ---: |
| ERC-1155 transfer | 27 | 447,164 | 1,855,705 |
| ERC-721 transfer | 16 | 481,946 | 581,433 |
| Swap route | 9 | 416,617 | 1,421,080 |
| ERC-1155 mint | 1 | 483,122 | 483,122 |
| ERC-721 mint | 1 | 996,903 | 996,903 |

The [largest current purchase](https://sepolia.etherscan.io/tx/0x0153e37813a0a727d7dfc744a1a3b3310f2ac523153aa61f227d4e06b7b20e95) used 1,855,705 gas for 19 lines, nine ERC-1155 transfer operations, nine listings under one seller root, two payment recipients, and one settlement currency. Its calldata was 11,236 bytes and its deepest proof contained four siblings. Its calldata floor was 258,490 gas, far below the receipt gas, so execution rather than calldata determined the charge in this case.

No observed purchase exceeds 19 lines or nine fulfillment operations. The current implementation's largest route has five commands, its largest proof depth is four, and its ERC-721 mint sample contains one mint operation. These receipts support headroom for the tested workloads, but they do not establish the cost of 20 real ERC-721 mints or 32 complex lines. Sepolia transactions also do not establish Ethereum mainnet behavior for different token or router deployments.

The [ERC-721 mint transaction](https://sepolia.etherscan.io/tx/0xb944bd39a60079c9c7b5d3ad39725143d88ec4a36e9c68f724e9f5246a8746fa) used 996,903 gas in total. Its [execution trace](https://eth-sepolia.blockscout.com/api/v2/transactions/0xb944bd39a60079c9c7b5d3ad39725143d88ec4a36e9c68f724e9f5246a8746fa/raw-trace) attributes 565,266 gas to the inclusive NFT mint call. Nested calls are included in that value and must not be summed again. This is direct evidence that the chosen NFT implementation can dominate purchase cost. Repeating that call cost 20 times would be 11.3 million gas before Cart overhead, but that multiplication is only a scale illustration. It does not model warm accesses, shared state, or subsequent token IDs.

## Local capacity experiments

The new [CartGasCapacity test](../src/test/cart/CartGasCapacity.t.sol) constructs signed purchases against the existing proxy fixture. It tests distinct existing payout accounts at 1, 5, 10, 20, and 32 lines. Scenarios include listing-less native payments, separate seller-authorized off-chain listings, the maximum proof depth of 64, and 20 ERC-721 mint calls. The native payment and NFT test contracts are local models. These experiments do not measure a live Universal Router swap.

Each experiment encodes the payload before measuring gas around the purchase call. It reports the payload byte count, gross gas consumed by the external call, and ordinary intrinsic gas of 21,000 plus 4 per zero calldata byte and 16 per nonzero byte. Cart, WETH, and the mint account are cooled before the call. The result remains an approximation of transaction gas because a test's outer CALL, account warmth, and refunds differ from a top-level transaction. The post-Pectra calldata floor must be calculated separately.

Reproduce the experiments with the repository's [Cart profile](../foundry.toml):

```sh
FOUNDRY_PROFILE=cart forge test --offline --match-path src/test/cart/CartGasCapacity.t.sol --match-test '^testCapacity' -vvvv
```

All 14 experiments passed with Forge 1.4.3 and Solidity 0.8.18, using the repository's `viaIR` and optimizer configuration. Approximate totals below are `max(grossCallGas + ordinaryIntrinsicGas, calldataFloorGas)`. They are not transaction receipts. The offline flag avoids a Foundry crash in macOS proxy discovery during online trace-signature lookup.

| Local workload | Lines | Calldata bytes | Approximate gas |
| --- | ---: | ---: | ---: |
| Listing-less native payments | 1 | 1,284 | 141,468 |
| Listing-less native payments | 5 | 2,180 | 231,628 |
| Listing-less native payments | 10 | 3,300 | 361,057 |
| Listing-less native payments | 20 | 5,540 | 675,565 |
| Listing-less native payments | 32 | 8,228 | 1,150,958 |
| Separate singleton listing roots | 1 | 1,956 | 192,083 |
| Separate singleton listing roots | 5 | 5,540 | 481,706 |
| Separate singleton listing roots | 10 | 10,020 | 869,942 |
| Separate singleton listing roots | 20 | 18,980 | 1,733,432 |
| Separate singleton listing roots | 32 | 29,732 | 2,923,053 |
| Separate listing roots, depth 64 | 20 | 59,940 | 2,764,304 |
| Separate listing roots, depth 64 | 32 | 95,268 | 4,577,874 |
| Mock ERC-721 mint calls | 20 | 20,900 | 2,931,733 |
| Mock ERC-721 mint calls, depth 64 | 20 | 61,860 | 3,967,603 |

The 32-line proof stress case consumes 95,268 calldata bytes before transaction envelope overhead. That result makes byte-size checks relevant even though ordinary observed purchases use much less data. The mock NFT mint cases establish that Cart can process 20 operations with that model. They do not establish the capacity of the real NFT contract whose one mint call consumed 565,266 gas.

The [saved benchmark measurements](data/cart-gas-2026-10-24/local-benchmarks.json) retain gross call gas, ordinary intrinsic gas, and calldata floor separately. The [trace summary](data/cart-gas-2026-10-24/trace-summary.json) records inclusive call costs for the largest purchase and the real ERC-721 mint.

## Why receipt averages cannot establish a safe maximum

A receipt reports gas charged after execution and refunds. The transaction's gas limit must also cover execution before refunds and any calldata floor. Ethereum's [EIP-7623](https://eips.ethereum.org/EIPS/eip-7623) defines the calldata floor as `21,000 + 10 * (zeroBytes + 4 * nonzeroBytes)`. Data-heavy Merkle witnesses can reach this floor even when their execution work is modest. Ethereum's [EIP-7825](https://eips.ethereum.org/EIPS/eip-7825) caps the transaction's specified gas limit at 16,777,216 where that fork is active.

The benchmark seeds payout accounts with 1 wei. Paying a dead account costs another 25,000 gas when CALL transfers value. Thirty-two distinct new accounts therefore add 800,000 gas relative to otherwise equivalent existing recipients. See [EIP-161](https://eips.ethereum.org/EIPS/eip-161). Cold accesses also cost more than repeated accesses within a transaction. See [EIP-2929](https://eips.ethereum.org/EIPS/eip-2929).

Cart forwards calls to seller-specified NFT contracts, ERC-20 contracts, payment recipients, signature-checking contracts, and the configured router. Those contracts determine part of the gas cost. A fixed line count cannot guarantee that every permitted order executes within a gas budget. Local models and historical successful orders cover only the contracts, state, routes, and payloads they exercised. See `_requireSignature` and `_executeFulfillment` in [Cart](../src/cart/Cart.sol), and payment calls in [CartPayments](../src/cart/CartPayments.sol).

## A policy tied to measured capacity

The local evidence supports retaining the working tree's 32-line execution bound while full signed-payload simulation supplies the gas check. The historical evidence does not justify a higher bound. CartLens can be aligned with 32 after representative full-order simulations pass. Keep separate bounds for fulfillment operations, proof depth, route complexity, and encoded transaction bytes. The simulation must use the active implementation and actual token, router, receiver, and signer contracts.

A proposed operating policy is a 12,000,000 gas application budget. Estimate the complete signed payload, calculate `ceil(1.25 * estimateGas)`, and reject a quote when that buffered limit exceeds the budget. Submit an admitted order with that buffered limit. This is a chosen reserve policy, not an Ethereum rule or a measured universal maximum. It leaves more than 4.7 million gas below the EIP-7825 ceiling.

Check the serialized signed transaction's byte size as well. Geth's [ordinary transaction pool](https://github.com/ethereum/go-ethereum/blob/master/core/txpool/legacypool/legacypool.go) sets `txMaxSize` to 131,072 bytes. This includes the transaction envelope and is a node policy. Admit the transaction only when its actual size fits both the node and RPC provider limits. The 95,268-byte benchmark leaves about 35.8 KB below that Geth threshold before envelope and additional routing data, so proof-heavy orders have less input headroom than the line records alone suggest.

Before increasing any count, measure fresh and previously filled listings, shared and separate seller roots, distinct currencies and recipients, new recipients, deep proofs, representative swap routes, NFT transfers and mints, and supported contract-wallet signatures. Include the combined workload rather than only isolated dimensions. Historical p95 and maximum gas can select representative cases, but a recommendation must also explain what the historical sample never exercised.
