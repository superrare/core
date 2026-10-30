# Cart Kontrol proofs

The signed spread-recipient migration updates these fixture builders to the current order ABI. Saved proof results predate that migration and do not prove the updated contracts; rerun the proof selection before making a current formal-verification claim.

This project verifies fixed-shape purchases through a freshly initialized ERC1967 proxy using the production Cart implementation and CartPayments delegatecalls. Production contracts are imported directly. The runner pins Kontrol 1.0.255 and its container digest.

## Run

Docker must be running. On Apple Silicon the pinned Linux amd64 image uses emulation. Run from the repository:

```sh
verification/cart/kontrol.sh version
verification/cart/prove.sh
```

The wrapper caps each K compiler JVM at 3 GiB because the build runs two backends concurrently. Docker needs additional memory for native compilation and proof workers. Override the JVM options with `CART_K_OPTS` if needed; the runtime's uncapped default allows 8 GiB per JVM.

The fresh runner defaults to one proof worker. Set `CART_PROOF_WORKERS=3` to run three claims concurrently when memory allows. The authorization batch uses three workers with an 8 GiB Docker memory limit.

The runner removes the previous result file, builds the execution model, and archives old checkpoints under `out/proof-history` before starting fresh proofs. It selects 29 properties and validates their APR proofs, all five setup proofs, and referenced subproofs. Pending, failing, bounded, admitted, or refuted states fail validation, as does a configured bounded-model-checking depth.

The checker compares each proof's initial program byte-for-byte with the current harness artifact. It writes `out/verified-results.json`, including program SHA-256 hashes and arithmetic-helper evidence, only after every required proof passes.

This result record summarizes trusted Kontrol execution; it is not an independently checkable proof certificate. Saved APR records do not attest which runtime helper modules were loaded. Reproduce module selection through the maintained runner; helper hashes identify the reviewed sources rather than certify a saved proof's complete execution context.

Output paths are relative to this project and ignored by Git. Checkpoints live in `out/proofs/` and the execution model in `out/kompiled/`. Foundry artifacts and the final result file also live in `out/`. The profile sets this output path explicitly so Kontrol and Foundry resolve the same artifact root.

SMT queries use a 30-second base timeout with three scaling retries. Execution saves a pending checkpoint after at most 1,000 K steps; this is not a path or loop bound. A 3,600-second step budget allows expensive final implication checks to finish. The runtime retries timed-out steps with smaller execution chunks, but shrinking execution depth cannot speed up a terminal implication check. Unfinished paths remain pending. Rewrite trace logging is disabled to reduce output overhead.

To execute concrete witnesses independently:

```sh
cd verification/cart
FOUNDRY_OUT=/private/tmp/cart-native-out FOUNDRY_CACHE_PATH=/private/tmp/cart-native-cache \
  forge test --offline --match-contract '^Cart(Settlement|Inventory|Approval|Authorization|Revocation)Proof$' --match-test testConcrete
```

Keep native output and compiler caches outside this project. The pinned Kontrol release scans its effective artifact root recursively, including hidden directories; an in-project `.native-out` can contaminate artifact discovery.

Run from this directory. Foundry root and remapping resolution differ when invoked from the repository with `--root`.

## Claims

| Fixture | Property |
| --- | --- |
| Settlement | Two native lines grouped to one recipient pay exactly, capture spread, preserve independent native/WETH baselines, and record execution. |
| Settlement | Native input funds a WETH payout through Cart's conversion logic. |
| Settlement | WETH input funds a native payout, preserves initial balances, and captures WETH spread. |
| Settlement | A modeled exact-output ERC20 route spends the quote, pays exact obligations, captures spread, and clears both approval layers. |
| Approval | A partial spend leaves one unit in each allowance layer; Cart must revoke both and capture unused input as protocol spread, preserving independent ERC20 baselines. |
| Inventory | Duplicate lines aggregate into one listing fill bucket. |
| Inventory | Two purchases accumulate fills and reject identical replay. |
| Inventory | Overfill after a successful purchase rejects without changing state or balances. |
| Inventory | Two individually valid lines cannot independently reuse the same listing capacity. |
| Inventory | Late payout failure restores reserved quantity, replay state, and balances. |

The authorization batch adds ten properties: valid authorization, rejected platform and seller authorization, changed payment amount, signed line/route/action hash consistency, seller isolation for a cached root, Merkle membership, and Cart domain binding. Nine revocation properties cover listing cancellation, root cancellation, nonce invalidation, isolation of those three operations between sellers, expired orders, expired roots, and acceptance exactly at both deadlines.

Positive calls assert successful execution. Rejections assert expected custom error selectors. The specifications use Solidity `assert` rather than relying on test-runner assertion helpers.

## Assumptions and limits

The runner loads `CART-WORD-ARITHMETIC`, an extra trusted module with two guarded arithmetic identities. The first rewrites `X XOR (2^256 - 1)` as `(2^256 - 1) - X` for a word-sized nonnegative X. The second rewrites `chop(X - Y) == 0` as `X == Y` for Keccak-valued operands in `[0, 2^256)`, in either comparison orientation. Matching only hash expressions avoids testing range guards against unrelated arithmetic; the checked mathematical identity holds for all word-sized operands. Stock symbolic reasoning misses these identities in some inventory and Merkle paths.

`verify_lemmas.py` binds the reviewed K modules and both SMT formulas by SHA-256, then requires bundled Z3 to return UNSAT for both negated identities before a run and before acceptance. The complement formula uses a 257-bit sum that cannot overflow. The difference formula uses integer modulo directly, matching KEVM's definition of chop. Applying the results relies on the documented K integer-XOR and KEVM chop semantics and the explicit range guards. These are solver-checked arithmetic justifications for trusted rewrites, not kernel-certified K theorems. They add no Cart-specific assumption or quantity restriction. The original complement-only module remains available for reproducing earlier runs.

The proofs use Kontrol’s default `TEST_CONFIG`: chain ID 1, fixed caller and deployment addresses, `2^30 < block.timestamp < 2^35`, and `2^24 < block.number < 2^32`. Other default environment constraints in the pinned runtime also apply. These are modeled executions, not a proof across every possible chain environment.

The fixture additionally assumes the block timestamp is at most `type(uint48).max - 1 days`, keeping order deadlines representable by Permit2. The revocation claims cover the specific expiry boundaries described below.

Amounts and quantities are symbolic `uint96` values, with explicit positive-amount assumptions. Listing proofs require nonzero listing digests and singleton Merkle roots, matching Cart’s reserved zero digest and invalid-root checks; they do not prove the absence of Keccak zero preimages. Array shapes are fixed at one or two lines and zero fulfillment actions. Most fixtures use one listing; the cached-root seller-isolation claim supplies two listings from different sellers. Listing proofs use one singleton Merkle root, unit price 1, and OFF_CHAIN fulfillment. Transaction sequences contain at most two successful purchases plus one rejected call. These specifications do not establish arbitrary-history induction or full-array-size coverage.

Order IDs are fixed at 1 and 2. Most fixtures use SKU and listing salt 1; authorization mutations also use the fixed value 2. The fixture is both buyer and protocol spread recipient, so a payment back to it does not establish a general payer-refund behavior.

The settlement, approval and inventory fixtures assume platform and seller signatures through an ERC1271 signer that accepts every digest. The authorization and revocation fixtures instead use separate digest-selective ERC1271 oracles. Only a fixture-approved digest returns the ERC1271 magic value. This checks Cart's enforcement of modeled authorization decisions, not ECDSA recovery, a production wallet implementation, or cryptographic unforgeability. Oracle configuration methods are controlled by the fixture and are not proposed production wallet code.

The changed-amount and wrong-domain properties explicitly assume their different signed messages have different digests. The Merkle-membership property asserts distinct leaves for the selected salt mutation and relies on the pinned runtime's hash model. These are cryptographic-model limits, not proofs of real Keccak collision resistance. Payload-hash mismatch properties deliberately approve an envelope with a hash different from the supplied payload; they establish equality enforcement rather than exhaustive hashing of every field. The cached-root seller-isolation claim uses a valid first singleton leaf and asserts that the different-seller guard rejects before checking the second leaf. It does not cover a multi-leaf tree containing valid membership proofs for both sellers.

Revocation starts with a fresh seller nonce of zero. Each claim performs one cancellation or nonce increment followed by one purchase attempt. Isolation uses one fixed alternate caller. Order/root expiry checks reject one second before the current timestamp, and a positive control accepts deadlines equal to the timestamp. Arbitrary prior fills, nonce-overflow behavior, arbitrary histories, and arbitrary timestamp ranges remain outside this batch.

Executable dependency models implement exact-transfer ERC20, backed WETH conversion, two-layer Permit2 spending, and a fixed exact-output router. These models exclude fee-on-transfer, rebasing tokens, arbitrary callbacks, real AMM pricing, arbitrary Universal Router programs, and hostile dependency implementations. The actual Cart code and its delegatecall boundaries are retained.

Gas is unbounded under Kontrol's default configuration. No gas-cost or transaction-completion-within-block-limit claim is made. No UUPS upgrade, NFT transfer/mint, or arbitrary-recipient reentrancy property is established here.

## Negative control

`CartNegativeControl.checkWrongPayout()` first executes a known valid grouped purchase and then asserts an incorrect recipient balance. It is excluded from normal test discovery and the positive proof selection. Run explicitly:

```sh
verification/cart/kontrol.sh prove \
  --match-test '^test%CartNegativeControl\.checkWrongPayout' \
  --workers 1 --smt-timeout 30000 --smt-retry-limit 3 \
  --max-depth 10000 --no-log-rewrites --step-timeout 120 --hide-status-bar
```

Its expected result is an assertion failure after successful settlement. This was observed: the saved failing state has recipient balance 18 while the deliberate assertion requires 19, with zero pending nodes. An incomplete proof, tool failure, or setup failure is not a successful negative control. Do not include this method in the maintained positive suite.

## Evidence

All 29 property proofs and five setup proofs passed the strict acceptance check, including all 19 new authorization/revocation properties. The previous ten properties remain accepted. Every accepted record has zero pending, failing, or bounded nodes, no admissions or refutations, and no configured bounded-model-checking depth. Initial program bytes match the current harness artifacts. Both checked arithmetic identities returned UNSAT in bundled Z3 4.13.4. Results are saved in `out/verified-results.json`.

Eleven concrete witnesses and all ten parameterized specifications at 256 fuzz runs each (2,560 sampled cases) also passed on the finalized fixtures. The entire native suite passed 29 tests, including eight inherited duplicates. Solidity formatting, shell syntax, Python compilation, and whitespace checks passed. Native testing is separate evidence from the formal Kontrol results.

The new authorization and revocation native suites passed 38 tests: 19 concrete witnesses and 19 parameterized specifications at 256 fuzz runs each (4,864 sampled cases). These runs used the finalized new sources and were separate from the initial 29-test run. Independent review found no remaining concrete specification or acceptance defect.

Final acceptance also verified exact initial program bytes for every proof. All 73 distinct source files referenced by the five harness artifacts matched their metadata Keccak hashes at completion. No production contracts were changed for this proof batch.
