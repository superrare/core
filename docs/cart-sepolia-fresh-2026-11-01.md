# Fresh Sepolia Cart deployment, November 1, 2026

A fresh Cart suite was deployed from commit `593f13bf465b43c2ace4f37fe246b704c16d30a4` on Sepolia, chain 11155111. This replaces the test environment's active addresses. The previous proxy was paused after the replacement passed runtime and configuration checks. It was not upgraded.

## Addresses

| Contract | Address |
|---|---|
| CartRoutePolicy | `0x26066b6da5e9028224418e51edad9e518276e560` |
| CartPayments | `0xabedd30055cf87afa0231ac375293e1b795691f7` |
| Cart | `0x977338b1ebb0eb5f2e37e6b45edd25c4adfa0780` |
| ERC1967Proxy | `0xb08876f9c661667af22e85859357bb31c4e11741` |
| CartLens | `0xb6812159892b48363b6b3ec4e8f0c34944d8e4ab` |
| CartHashes | `0x78554e14fb196de79a8e4ce49c1fca4e6d46b8bd` |

[NetworkConfig](../script/NetworkConfig.s.sol) records these addresses. The [deployment ledger](data/cart-sepolia-fresh-2026-11-01.json) contains all seven successful receipts, live gas estimates, transaction limits, artifact SHA-256 fingerprints, immutable verification results, and proxy configuration reads.

## Verification and deployment method

Deployment used the fresh constructor and initialization sequence in `script/cart/CartDeploy.s.sol`, plus new Lens and Hashes contracts. A local orchestration adapter reused `Upgrade.deploy` and `Upgrade.send` from `tools/upgradeCartFreeListings.py` for live RPC estimation, a 25 percent gas margin, nonce checks, sequential receipt confirmation, and runtime comparison. It did not call an upgrade function. The checkout guard verified the remote PR head before broadcast. Compiled artifact metadata source hashes were checked against the checkout before deployment.

All six deployed runtimes match the compiled Solidity 0.8.18, via IR, optimizer 100 artifacts after checking immutable addresses. To reproduce the build, recover the original compiler input, including EVM target, and the pinned dependency revisions. This record captures the artifact hashes and runtime comparison but does not capture the full compiler input. The proxy implementation slot points to the new Cart implementation. Owner, platform signer, Universal Router, Permit2, and WETH match the previous deployment. The new proxy is unpaused. Its reserved former treasury slot is zero.

Owner: `0xba68422a154e459f7b4992a95ad358d412b6bd1d`.

Platform signer: `0xf7885c18e2757fbaea2dcfff3ac0df94520f4eae`.

New domain separator: `0x84247b6ba9142a2eb9368b858cabe552cc1a10d72da904192da2e1271379ccb2`. The new proxy address changes the EIP-712 domain, so signatures for the old proxy cannot authorize this deployment.

The current source includes signed order spread recipients, seller-signed per-listing splits, and indexed payout aggregation. Runtime and configuration verification were performed on Sepolia; no signed end-to-end checkout against the new deployment was submitted during this rollout.

## Transactions

| Action | Transaction | Receipt gas used |
|---|---|---|
| CartRoutePolicy | [Receipt](https://sepolia.etherscan.io/tx/0x622a20e1b5d9591130873ac32d0d3054c42108f0e545b9e2f8679b801551b278) | 1285714 |
| CartPayments | [Receipt](https://sepolia.etherscan.io/tx/0x9afe5c8c3d8b0654d5f7531e6df447b2fde905b8281126c7e3e6e66f920babbc) | 17309951 |
| Cart | [Receipt](https://sepolia.etherscan.io/tx/0x36c4d79d4c15ef9a660127522fe9ee1c918e6d34722db2759105d312a88e3e98) | 29518318 |
| ERC1967Proxy | [Receipt](https://sepolia.etherscan.io/tx/0x6e873ac87516e3f004d2ee10036484b6e7404c6de869be9df3d1200a0145b6f0) | 1665326 |
| CartLens | [Receipt](https://sepolia.etherscan.io/tx/0xf9cda78162587b686d3bc384591aa63bc5898646593b5e6973ef2708803cee5e) | 15863224 |
| CartHashes | [Receipt](https://sepolia.etherscan.io/tx/0x92b5b8eead6d54a83535dce4a8c0479b0a646c0cfc51ae1ea39ba27f0d01fea5) | 4220729 |
| PauseOldCart | [Receipt](https://sepolia.etherscan.io/tx/0xfdb1d09d42b088ade662fb3b90489a0a883da25f8e85e7165a336fa8512ea7ee) | 36177 |

## Retired deployment and integration boundary

The old proxy, `0x1ebf35b3a76caef60a009d2786a66a91d42a38bc`, is confirmed paused by the owner transaction above. Its implementation and historical state remain intact. Pausing does not cancel its outstanding signatures; keep it paused while retired.

The new proxy starts with empty listing fill, cancellation, seller nonce, and order replay state. No old inventory or cancellation history was migrated. Recreated test listings must use intended remaining quantities and fresh seller authorizations.

SDK, frontend, backend, and indexer cutover were pending at this deployment checkpoint. Confirm current consumer configuration separately. The new proxy requires its own approvals and signatures, current ABI bindings, and regenerated Listing Roots.
