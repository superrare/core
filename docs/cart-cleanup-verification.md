# Cart cleanup verification

The cleanup preserves the public purchase interface while separating shared test fixtures, removing inherited test duplication, and simplifying internal settlement code. The comparison baseline is `2e396e125e993b4a00527a6d53e2abea766b6cf2` on PR #26.

## Compatibility

The compiled ABIs and method selectors match the baseline for Cart, CartPayments, CartLens, CartRoutePolicy, CartHashes, CartHashing, CartStorage, and ICart. The new CartValidation library has only internal helpers and introduces no external library linking.

Canonical EIP-712 hashing source, payment-state types, storage declarations, and the committed storage-layout baseline are unchanged. CartRoutePolicy, CartHashes, and CartHashing also retain identical executable bytecode after removing compiler metadata. Independent source review checked validation and external-call order, payout-group order and failure indexes, native/WETH separation, and moved mock bodies.

Cart still materializes and hashes the route before envelope checks. This preserves the original decoding order for malformed calldata. Shared validation retains each caller's check order and diagnostic behavior.

## Runtime bytecode

| Contract | Baseline bytes | Cleanup bytes | Change |
| --- | ---: | ---: | ---: |
| Cart | 17,725 | 18,041 | +316 |
| CartPayments | 9,977 | 9,821 | -156 |
| CartLens | 9,593 | 9,593 | 0 |
| CartRoutePolicy | 697 | 697 | 0 |
| CartHashes | 2,247 | 2,247 | 0 |

All deployable runtimes remain below the 24,576-byte limit. These are runtime sizes, not deployment transaction gas estimates.

## Tests

`FOUNDRY_PROFILE=cart forge test --offline --gas-report` passes 210 tests across 19 suites with zero failures or skips. Both stateful invariants complete 256 runs and 128,000 calls with zero reverts. Unit, fuzz, storage-upgrade, free-listing, settlement, and fulfillment coverage remain included.

All 210 declared test and invariant methods remain present, including two names independently declared in separate suites. The earlier 646 executions included inherited duplicates. The abstract fixtures now provide setup and builders without executable tests. Token and router mocks retain their original bodies.

## Checkout gas

All 29 matched checkout benchmarks use less gas. Savings range from 0.26 percent to 3.32 percent. The 64-line repeated-Listing case falls from 1,002,618 to 969,364 gas; the 64-item ERC-721 mint case falls from 8,622,511 to 8,600,031 gas.

The comparison uses `grossCallGas` emitted by each benchmark's own suite, rather than whole-test gas or averages across inherited duplicates. All compared payloads retain their calldata length. These measurements describe the local Foundry environment. Backend admission still requires estimates against the intended deployed contracts and current chain state.

Run the full Cart suite from the repository root:

```sh
FOUNDRY_PROFILE=cart forge test --offline --gas-report
```

To capture the benchmark events, run the suites with verbose tracing and read the `ListingGas`, `ERC721Gas`, and `RareERC1155Gas` events. Compare the same suite and workload at the baseline and cleanup revisions. The machine-readable [verification summary](data/cart-cleanup-verification.json) records the individual gas cases and runtime sizes.

The RPC-backed fork suite and formal proofs were not rerun for this refactor. No deployment was performed. Existing Sepolia receipts describe the deployed versions, not the new source runtimes.
