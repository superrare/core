# Cart Kontrol implementation

## Objective and status

Complete: reproducible Kontrol proofs over the production Cart proxy and payment executor, preserving preexisting production changes. No production contracts were changed to obtain passing proofs.

The final pinned-runtime acceptance check accepted all ten property proofs and three setup proofs. Every record passed with zero pending, failing, or bounded nodes, no admissions or refutations, and no bounded-model-checking depth. Initial program bytes match current harness artifacts. Evidence is in `out/verified-results.json`; assumptions and reproduction instructions are in `README.md`.

Work graph: runtime/integration, settlement fixtures, inventory fixtures, partial-spend approval fixture, formal execution, independent review, and final acceptance are complete.

## Validation

- Four settlement, five inventory, and one partial-spend approval property proved.
- All three setup proofs proved. The checker selects setups explicitly because test subproof IDs are empty in this runtime.
- Negative control `CartNegativeControl.checkWrongPayout():0` failed at its deliberate assertion with zero pending nodes: recipient balance18, deliberately expected19. Production was not mutated for this control.
- Eleven concrete witnesses and ten parameterized specs at256 fuzz runs passed (2560 sampled cases). Whole native suite29/29, including8 inherited duplicates.
- Solidity formatting, Bash syntax, Python compilation, and whitespace checks passed.
- Independent review found no additional material acceptance gap. The manifest checks status, program provenance, and approved helper justification; it is not a certificate of a saved proof's runtime-module context.

## Runtime and trust decisions

- Pinned Kontrol1.0.255/K7.1.337 container digest, bundled Z3 4.13.4, Solidity0.8.18, viaIR, optimizer100, ast=true. Profile explicitly sets out="out".
- Checkpoints in out/proofs, model in out/kompiled, digest in out/digest. Native outputs/cache stay outside project. Former root outputs were moved intact; old model archived under out/proof-history/before-explicit-output-path. Current artifacts have identical retained Settlement/Inventory bytecode to the previous model.
- Wrapper caps each compiler JVM at3GiB (CART_K_OPTS override). The default8GiB per JVM exhausted Docker memory while compiling two backends. Capped rebuild succeeded.
- Solver base30s/three scaling retries; checkpoint chunk10000 K steps, not a path/loop bound. Final runner step budget600s lets solver retries and final matching complete. Slow steps remain pending until proved.
- Explicit root-index initialization avoids an unevaluated symbolic out-of-buffer zero-padding expression. Inventory valid-input assumptions require nonzero digest/root matching production checks; no inventory assertions were removed.
- Added one range-guarded integer-complement rewrite. Independent 257-bit nonwrapping arithmetic query is UNSAT; fixed hashes bind the reviewed K rule and formula. The K integer correspondence is trusted and documented, not kernel-certified. No Cart-specific assumptions or quantity restrictions were introduced.
- Pinned CLI simplify-node adds extra modules but fails to select them. A read-only direct API diagnostic explicitly selected the helper and reduced the old impossible failure path to #Bottom. No saved node edits, pruning, admissions, or refutations were used. Failed duplicate-lines version0 is preserved; fresh version1 proved with the helper.

## Recorded execution

All prove commands below used the approved `--lemmas lemmas/word-complement.k:CART-WORD-COMPLEMENT`, `--smt-timeout 30000 --smt-retry-limit 3 --maintenance-rate 1 --max-depth 10000 --no-log-rewrites --hide-status-bar --xml-test-report`.

- Settlement0 and payout-rollback0 completed earlier without needing the helper and remain unchanged.
- Session67698: `--reinit --setup-version 0 --match-test '^test%CartInventoryProof\.testProof_duplicateLinesShareCapacity' --workers 1 --step-timeout 120`; fresh version1 passed in41m56s.
- Session25541: separate exact selectors for Inventory CannotIndividuallyReuseCapacity, overfillAfterPurchaseRollsBack, twoPurchasesAndReplay, and Approval testUnusedApprovalRevoked; workers2/step-timeout120. First two Inventory claims passed. Stopped after final TwoPurchases matching repeatedly exceeded the budget; checkpoints retained.
- Session49768: separate selectors for `^test%CartInventoryProof\.testProof_twoPurchasesAndReplay` and `^test%CartApprovalProof\.testUnusedApprovalRevoked`; workers2/step-timeout600. Both version0 claims passed (5m39s and31m10s respectively).
- Final session25547 ran `check-results.py` in the pinned image and exited0, writing all13 accepted records plus checked-helper metadata.

This file records the initial ten-property phase. The next authorization/revocation batch is tracked in [AUTH-WORK.md](AUTH-WORK.md). The maintained `verification/cart/prove.sh` now selects all 29 positive claims and five setups, with the current helper and runtime limits documented in [README.md](README.md). It removes stale acceptance records, verifies the helpers, builds, archives old proofs, and requires strict acceptance. Do not run it concurrently with a proof process.
