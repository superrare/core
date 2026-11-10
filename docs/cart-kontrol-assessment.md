# Kontrol assessment for Cart

Original assessment on October 23, 2026. This historical source assessment predates the implementation in [verification/cart](../verification/cart/README.md); see that project for current execution evidence. Links to upstream `master` describe the source inspected today; a production pilot must pin the tool and dependency revisions.

The implementation now lives in [verification/cart](../verification/cart/README.md). The source assessment below predates that work. Its no-execution statements describe the assessment stage. Check the implementation evidence for current proof status.

## Recommendation

Keep Kontrol as the next option if a bounded symbolic pilot exposes important coverage gaps. Its main benefit for Cart is the ability to prove inductive loop summaries using K. That benefit requires more proof engineering than passing the existing suite to another runner. Runtime Verification's loop tutorial explicitly constructs an invariant from EVM states and proves it, rather than deriving one automatically. [Loop invariant tutorial](https://runtimeverification.com/blog/formally-verifying-loops-part-2)

My suggested first experiment is a settlement proof with one or two order lines, symbolic amounts and initial balances, real Cart-to-CartPayments delegatecalls, and explicit token and recipient implementations. Expand to grouped payouts and callbacks before deciding whether to invest in arbitrary line counts. This is a proposed scope, not measured feasibility.

## What a result means

Kontrol consumes Foundry tests and reasons about EVM bytecode through KEVM. The test's setup, assumptions, external contracts, and assertions define the claim. A passing claim says only what those assertions express for the executions covered. [Kontrol overview](https://docs.runtimeverification.com/kontrol)

Kontrol does not cap loop exploration by default. `--bmc-depth` opts into a finite unrolling bound. A bounded run can report `PASSED` after warning that it cut off paths; that is not an unrestricted proof. A proof review must inspect bounded nodes and incomplete paths, as well as the headline result. [Runtime Verification's explanation and example output](https://runtimeverification.com/blog/formally-verifying-loops-part-1)

Loop invariants permit reasoning across arbitrarily many iterations, but safety on termination and termination itself are different obligations. The tutorial distinguishes partial correctness from total correctness. We should state explicitly whether a Cart claim covers successful settlement, rejection, completion, and gas. [Loop invariant tutorial](https://runtimeverification.com/blog/formally-verifying-loops-part-2)

Kontrol's ordinary prover constructs `APRProof` objects containing a K control flow graph, initial and target nodes, bounded nodes, and subproof references. It invokes K's prover through Kore RPC and records proof data. I found no Rocq certificate checking step in that workflow. Treat the EVM model, cheatcode semantics, K/prover implementation, solver reasoning, and imported lemmas as trusted components unless a separate certificate checking process is demonstrated. This trust inventory is an inference from the inspected implementation, not a claim that certificates are impossible. [Prover source](https://github.com/runtimeverification/kontrol/blob/master/src/kontrol/prove.py)

That differs from the linked Anthropic project, where Claude writes Rocq proofs and the Rocq kernel checks the generated theorem. The article explicitly identifies the models, theorem statements, and checker as trusted components. A Kontrol pass should not be described as the same independent proof certificate guarantee. [Anthropic research](https://www.anthropic.com/research/formal-verification)

## Fit with this implementation

| Cart concern | Assessment |
| --- | --- |
| Upgradeable proxy and payments executor | The existing fixture deploys an ERC1967 proxy, Cart implementation, and CartPayments executor. Cart delegates `begin` and `finish` to payments. Preserve those actual contracts in the proof fixture so storage location, `msg.sender`, `msg.value`, and immutable configuration remain part of the modeled execution. A direct CartPayments call is rejected by its guard. See [fixture](../src/test/cart/CartInvariants.t.sol), [delegatecalls](../src/cart/Cart.sol), and [executor](../src/cart/CartPayments.sol). |
| Loops and arrays | Cart limits lines to 32, fulfillment operations to 20, Merkle depth to 64, and route commands and inputs to 32. Payments also groups recipients with nested scans and loops over token snapshots. These limits help define a finite domain; proving only a two-line test still covers only two lines. Compiler-generated data-copy loops also need coverage. See [Cart](../src/cart/Cart.sol), [payments](../src/cart/CartPayments.sol), and the [upstream explanation of compiler-generated loops](https://runtimeverification.com/blog/formally-verifying-loops-part-1). |
| Existing stateful invariants | The current handler performs three kinds of purchase and then checks baseline balances and approvals. Its listings and actions are empty. Proving a single handler invocation from setup does not prove the property after arbitrary sequences. A durable invariant needs a base case and preservation from a valid arbitrary prestate for every relevant transition, including cancellation and failure paths. See [CartInvariants.t.sol](../src/test/cart/CartInvariants.t.sol). |
| Opaque route inputs | Route inputs contain nested dynamic bytes. The ordinary Kontrol ABI guidance requires concrete lengths using NatSpec annotations, including nested struct and tuple elements. Symbolic contents are useful, but a concrete length is a coverage condition. [Dynamic input guidance](https://docs.runtimeverification.com/kontrol/guides/kontrol-example/dynamic-types) |

The concrete-size frontend limitation does not mean arbitrary-length reasoning is theoretically unavailable. Runtime Verification documents an Optimism engagement that needed custom loop invariants for arbitrary-length bytes copying and bounded handling for a separate proof array. Cart should budget for similar K work if arbitrary route-input lengths are part of the intended theorem. [Dynamic constructs case study](https://runtimeverification.com/blog/using-kontrol-to-tackle-complexities-caused-by-dynamically-sized-constructs)

## External calls and Foundry compatibility

Kontrol supports `mockCall`, `mockFunction`, code replacement, symbolic storage, and call/storage restrictions. Their semantics are part of the model. A `mockCall` that returns bytes does not exercise the callee's actual transfer or callback behavior. For a reentrancy claim, deploy an executable hostile recipient/token/router that calls back into Cart, or prove a suitably general external-call model separately. This is the implication of replacing external execution with a return-value mock. [Cheatcode documentation](https://docs.runtimeverification.com/kontrol/cheatsheets/cheatcodes)

The existing `vm.addr` and `vm.sign` calls are implemented, so listing them as unsupported would be incorrect. However, the inspected signing helper delegates to `ECDSASign` through a rule marked `[concrete]`. A fixed private key works for concrete signing, but Cart's signed digest depends on symbolic order values. The ordinary concrete signing rule will not evaluate that symbolic digest. Options include a separate payment fixture below signature validation, fixed signatures with concrete signed fields, or explicit crypto lemmas/models. Each changes what is covered. Unknown cheatcodes fall through to `CHEATCODE_UNIMPLEMENTED`. [Cheatcode implementation](https://github.com/runtimeverification/kontrol/blob/master/src/kontrol/kdist/cheatcodes.md)

The documented reuse path is `kontrol build` followed by `kontrol prove` on selected test functions. It is a basis for porting existing assertions and setup; it is not evidence that Foundry's stateful invariant scheduler is reproduced automatically. [Foundry property verification guide](https://docs.runtimeverification.com/kontrol/guides/kontrol-example/property-verification-using-kontrol)

Use the repository's `cart` Foundry profile so the pilot compiles Solidity 0.8.18 with the existing `viaIR` and optimizer settings. Pin bytecode hashes with the proof results. Check the selected Kontrol release's CLI before scripting; current source accepts `--match-test`, while some documentation still shows `--test`. `--use-gas` explicitly enables gas computation. [Repository configuration](../foundry.toml), [current CLI source](https://github.com/runtimeverification/kontrol/blob/master/src/kontrol/cli.py)

## Installation and CI cost

Official installation guidance recommends 16 GB RAM and 16 GB swap, offers Kup and Docker installation, and provides a GitHub Actions integration. The project README estimates 30 minutes to an hour for the first dependency fetch/build and includes an Apple Silicon source-build setting. These are upstream estimates, not timings for Cart. [Installation guidance](https://docs.runtimeverification.com/kontrol/overview/readme/installations), [README](https://github.com/runtimeverification/kontrol)

The Nix flake includes an `aarch64-darwin` Foundry dependency and exports a Kontrol package, so there is a documented source path for this Mac's architecture. Actual installation success and resource use remain untested here. [Nix configuration](https://github.com/runtimeverification/kontrol/blob/master/flake.nix)

The Docker Hub listing shows versioned images such as `runtimeverificationinc/kontrol:ubuntu-jammy-1.0.255`, listed as `linux/amd64`. The live manifest's compressed layers total 2,074,360,747 bytes, about 1.93 GiB. The tag listing was cached, so it establishes a candidate tag rather than the latest release. An Apple Silicon Docker run would need an architecture-compatible image or amd64 emulation. Pin a working image digest rather than relying on an untagged pull. [Published tags](https://hub.docker.com/r/runtimeverificationinc/kontrol/tags)

CI should begin with one worker and a dedicated Linux runner. The upstream cheatsheet recommends at most `(RAM_GB - 8) / 8` workers. Keep proof artifacts, tool versions, compiler settings, assumptions, bounded-node counts, and exact selected claims with the run. Introduce more parallel workers only after measuring the pilot. The artifact policy is my recommendation; the worker estimate is upstream guidance. [Kontrol cheatsheet](https://docs.runtimeverification.com/kontrol/cheatsheets/kontrol-cheatsheet)

## Local evidence and remaining work

No Kontrol executable benchmark was completed. `kontrol` and `nix` were absent. Docker socket access failed in the default sandbox. Docker 29.8.2 was subsequently accessible outside the sandbox, with no cached Kontrol image. The documented `runtimeverificationinc/kontrol:latest` manifest lookup failed.

The versioned `runtimeverificationinc/kontrol:ubuntu-jammy-1.0.255` manifest lookup succeeded. Docker reports Linux amd64 and manifest digest `sha256:858f004144d61b005997f56bb8b7cd15673850286c96e0e5ec0502d9c9a9e204`. This establishes an available image candidate. It does not establish that the image successfully runs a Cart proof. The multi-gigabyte image was not downloaded during this assessment.

Before selecting Kontrol, require one successful nontrivial payment proof, one deliberately broken variant that fails, a successful purchase witness, measured runtime and memory, and an explicit statement of all length bounds, token models, callback behaviors, and gas assumptions. Stop the feasibility experiment if implementing the first useful claim requires extensive bytecode-specific K lemmas that the team cannot maintain.
