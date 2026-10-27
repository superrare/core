# Sepolia Cart upgrade, October 26, 2026

Cart, CartPayments, and CartLens were replaced by the [October 27 free-listing repair](cart-sepolia-free-listings-2026-10-27.md). The route policy recorded below remains current. This document retains the October 26 deployment history.

The Cart proxy at `0x1EBF35b3A76caEf60a009d2786A66A91D42A38Bc` now uses the implementation with listing lookup and hashing optimizations, mint-result returns, and no numerical resource caps. The route policy, payment executor, and CartLens were replaced together.

| Contract | Address |
| --- | --- |
| Cart proxy, unchanged | `0x1EBF35b3A76caEf60a009d2786A66A91D42A38Bc` |
| Cart implementation | `0x6d10c6a2cbD956CbC5Bf74e06fAB3651434C52aA` |
| CartRoutePolicy | `0xbF6c6D2E8Be99cDc5882d186c40fDF9222892f9C` |
| CartPayments | `0xBf73E54100D9C9853D31ce5a82B9a1066A3103cB` |
| CartLens | `0x7DD8e5c3560Af43700722270fBbc1D0d6079E9B5` |
| CartHashes, unchanged | `0x7cF7626AA1881FFeb2004705886DA42605Ec9A0F` |

The [proxy upgrade transaction](https://sepolia.etherscan.io/tx/0xb1343a63d2c27c12452027372cdc3fbfa24dcfafbae86d650baf5af9a2f9d397) succeeded in block 12,000,221. The [deployment ledger](data/cart-sepolia-upgrade-2026-10-26.json) contains all successful transaction hashes, node estimates, submitted gas limits, receipt gas, addresses, and postflight checks. `script/NetworkConfig.s.sol` records the new addresses.

Integrations keep the existing Cart proxy address and use the new CartLens address. The existing CartHashes helper remains compatible because the hashing optimization preserves its outputs and ABI. Apply the [backend transaction builder guidance](cart-transaction-builder-handoff.md#admit-checkouts-in-the-backend) before admitting larger orders.

## Validation

`FOUNDRY_PROFILE=cart forge test --offline` passed all 599 tests across 18 suites, with no failures or skips. Each stateful invariant completed 256 runs and 128,000 calls with zero reverts. The storage-upgrade canary passed.

Postflight reads confirmed the new implementation slot and route policy. Owner, platform signer, protocol recipient, pause state, Universal Router, Permit2, and WETH match their pre-upgrade values. All four deployed runtime bytecodes match the tested local artifacts after immutable references are resolved. Cart and CartPayments embed the expected policy and executor addresses.

Read-only on-chain probes confirmed that 65-line payloads reach hash validation in both Cart and CartLens. The route policy accepts 33 allowed commands with matching inputs and still rejects mismatched arrays. These probes do not execute customer purchases or consume order IDs.

Explorer source verification has not been submitted. Automatic approval review requires explicit approval before exporting the source and build metadata to Etherscan. Runtime bytecode verification against the local artifacts is complete.

## Deployment gas and recovery

The first Foundry script broadcast encountered the delegated wallet's in-flight transaction limit. The first route-policy creation was included but ran out of gas. The proxy remained unchanged. Resuming that saved script correctly reported the failed creation.

The node estimated 1,297,097 gas for the exact policy creation bytecode, while the older local simulator had submitted only 265,179 gas. Deployment continued with the tested creation bytecode, live `eth_estimateGas` results, a 25 percent margin, and sequential receipt confirmation. Each replacement and the final proxy upgrade succeeded.

| Transaction | Receipt gas |
| --- | ---: |
| CartRoutePolicy deployment | 1,285,726 |
| CartPayments deployment | 15,554,719 |
| Cart implementation deployment | 28,273,333 |
| CartLens deployment | 15,224,002 |
| Proxy upgrade | 42,622 |

The older local simulator does not reproduce this Sepolia deployment pricing. Earlier local purchase benchmarks remain comparisons under their recorded settings; use current node estimates for checkout admission and deployment gas. Do not reuse this Foundry script's local gas estimates for another broadcast on the same network without addressing that mismatch.
