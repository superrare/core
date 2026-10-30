# Authorization and revocation proof batch

## Accepted result

Complete: final strict acceptance session83345 exited0. All29 properties and5setups passed with exact current-artifact program bytes, zero pending/failing/bounded states, no admissions/refutations, and bmc_depth=None. Both approved arithmetic queries returnedUNSAT. Final73-source metadata hash audit had zero mismatches. Native new38/38 passed; independent review found no remaining concrete defects. Evidence: out/verified-results.json.

## Goal contract

Implement and execute Kontrol proofs for Cart signature rejection, signed-payload binding, seller isolation, cancellation, nonce invalidation, and expiry. Preserve production changes and all existing proof fixtures. Use digest-selective ERC1271 models: authorization decisions are explicit assumptions, not accepting-all signatures or a proof of ECDSA cryptography.

Completion requires native witnesses and parameterized specifications passing, all new property and setup APR proofs passing with no pending/failing/bounded/admitted/refuted obligations, exact current-artifact program matching, retained previous thirteen accepted proofs, and documented scope. Positive controls must show that valid authorization can execute. Negative claims must assert the intended rejection and unchanged balances, fill and replay state.

Non-goals: NFT fulfillment, general hostile-dependency proofs, arbitrary-history induction, administrator security, full cryptographic implementation verification, deployment or publication.

## Work graph

- Common authorization fixture: coordinator, implement, accepted. New standalone fixture only; no changes to existing base/models/specs. Stop when native-compilable interface is ready.
- Authorization specifications: complete, independently reviewed and all10 current-program formal claims accepted; final native rerun81288 after the arithmetic fixture repair. New CartAuthorizationProof.t.sol only. Native tests and source review required before formal execution.
- Revocation specifications: complete, independently reviewed, native18/18 and all9 formal claims accepted. New CartRevocationProof.t.sol only. Native tests and source review required before formal execution.
- Integration/runtime: complete, EXPECTED and runner extended to19new claims/two setups. Total acceptance34 records =29properties+5setups. Current model and retained previous proof programs validated.
- Independent review: separate reviewer, accepted all new specs/integration; no remaining implementation findings. Validate non-vacuity, modeled authority, intended error paths and acceptance coverage.
- Final acceptance/documentation: complete; strict gate83345 passed all34records and documentation records final scope/evidence.

Operational constraints: pinned runtime, existing checked arithmetic helper, K heap3GiB, step-timeout600, slow progress checks per user preference. Keep native artifacts outside this project. Archive prior result manifest before expanding acceptance; never count incomplete claims as proved. No production changes to make proofs pass.

## Historical execution evidence

The entries below record intermediate states and investigations. The accepted result above is authoritative.

- Revocation native18/18 and Authorization native20/20 passed, each parameterized method at256 fuzz runs. Final Authorization rerun14252 includes removal of unnecessary crossseller digest inequality.
- Independent review accepted all19 claims, commonbase and acceptance coverage. Merkle inequality assertion relies on runtime hash model; changed amount/domain have explicit distinct-digest assumptions.
- Model build95756 succeeded. Prior Settlement/Inventory/Approval deployed harness bytecode hashes unchanged from /private/tmp/cart-bytecode-before-authorization.json. Prior accepted manifest archived at out/proof-history/accepted-before-authorization.json.
- Approved helper check passed in pinned Z3 4.13.4 (UNSAT).
- New formal invocation uses two exact prefixes: ^test%CartAuthorizationProof\.testProof_ and ^test%CartRevocationProof\.testRevocation_; --lemmas lemmas/word-complement.k:CART-WORD-COMPLEMENT --workers 3 --smt-timeout 30000 --smt-retry-limit 3 --maintenance-rate 1 --max-depth 10000 --no-log-rewrites --step-timeout 600 --hide-status-bar --xml-test-report. Existing proofs not selected or reinitialized.
- Formal tool session43809 active. Do not run prove.sh during it, because the fresh runner archives checkpoints.
- First formal milestones: signedLinesHashMustMatch:0 and signedRouteHashMustMatch:0 confirmed passed via APRProof API (pending0/failing0/bounded0/admittedfalse). Runtime container keen_lamarr. Read-only cheap checkpoint monitor /private/tmp/cart-auth-checkpoints.py; formal status still requires APR API/final strict checker.
- Additional APR API confirmed passes: validAuthorization, sellerRejectsUnapprovedRoot, platformApprovalUsesCartDomain; all pending0/failing0/bounded0/admittedfalse. Five new properties accepted so far. Remaining claims executing without observed failures.

## Arithmetic fixture repair

- cachedRootCannotAuthorizeDifferentSeller:0 failed at node41 before Cart, panic0x11. Impossible path: ((quantity << 1) & (2^97-2)) / quantity !=2 despite0<quantity<2^96. This is the compiler's checked multiplication overflow guard in fixture paymentAmount=q*2, not Cart seller-isolation behavior.
- Stop invocation43809/containerkeen_lamarr before changing sources. Replace multiplication with equivalent widened addition q+q, preserving every transaction/input amount and assertion. No production change or new trusted rule. All Authorization harness programs must be reproved after changed bytecode; prior five preliminary passes are invalidated for current artifacts. Revocation setup and old thirteen accepted proofs remain reusable if hashes match.
- Native repair rerun81288: Authorization20/20 passed,256 fuzzruns each. Model rebuild37029 succeeded; all three old harness bytecodes still exactly match prior accepted artifacts. New batch restarted with the same nineteen selectors and solver/runtime flags; no --reinit or digest overrides, so changed Authorization artifacts obtain fresh versions naturally. Revocation setup0 remains reusable.
- Restarted formal tool session37842 active. Earlier43809 stopped. Do not read old Authorization version0 passes as current evidence; new class program changed. All assertions and uint96 domains preserved by equivalent q+q repair.
- New container zealous_wozniak. Authorization setup:1 created and complete; new methods naturally version1. Initial new workers select cached-seller, actions hash, and Merkle claims first. No digest forcing. Cheap monitor now shows only latest versions per method.
- Repair confirmed formally: cachedRootCannotAuthorizeDifferentSeller:1 PASSED; sellerRejectsUnapprovedRoot:1 and signedActionsHashMustMatch:1 also PASSED through APR API, all pending0/failing0/bounded0/admittedfalse. No new trusted arithmetic rule or narrowed inputs needed. Remaining batch37842 active.

## Modular arithmetic prover repair

- Merkle membership:1 node74 failed because Cart accepted on infeasible path `chop(oldLeaf-newLeaf)==0` despite the earlier distinct-leaf assertion and word bounds. The real unequal branch rejects InvalidMerkleProof correctly. No Solidity change planned.
- Candidate bounded modulo identity: for0<=x,y<2^256, `(x-y) mod2^256=0` iff x=y. Independent bundled Z3 Int/mod negation UNSAT. Read-only actual-node explicit-module simplification being checked before adopting anything.
- Pinned CLI --lemmas accepts only one file:module, not a list. New reviewed aggregate CART-WORD-ARITHMETIC will contain original complement plus guarded modular-zero rules; original helper remains unchanged for historical runs. Verification must bind aggregate/queries and check both identities. Failed Merkle must run fresh with aggregate, no manual graph edits/pruning/admission. Other current claims continue unchanged.
- Aggregate module exact actual-node diagnostic PASSED: node74 -> #Bottom with empty constraints; both hash-word bounds discharge. Independent math review accepted all guards/negative-difference semantics. No node modifications.
- verify_lemmas.py now binds4 reviewed files (legacy complementK/SMT, aggregateK, differenceSMT) and requires both queries UNSAT. Pinned Z3 check passed. Fresh maintained runner selects CART-WORD-ARITHMETIC. Main batch37842 continues using the sound complement subset; no need to invalidate correct completed proofs for adding an independently valid rule.
- Fresh Merkle invocation uses --reinit --setup-version 1, exact sellerRootRequiresMerkleMembership selector, aggregate module, workers1 and unchanged30s/3retry/600s flags. Version2 must establish the original claim fresh. No Solidity or model rebuild for this arithmetic repair.
- Consolidate pending execution under the checked aggregate: changedAmount:0 atnode39 retried a600s step while other methods remained active. Stop main37842 and dedicatedMerkle82876 containers; preserve every checkpoint. No source/program/digest changes. Resume all19 selectors in one invocation using aggregate and4workers. Four concurrent servers previously used ~5GiB combined with3+1workers, within8GiB VM. Completed current proofs retained; latestMerkle:2 resumes, oldfailed:1 unselected. This avoids leaving pending digest comparisons on the old module when the reviewed modulo rule is available.
- Consolidated active formal tool session12475; aggregate module, workers4, same solver/checkpoint flags, no reinit/digest overrides. Source/model unchanged. Stop old sessions37842/82876 completed. All new Solidity files remain frozen; current Authsetup1,Revsetup0; old13 proof programs unchanged.
- Generic aggregate made four pending steps repeatedly exceed600s with little progress. Hash-specific specialization matches only Keccak outputs, whose bounds stock rules discharge syntactically; mathematical theorem unchanged. No controlled runtime benchmark completed because its Java parser took>4min under load and was stopped; causation is a hypothesis, not a measured conclusion.
- Saved generic module at out/proof-history/word-arithmetic-generic.k (fcfd... hash). Repo aggregate now specialized to Keccak differences, new SHA256 ae1449ab57d6915d533c2e4d637aef2c8159e437a44f690ab37dc30a1986f7c9. Verifier hash not updated until independent review.
- Docker stop vigorous_agnesi returned 'tried to kill container, but did not receive an exit event'. Checking actual state before new execution; do not start another main run while old status unresolved. Helper source was updated after stop attempt; live oldRPCs already loaded generic module; any future proof startup could load specialized module. Both are sound reviewed identities, but record mixed context honestly. No Solidity/program changes.
- Independent review approved specialized hash-only rules mathematically (samefourguards, no added injectivity assumption). Verifierapprovedhash updatedae1449..., SMTformulas unchanged.
- Container stop eventually removed processnamespace; cleanup exec failedbecause /proc/PID namespacewasgone. docker rm --force succeeded; old session12475 exited137. No other containers restarted/touched. All checkpoints persisted.
- Request exact specialized-module node74 #Bottom diagnostic with workers stopped, before new mainrun. Next execution plan: aggregate, max-depth1000, workers3, step-timeout600, sameSMT30s/3retries. Reducedchunkischeckpointfrequency, notBMC/pathbound.
- Exact specialized aggregate diagnostic PASSED: SHA256ae1449... modulem193f04ca...; retainedMerkle:1node74 -> exact#Bottom, constraints[]. No graphwrite or modelbuild.
- Resuming all19 selectors with specialized aggregate, workers3, max-depth1000, sameSMT30s/3retries andstep600. No reinit/digest/programchanges. All completed valid current proofs preserved; latestMerkle:2 remains pending/resumes.
- CURRENT active formal tool session81803. All earlier main sessions stopped; no model/Solidity changes since q+q fix. Final gate still requires34 records29properties+5setups. Do not claim completion or run fresh prove.sh while active.
- Active main81803 container nice_cori. Specialized rule+1000stepchunks now making steady checkpoint progress, no new failures. Controlled attribution to one tuning change not established.
- Full Merkle membership:2 PASSED through APR API (pending0/failing0/bounded0/admittedfalse), resolving falsepath failure:1 without source weakening or node edits. Current domain-binding:1 also PASSED via API. Current helpersourcehashae1449... is the accepted specialization. Other current completed newclaims: cachedseller1,invalidplatform1,invalidseller1,actionhash1,linehash1 (7currentproperties total; final strict gate remains authoritative).

## Cached-result provenance repair

- In-run APR API program audit found signedRouteHashMustMatch:0 passed but its initial program did NOT match current Authorization artifact. Kontrol skipped this method based on its cache despite class bytecode changing; exact-program acceptance guard correctly prevents reuse. Every other audited latest proof, including changedAmount:0, matches current artifacts. ChangedAmount:0 also confirmed passed.
- Fresh explicit reinit for signedRouteHashMustMatch with setup-version1 and specialized aggregate, workers1/max-depth1000/sameSMTflags. This produces version1 without source changes. Main81803 continues Revocation/validAuth without overlap; route0 already skipped/completed in its queue. Latest route1 must pass before final gate.
- OtherNonce isolation:0 remained pendingnode58 >15min while peers advanced. Docker top showed its oldest booster elapsed30min CPU5m53, noZ3child, versus otherboosters CPU18m/25min and13m/18min. Treat as stalled worker. Stop main81803/containernice_cori only; separate route refresh95608 continues. Resume ONLY Revocation prefix workers3 to avoid overlapping active Route:1. All Authcurrent exceptRoute:1 now have complete checkpointgraphs; final API/gate still authoritative.
- CURRENT active sessions:6282 (Revocation9 prefix, workers3, specialized aggregate/max-depth1000/step600/SMT30s+3retries) and95608 (freshRouteHash:1, workers1, sameflags/setup1). Main81803 stopped cleanly. No source/model/digestchanges and no reinitforRevocation. Wait both then run strict checker all34records.
- Route refresh95608 completed PROOF PASSED: signedRouteHashMustMatch:1 (34m6s). No active separateAuthrun remains.
- Pinned APR API audit85330 accepted ALL10 current Authorization properties +setup: every latest program matches currentartifact, passedtrue, no pending/failing/bounded/admitted/refuted nodes, bmcNone. ChangedAmount latest0 matchescurrent; Merkle latest2; otherslatest1. Authorizationimplementation/formalnode accepted. Remaining ONLY9Revocation properties active6282.
- Final source-provenance check planned after execution: artifact metadata.sources contains keccak256 per source, paths relative to verification/cart (or /workspace absolute). Compare current source bytes via host cast keccak, mapping /workspace to repo root, to ensure long-running artifacts did not become stale due concurrent source edits. Do this once at final acceptance; no rebuild unless a mismatch is real. Host cast supports stdin hex and is available.

- Source provenance audit: all73 distinct source files referenced by the five current harness metadata records match their current exact-byte Keccak hashes. Audit saved at /private/tmp/cart-auth-source-audit.json; repeat only if sources change before final acceptance.

## Terminal implication time budget

- Revocation otherNonce isolation closed ordinarily; otherRoot isolation terminal156 repeatedly exceeded600s. Independent pinned-source inspection confirmed the whole step is interrupted, its unfinished result discarded, then retried with smaller execute_depth. Terminal subsumption runs before execution, so shrinking depth cannot help this check.
- Stop6282/containerbrave_lamport and resume the nine Revocation selectors with step-timeout3600, same ordinary implication semantics/SMT flags/helper/checkpoints. Maintained runner updated to3600. No assume-defined option, source/model change, graph edit, pruning, admission, or narrowed domain.
- Final independent review accepted all19 specifications and acceptance integration; no remaining concrete findings.
- Resumed Revocation execution active tool session59491, workers3, step-timeout3600. Prior6282 stopped cleanly. No other proof containers overlap.
- Expanded time budget resolved the repeatedly interrupted terminal matching: otherRootCancellationIsIsolated and sellerRootCancellation now have complete checkpoint graphs. No flags changing implication semantics used. Five earlier Revocation claims independently confirmed passed via APR API session10216. Remaining checkpoint execution: deadlinesInclusive and otherListingCancellationIsIsolated. Final34-record gate still pending.

## Final acceptance

- Revocation session59491 exited0 with all9 claims PASSED using ordinary matching and step-timeout3600.
- Strict checker session83345 exited0 and wrote out/verified-results.json: all34 required records accepted,29properties+5setups; previous13 retained. Both approved Z3 queriesUNSAT. No stale program, pending/failing/bounded/admitted/refuted proof, or BMC depth accepted.
- Final metadata provenance audit matched all73 distinct sources. Solidity formatting, shell syntax, Python compilation and whitespace checks passed.
- No production edits, commits, PRs, deployments or publication made for this batch. Earlier user changes preserved.
