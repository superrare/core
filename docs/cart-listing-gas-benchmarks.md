# Benchmark Cart listing counts

> Source update, October 26, 2026: Cart, CartLens, and CartRoutePolicy now have no numerical resource caps. Cap-specific results below describe the earlier measured source. The current real-token benchmark runner tests every listed size without changing contract constants; `--expanded` is retained as a compatibility flag. See [Cart resource policy](cart-resource-policy.md) and the [backend handoff](cart-transaction-builder-handoff.md#admit-checkouts-in-the-backend).

The [listing gas test](../src/test/cart/CartListingGas.t.sol) benchmarks 9, 18, 32, and 64 order lines. Each count has two cases: one distinct listing per line, and all lines referencing one listing. The tests use the current Cart implementation, with its source order-line cap raised to 64 and CartLens aligned to 64. No deployment forms part of this change.

Run the suite from the repository root:

```sh
FOUNDRY_PROFILE=cart forge test --offline --match-contract CartListingGasTest --match-test '^testListingGas' -vvvv | tee /tmp/cart-listing-gas.log
python3 tools/summarizeCartListingGas.py /tmp/cart-listing-gas.log
```

Read the `ListingGas` events rather than Forge's total test gas. Fixture construction, signatures, proof generation, and assertions contribute to the total test gas but occur outside the purchase-call measurement. Each event records line count, supplied listing count, calldata bytes, gross external purchase-call gas, ordinary intrinsic gas, and the calldata floor. An approximate transaction total is:

```text
max(grossCallGas + intrinsicGas, calldataFloorGas)
```

Each purchase uses off-chain merchandise, native payment, one seller, one shared seller root, one existing payout recipient, no fee lines, and no router or NFT calls. Distinct-listing proofs have depth ceil(log2(listingCount)); repeated-listing cases use an empty singleton proof. The suite deliberately holds payout-group count constant. Distinct and repeated cases differ in authorization, inventory writes, witness bytes, and listing validation as well as lookup comparisons, so their difference is not an isolated measurement of lookup cost.

Every successful case asserts exact seller proceeds, the executed-order flag, filled quantity for every supplied listing, and CartLens preflight acceptance. A separate case verifies Cart rejects 65 lines. Both distinct and repeated cases must pass when testing a future optimization.

The purchase measurement excludes payload construction and preflight. Cart, WETH, and the recipient are cooled before execution, but fixture storage warmth, the outer test CALL, and refund behavior can differ from a top-level transaction. Treat these figures as a repeatable local baseline rather than chain receipts. The off-chain model does not establish capacity for 64 NFT transfers or mints.

Keep the same fixture, compiler settings, and payloads when comparing an optimized implementation. Measure any optimization against both cases; an index can help distinct listings while adding overhead when many lines reuse one listing. Hash-table collisions also need dedicated correctness and performance coverage before adopting such an optimization.

## Initial results

All nine targeted tests passed on October 26, 2026. The targeted run used an isolated copy of the current production contracts and test fixture helpers, omitting inherited unrelated test methods to reduce compilation. No production contract transformations were applied in that run. The canonical repository command above runs the retained benchmark source. [Saved measurements](data/cart-listing-gas-2026-10-26.json) include the component gas figures.

| Order lines | Distinct listings, approximate gas | One repeated listing, approximate gas |
| ---: | ---: | ---: |
| 9 | 643,800 | 319,234 |
| 18 | 1,195,200 | 462,436 |
| 32 | 2,107,216 | 685,669 |
| 64 | 4,546,799 | 1,198,067 |

These are baseline measurements with no listing-lookup optimization. They should not be compared directly with the live ERC-1155 transaction, which performs NFT calls and has different witnesses, fees, and chain state.

## Listing-index implementation comparison

The implementation now builds a temporary open-addressed index when more than one Listing is supplied. Each slot stores the original listing index plus one. The same index rejects duplicate digests after authorization and resolves line references. Complete digest comparisons handle bucket collisions. Empty and single-listing purchases use direct lookup without allocating the table. No signed types, array ordering, persistent storage, payment rules, or inventory semantics change.

The table has at least twice as many slots as Listings. Empty slots therefore remain available, and linear probing wraps at the table mask. Expected lookup work is linear across an ordinary order, but deliberately colliding digests can still cause quadratic work. The 64-line bound still applies.

Paired runs use identical signed payloads, compiler settings, and test fixtures. The baseline is the source immediately before this lookup change, including the 64-line cap and existing mint-result work. [Saved paired measurements](data/cart-listing-lookup-optimization-2026-10-26.json) retain calldata bytes and component gas costs.

| Distinct listings | Baseline approximate gas | Indexed approximate gas | Gas saved | Reduction |
| ---: | ---: | ---: | ---: | ---: |
| 9 | 643,800 | 639,327 | 4,473 | 0.69% |
| 18 | 1,195,200 | 1,150,724 | 44,476 | 3.72% |
| 32 | 2,107,216 | 1,943,341 | 163,875 | 7.78% |
| 64 | 4,546,799 | 3,805,578 | 741,221 | 16.30% |

Repeated-single-listing cases save 293, 644, 1,190, and 2,438 gas at 9, 18, 32, and 64 lines respectively. No case in the eight-workload comparison regresses. These savings apply to the measured local workloads and must not be applied as percentages to NFT receipts.

The [listing-index correctness tests](../src/test/cart/CartListingIndex.t.sol) exercise colliding buckets at the end of the table, wraparound, repeated references, reordered references, duplicate digests inside a collision chain, missing digests inside and outside the indexed path, and unused-listing rejection. The fuzz case varies repeated quantity allocation while checking filled quantities and seller proceeds.

Validation passed for both nine-case baseline/candidate benchmark runs and 38 correctness tests: 32 existing CartVerification tests and six listing-index tests. The listing-index fuzz test ran 256 cases. Correctness tests used the same isolated fixture setup described above. The optimized Cart runtime is 18,198 bytes, below the 24,576-byte EVM code-size limit. No deployment was performed.

The [optimization-only patch](data/cart-listing-lookup-optimization.patch) records this change separately from pre-existing work. Run the focused correctness tests in the repository with:

```sh
FOUNDRY_PROFILE=cart forge test --offline --match-path src/test/cart/CartListingIndex.t.sol --match-test '^test(Fuzz)?ListingIndex' -vv
FOUNDRY_PROFILE=cart forge test --offline --match-path src/test/cart/CartVerification.t.sol -vv
```

## Reusable order-line hashing buffer

`CartHashing.hashOrderLines` now reuses one eight-word buffer containing the unchanged EIP-712 type hash and seven typed fields. It still hashes each encoded line, then hashes the ordered element digests. The production library compiles into Cart, CartLens, and the optional CartHashes helper. No signed-message types or external interface change.

The [hashing tests](../src/test/cart/CartHashingBuffer.t.sol) compare the production library with the original `abi.encode` reference. They cover randomized valid arrays from zero through 128 lines, an explicit empty array, minimum and maximum field values, array ordering, and malformed enum/address encodings. The implementation uses Solidity's typed field reads before writing the buffer, preserving decoding behavior.

These additional savings compare against the listing-index implementation from the preceding section, with no other production changes:

| Distinct listings | Before approximate gas | After approximate gas | Additional gas saved |
| ---: | ---: | ---: | ---: |
| 9 | 639,327 | 632,310 | 7,017 |
| 18 | 1,150,724 | 1,136,254 | 14,470 |
| 32 | 1,943,341 | 1,916,742 | 26,599 |
| 64 | 3,805,578 | 3,748,603 | 56,975 |

Repeated-single-listing cases save 6,945, 14,154, 25,612, and 52,915 gas at the same line counts. None of the eight measured cases regresses. Full-purchase savings differ from the earlier isolated hash microbenchmark. Reusing the buffer can also reduce memory expansion in later execution, and the compiler context differs. These figures remain local approximations and do not establish NFT checkout capacity.

The [paired hashing measurements](data/cart-order-line-hashing-2026-10-26.json) and [hashing-only patch](data/cart-order-line-hashing-2026-10-26.patch) preserve the comparison. Reproduce hash-equivalence checks with:

```sh
FOUNDRY_PROFILE=cart forge test --offline --match-contract CartHashingBufferTest -vv
```

Validation passed for all 51 focused tests across hashing equivalence, listing-index correctness, purchase verification, and the gas/boundary suite. Both fuzz tests ran 256 cases each. The optimized Cart runtime is 18,097 bytes. Tests used the same isolated fixture setup documented above; no deployment was performed.
