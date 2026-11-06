# Fresh Sepolia Cart deployment, November 6, 2026

A fresh six-contract Cart system was deployed on Ethereum Sepolia, chain 11155111, from core commit `5ef61a2dbf8f81c635d04b9734a635a269929bf9`. No existing proxy was upgraded.

## Addresses

| Contract | Address |
|---|---|
| CartRoutePolicy | `0xD1eB11D80D76EB8AD42e034436C6122f1576599A` |
| CartPayments | `0x18060529F82e468D39c0ED67e8194C8fB214e435` |
| Cart | `0x9285B46BE6674a307DeC6d7c4BEb7714d770166F` |
| Cart proxy | `0xACfF2622f53f360274df3014DC135EfDC058786B` |
| CartLens | `0x6eED643D5016575952e7F424Dfc708bf8DcC29ab` |
| CartHashes | `0x0377835fbD6050d6CA17cfD154b93E8307205803` |

[NetworkConfig](../script/NetworkConfig.s.sol) records the new addresses. The [deployment ledger](data/cart-sepolia-fresh-2026-11-06.json) records receipts, transaction gas limits, compiler settings, artifact and source fingerprints, runtime comparisons, and proxy configuration.

## Verification

All six contracts passed Etherscan source verification. All six deployed runtimes match the local compiled artifacts. Immutable references contain the expected policy, payment executor, and self addresses. Artifact metadata source hashes match the source files used for deployment. The compiler is Solidity 0.8.18 with via IR, optimizer 100, and the Paris EVM target.

The proxy implementation slot points to the new Cart implementation. The new policy is embedded in both Cart and CartPayments. The new proxy is unpaused. The reserved former treasury slot is zero.

Owner: `0xBa68422A154e459f7b4992a95Ad358d412b6bd1d`.

Platform signer: `0xF7885c18e2757fbaEa2dCfFF3aC0DF94520f4EAE`.

Universal Router, Permit2, and WETH match the configured Sepolia dependencies and have deployed code. A supported zero-amount WRAP_ETH policy probe returned the expected empty asset array, confirming the new typed policy interface.

SDK type checking and lint passed. Its test suite passed 565 tests, with 14 skipped. The built SDK passed live Sepolia reads using its updated public contract exports. It verified the owner, signer, unpaused state, and EIP-712 domain. The deployed Hashes helper matched independent viem calculations. The Lens accepted a supported route through the new proxy and policy. No signed end-to-end purchase was broadcast during this rollout.

## Transactions

| Contract | Transaction | Receipt gas used |
|---|---|---|
| CartRoutePolicy | [Receipt](https://sepolia.etherscan.io/tx/0xd2d5e7dd1b26742f32281d0a2dc0f1b81a9a96b94ff0135d67c0f478b69954fb) | 4551709 |
| CartPayments | [Receipt](https://sepolia.etherscan.io/tx/0x52e6d53627e04ab1b2da57e029c3f5db43caf965e18a2b07eb017849150d412b) | 18704719 |
| Cart | [Receipt](https://sepolia.etherscan.io/tx/0xab7f74d84cabdf560a244f83242725b086212333b5e878655480f10c74560d2e) | 29604951 |
| ERC1967Proxy | [Receipt](https://sepolia.etherscan.io/tx/0xf98470c5d3b56511a8b1cbbe6880e53f3b146580f57473507d6834ca411d1dee) | 1665363 |
| CartLens | [Receipt](https://sepolia.etherscan.io/tx/0x06aa867f12dc6cc05dd31e6570012522df276cef9f6654338cdca5d094dc17c4) | 16082841 |
| CartHashes | [Receipt](https://sepolia.etherscan.io/tx/0x90489768ab519966b1549f204c68182d1d64feec8f0051e6450ac94f87237506) | 4214533 |

The suite and Lens used the checked-in shell wrappers with `--broadcast --slow --skip-simulation` and the default 150 percent live-node gas multiplier. Hashes used the existing Python helper's artifact checks, nonce checks, live estimation, sequential receipt confirmation, and runtime comparison. That helper deployed only Hashes and did not execute its upgrade method.

## SDK cutover

The existing [SDK Cart PR #13](https://github.com/superrare/rare-sdk/pull/13) contains the new proxy, Lens, and Hashes addresses, refreshed contract ABIs, address assertions, and deployment guidance. Its dependent stack layers inherit the update after restacking.

The previous November 1 proxy, `0xB08876F9c661667Af22e85859357bB31c4e11741`, was not modified and remained unpaused at verification. The new proxy starts with empty fill, cancellation, seller nonce, and replay state. No inventory or authorization history was migrated.

The new EIP-712 domain separator is `0x1e7887329a023bdf8be1222d4ffb0c7f5fcc113d90adf75067552e288eb05c44`. Authorizations for another proxy do not authorize this deployment. Sellers must authorize fresh roots with intended remaining quantities. Payers and sellers need approvals for the new proxy. Backend, frontend, and indexer configuration are separate consumer updates.

## Deployment issues and follow-up

- The core checkout's configured Alchemy RPC returned HTTP 401. The SDK's Sepolia RPC worked and was checked for chain 11155111 before broadcast. Add an RPC authentication and chain preflight before starting the build.
- Foundry attempted to initialize unrelated missing submodules during the build. It reported clone failures for populated dependency directories and created empty submodule Git pointers. Compilation succeeded. Those empty pointers were backed up outside the repo, restoring the original dependency state. Make the Cart build use only its required initialized dependencies without attempting unrelated installs.
- `deploy.sh` deploys policy, payments, implementation, and proxy. `deploy-lens.sh` adds only Lens. There is no fresh-system command that also deploys Hashes, so this rollout required a separate deployment through the existing Python helper. Add a single fresh-system path that includes all six contracts and emits their addresses together.
- Foundry printed source-parser, cache-file, and missing Etherscan configuration warnings even though deployment succeeded. Explorer verification required a separate step. Separate actionable failures from trace warnings and include source verification in the deployment workflow.

The broadcast transactions all succeeded. Live-node estimation with the 150 percent margin was sufficient for every deployment.
