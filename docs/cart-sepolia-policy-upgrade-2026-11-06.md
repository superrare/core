# Sepolia Cart policy upgrade, November 6, 2026

The Cart proxy `0xACfF2622f53f360274df3014DC135EfDC058786B` was upgraded on Ethereum Sepolia, chain 11155111, using source revision `042bcd74143986629eaf7f45d683e4df3af23b3e`. This rotates the policy, payment executor, implementation, Lens, and Hashes helper. The proxy address and EIP-712 domain remain unchanged.

## Replacement contracts

| Contract        | Address                                      |
| --------------- | -------------------------------------------- |
| CartRoutePolicy | `0x534055AF4D780b1776EE443D388B748abdF2da97` |
| CartPayments    | `0x95984953917BE6b94CeeA5CF90b271D5B07eB4a2` |
| Cart            | `0x3F440079Ac99D99d418F1355FdE4BA3110271cE0` |
| CartLens        | `0xD9f2ED84317D517fc8e393227D76c63227e3f823` |
| CartHashes      | `0xD0e7aeE76485Bb3D6af3aBa187014DC636afF12A` |

[NetworkConfig](../script/NetworkConfig.s.sol) records the replacement addresses. The [deployment ledger](data/cart-sepolia-policy-upgrade-2026-11-06.json) contains all six successful receipts, transaction gas limits, compiler settings, source fingerprints, runtime verification, before-and-after configuration, custody balances, and historical replay samples.

## Policy and client behavior

The policy accepts the captured V4 swap/SETTLE/TAKE form and V3 router-custody/unwrap form. Final sweeps and V4 takes return to Cart. Swaps and wrap/unwrap may use temporary router custody. The executor still rejects any increase in final tracked router balances and preserves preexisting Cart funds. Cart remains responsible for signed payouts and spread distribution.

`validate(bytes,bytes[])` binds explicit final recipients to its caller. The matching Lens uses `validateFor(cart,commands,inputs)` for the same recipient context during advisory previews. Checkout tuples, hashing, event schemas, and storage layouts are unchanged. See the [route protection rules](cart-route-protection.md).

The existing SDK Cart PR #13 updates Lens and Hashes addresses and ABI provenance. Routing PR #14 accepts the matching settlement forms, normalizes equivalent Cart/router recipients without rewriting swap bounds or payer flags, and retains the final native refund. Four read-only live compatibility tests passed against the deployed policy and Lens. They compare raw and SDK-normalized provider programs and reject third-party or router-directed final takes. The restacked SDK passed 650 local cases, with 14 skipped, plus type checking and lint with no errors.

## Verification and preserved state

All five deployed runtimes match the local compiler artifacts after checking immutable self, policy, and executor addresses. All five contracts passed Etherscan source verification. Compilation used Solidity 0.8.18, via IR, optimizer 100, and the Paris target.

The implementation slot and policy getter point to the replacement contracts. Owner, platform signer, pause state, WETH, Permit2, Universal Router, and domain separator match their pre-upgrade values. The proxy runtime is unchanged. Sampled historical executed-order flags remain true, and the observed Cart ETH, WETH, USDC, and RARE balances are unchanged.

Domain separator: `0x1e7887329a023bdf8be1222d4ffb0c7f5fcc113d90adf75067552e288eb05c44`.

The upgrade call passes empty migration data. It does not reinitialize the proxy or intentionally change inventory, cancellation, seller nonce, or replay state. Existing approvals and valid signatures retain the same target and domain. No new Cart proxy registration is required for this upgrade. The earlier [fresh deployment record](cart-sepolia-fresh-2026-11-06.md) remains the proxy's deployment and indexing anchor.

Before deployment, 299 local Cart test cases and four pinned Sepolia fork cases passed. The fork cases execute signed checkouts for both captured routes and verify rejection and rollback for stranded WETH and direct seller routing. No signed purchase was broadcast as part of this rollout.

## Transactions

| Action          | Transaction                                                                                                   | Receipt gas used |
| --------------- | ------------------------------------------------------------------------------------------------------------- | ---------------- |
| CartRoutePolicy | [Receipt](https://sepolia.etherscan.io/tx/0xec493f13aeab0a9d3dad506d1ef123777a9b10e17cca233ef962fbc25d3138ec) | 5075805          |
| CartPayments    | [Receipt](https://sepolia.etherscan.io/tx/0x2fc78674fea22eccb6a1a78a037d39c7d9d561624e268e6e5e30d341823770fd) | 18704719         |
| Cart            | [Receipt](https://sepolia.etherscan.io/tx/0x1c901cf9342d647fc1203dfbfbaaca0b816c5eb8b376e69e25e21eeafd7d1ab6) | 29604951         |
| CartLens        | [Receipt](https://sepolia.etherscan.io/tx/0x74fab2687be3f920eae1ec08bb79da8f4589c77a7f3d2a09b4aadc861cb7f30d) | 16102942         |
| CartHashes      | [Receipt](https://sepolia.etherscan.io/tx/0xecd33b5bbc6e1efceed15e55ec715ec54c666392601b2954910135ecbc46183d) | 4214533          |
| Upgrade         | [Receipt](https://sepolia.etherscan.io/tx/0xbf7a45e371be40b479be33854ec0070e737cc14773bb7916418c6ed10c07dcde) | 42566            |

The checked-in dependency-rotation wrapper used live-node estimation, multiplier 150, and sequential confirmations. All five creations and the upgrade transaction succeeded.

## Deployment follow-up

Foundry's resume path initially could not find the owner wallet because it skips the script's `run()` and `vm.startBroadcast`. Supplying the wallet explicitly completed verification without another deployment. The fresh wrapper now supplies its configured private key to resume. A local regression resumes a completed six-contract broadcast and asserts that no transaction is resubmitted and the deployer nonce is unchanged.

Trace metadata lookups also emitted nonfatal console-contract and Etherscan rate-limit warnings. They did not prevent deployment or completion of all five source verifications.
