# Formal verification tools for Cart

Assessed on October 23, 2026 against the working tree based on commit `606df5c35615ffff3b4b18ffd997e34f75ada295`. This checkout includes uncommitted Cart changes. Results belong to the tested working tree and must be rerun after changes.

## Recommendation

The selected direction is a maintained Kontrol suite, implemented under [verification/cart](../verification/cart/README.md). The Halmos fixtures below are the earlier compatibility experiment. Formal completion of the Kontrol claims requires the strict result checker in that project to pass. Both tools need explicit assumptions about external contracts.

The original assessment combined an executable Halmos compatibility experiment with a [source assessment of Kontrol](cart-kontrol-assessment.md). That initial assessment did not execute Kontrol. The maintained project now pins and runs Kontrol; its README records the current evidence.

## What matters for this Cart

The [Cart implementation](../src/cart/Cart.sol) uses Solidity 0.8.18, optimizer runs of 100, and `viaIR`. Purchases execute through an ERC1967 proxy and delegate funding and settlement to [CartPayments](../src/cart/CartPayments.sol). The proof must retain those calls to cover storage, caller identity, and native value propagation. A payment-executor-only model would establish a narrower claim.

The current implementation permits 32 order lines, 20 fulfillment operations, 64 Merkle siblings, and 32 route commands. The design document still describes a 20-line limit. Tool scopes must use the implementation being tested. The limits on route command counts do not bound the byte length of every opaque input.

Existing [stateful invariants](../src/test/cart/CartInvariants.t.sol) check repeated purchases with deterministic router outputs, empty listings, and empty fulfillment actions. Their assertions are useful specifications, but neither a few example purchases nor a bounded sequence establishes an invariant over arbitrary histories.

## Comparison

| Concern | Halmos | Kontrol |
| --- | --- | --- |
| Specification | Solidity assertions through a Foundry frontend. [Project](https://github.com/a16z/halmos) | Foundry specifications interpreted through KEVM. [Overview](https://docs.runtimeverification.com/kontrol) |
| Loop coverage | Explicit finite unrolling. A pass with a loop-bound warning is incomplete. Installed 0.3.3 defaults to two iterations. | Can use inductive loop summaries written in K. Bounded execution is also available, and can pass with cut-off paths. [Loop tutorial](https://runtimeverification.com/blog/formally-verifying-loops-part-1) |
| Dynamic inputs | Installed 0.3.3 exposes length choices through `--array-lengths` and default length lists. Review the selected sizes with each result. | Ordinary ABI guidance uses concrete lengths. Broader dynamic proofs can require custom K lemmas. [Dynamic inputs](https://docs.runtimeverification.com/kontrol/guides/kontrol-example/dynamic-types) |
| Signatures | The installed `vm.sign` implementation models signatures and recovery with symbolic functions and constraints. Cryptography is an assumption. [Source](https://github.com/a16z/halmos/blob/main/src/halmos/cheatcodes.py) | Signing is implemented, but the native signing rule needs concrete inputs. Symbolic order digests need adaptation. [Source](https://github.com/runtimeverification/kontrol/blob/master/src/kontrol/kdist/cheatcodes.md) |
| Local setup | Halmos 0.3.3 installed in a temporary Python virtual environment on this Apple Silicon Mac. | No Kontrol or Nix executable installed. Published candidate container requires Linux amd64. |
| Best initial use | Small fixed-shape checks with symbolic amounts and explicit success assertions. | A narrowly scoped proof when maintaining K lemmas is justified by the required guarantee. |

Halmos's older getting-started page says dynamic arrays must be constructed with fixed sizes. The installed CLI now exposes multiple selectable sizes. Use the pinned executable's behavior and report all selected bounds. Its default panic filter is assertion failure `0x01`. Use `--panic-error-codes '*'` to include arithmetic and other panics. Ordinary application reverts still require low-level calls and explicit success assertions. [Getting-started guide](https://github.com/a16z/halmos/blob/main/docs/getting-started.md)

## Compatibility fixture

[CartToolAssessment.t.sol](../src/test/cart/formal/CartToolAssessment.t.sol) deploys the actual Cart proxy, implementation, payment executor, and route policy. It reuses the existing token, WETH, Permit2, and router test contracts. An ERC1271 stub accepts authorization so the settlement experiment avoids signing symbolic order digests. It does not establish signature security.

The checks cover these deliberately limited cases:

- One-command route policy acceptance for a symbolic byte, including forbidden flags and command families.
- One native purchase with two lines grouped to one recipient. Positive line amounts, spread, and initial native and WETH balances are symbolic `uint96` values. Successful execution, exact grouped payment, protocol spread, baseline restoration, and replay-state recording are asserted.
- One ERC20 purchase with one output line and a mock exact-output route. The mock spends the quote through both approval layers. The check asserts exact output and spread, initial token balance restoration, approval amounts observed during routing, and cleared approvals afterward.

Every purchase check captures the low-level call result and asserts success before checking outcomes. Concrete Foundry witnesses exercise successful purchases. `canary_wrongNativePayout` changes the expected payout by one unit and is selected separately as a negative control.

The success assertion matters because Cart already has explicit final balance and allowance checks. Proving only that successful calls satisfy those checks adds limited assurance. The useful question also asks whether valid modeled purchases complete and deliver their exact obligations without spending initial balances.

These checks exclude listing fills, fulfillment, arbitrary callbacks, real Universal Router semantics, upgrades, full `uint256` amounts, arbitrary array sizes, and arbitrary execution sequences. The native check preserves a WETH baseline but does not exercise ETH/WETH conversion. A later proof must cover conversion in both directions and independent initial native and WETH balances.

## Measured results

Halmos passed all three checks. The final run reported these results with loop unrolling set to 64 and Z3 assertion timeouts set to 30 seconds:

| Check | Explored paths | Normal returns | Blocked paths | Truncated loops | Check time |
| --- | ---: | ---: | ---: | ---: | ---: |
| ERC20 routing and approvals | 17 | 2 | 0 | 0 | 3.59 seconds |
| Native grouped payouts | 14 | 2 | 0 | 0 | 9.54 seconds |
| One-command route policy | 12 | 11 | 0 | 0 | 0.29 seconds |

The purchase checks have successful paths and therefore do not pass solely because execution always reverts. No check reported a counterexample, solver timeout, blocked path, or truncated loop. These counts apply only to the fixed shapes and assumptions described above.

The separately selected negative control failed as intended. Halmos found two counterexamples to the deliberately incorrect payout assertion in 10.07 seconds, with no blocked paths or truncated loops. This is an expected specification failure in the assessment fixture.

The initial 96-file Cart-profile compile took 548.12 seconds. Its checks took 8.23 seconds. The narrower profile and formatted fixture required a separate 80-file compile of 138.97 seconds, followed by about 13.85 seconds for setup and checks. The negative-control run reused the build and took 16.14 seconds overall. These measurements describe this Mac and its current load. They are not a performance comparison with Kontrol, which was not executed.

The ordinary Foundry checks passed both concrete purchase witnesses and all 17 existing route-policy tests. The machine-readable symbolic reports are `out/cart-halmos-assessment.json` and `out/cart-halmos-canary.json`. The repository ignores `out`, so regenerate those reports with the commands below when sharing the fixture.

The final artifact fingerprints below are SHA256 hashes of the bytes in `deployedBytecode.object`. They identify compiled templates before constructor-time immutable address patching. The fixture deploys configured instances during `setUp`.

| Artifact | Template SHA256 |
| --- | --- |
| Cart | `4b31a8bc4ce10b9560da0b0db3a51a2b073e338b7cea3cd36ec50e9d781f32b0` |
| CartPayments | `778f1492be95bfa3fe38c59eaa3de19814640f406bf1f010e1716b8157b6b75a` |
| CartRoutePolicy | `c07676b8386877530b13f2695d46dfbae04c556508e6d58b37c3db996a7b027e` |
| CartToolAssessment | `36a28a0b265730f93f9a753c51c2617402735d5e1099186a9663e2a98acea611` |

The next useful pilot should extend the settlement fixture to independent native and WETH baselines, conversion in both directions, and grouped payouts across more than one currency. Then add a repeated-listing inventory property and executable hostile callbacks. Evaluate Kontrol on the same first claim if those scopes require excessive case enumeration, incomplete bounds, or difficult-to-maintain Halmos assumptions.

## Reproduction

The local environment uses Apple Silicon, Python 3.14.5, Foundry 1.4.3, Halmos 0.3.3, Z3 4.12.6, and Solidity 0.8.18. Halmos installed successfully in a temporary virtual environment. Its first build requests AST, storage layout, and metadata for the Foundry profile, which triggers a broader rebuild than the ordinary witness tests.

Default sandbox execution of Foundry crashed in macOS system proxy discovery. The same route-policy test command outside the sandbox passed all 17 tests. Both concrete assessment witnesses also passed outside the sandbox.

Install the same tool in an isolated environment:

```sh
python3 -m venv /tmp/cart-formal-halmos-venv
/tmp/cart-formal-halmos-venv/bin/python -m pip install 'halmos==0.3.3'
FOUNDRY_PROFILE=cart FOUNDRY_TEST=src/test/cart/formal FOUNDRY_SCRIPT=src/test/cart/formal \
	forge test --match-contract '^CartToolAssessment$' --offline
FOUNDRY_PROFILE=cart FOUNDRY_TEST=src/test/cart/formal FOUNDRY_SCRIPT=src/test/cart/formal \
	/tmp/cart-formal-halmos-venv/bin/halmos \
	--contract CartToolAssessment --solver z3 --loop 64 \
	--panic-error-codes '*' --solver-timeout-assertion 30s \
	--statistics --no-status --json-output out/cart-halmos-assessment.json
FOUNDRY_PROFILE=cart FOUNDRY_TEST=src/test/cart/formal FOUNDRY_SCRIPT=src/test/cart/formal \
	/tmp/cart-formal-halmos-venv/bin/halmos \
	--contract CartToolAssessment --function canary_ --solver z3 --loop 64 \
	--panic-error-codes '*' --solver-timeout-assertion 30s \
	--statistics --no-status --json-output out/cart-halmos-canary.json
```

The canary must fail at its incorrect payout assertion after successful execution. A failure to build, unsupported execution, or timeout is not a successful negative control. Review JSON for normal paths, blocked paths, bounded loops, counterexamples, and timeouts. A headline pass alone is insufficient.

Pin the compiler configuration, tool and solver versions, contract bytecode hashes, input sizes, assumptions, and claim definitions with any production result. A Cart upgrade requires new checks against its actual bytecode.
