# Sepolia free-listing repair, October 27, 2026

The corrective upgrade restores free Listings, zero-value merchandise lines, and zero-total Orders while retaining the capacity, listing-index, hashing, and mint-result improvements. All four approved transactions succeeded.

| Contract | Address |
| --- | --- |
| Cart proxy, unchanged | `0x1EBF35b3A76caEf60a009d2786A66A91D42A38Bc` |
| Cart implementation | `0x12d6D589F03076C68D1602e5e11B02485a72A0b1` |
| CartPayments | `0x29009e5B49833AD5ad9FdcB43F4427d10f6B6436` |
| CartLens | `0x9cfE838f95fDB8564d8F72E72E2208a3Dd124cD3` |
| CartRoutePolicy, unchanged | `0xbF6c6D2E8Be99cDc5882d186c40fDF9222892f9C` |
| CartHashes, unchanged | `0x7cF7626AA1881FFeb2004705886DA42605Ec9A0F` |

The [proxy upgrade](https://sepolia.etherscan.io/tx/0x05ae2023640a210d968ba06f0d571361639de5413d997452bac41ea9b6384eb9) replaces the implementation without an initializer. Owner, platform signer, protocol recipient, Universal Router, Permit2, WETH, pause state, route policy, and EIP-712 domain match the pre-upgrade values. Purchases remain unpaused.

The [deployment ledger](data/cart-sepolia-free-listings-2026-10-27.json) records receipts, live estimates, submitted limits, source and artifact hashes, runtime checks, and pre/post-upgrade state. All three deployed runtimes match the tested artifacts. Immutable addresses identify the preserved policy and expected new payment executor and implementation.

## Validation

`FOUNDRY_PROFILE=cart forge test --offline` passed 646 tests across 19 suites with no failures or skips, including the storage-upgrade canary. Each stateful invariant completed 256 runs and 128,000 calls without reverts. The corrective upgrade also passed a Sepolia fork simulation before broadcast.

After confirmation, the new Lens accepted a genuinely signed zero-price Listing with `valid = true` and code `OK`. The same Listing and authorization returned `INVALID_LISTING` from the previous `0x7DD8…E9B5` Lens. This was a read-only preflight, without executing a purchase or consuming inventory.

The [checkout reconciliation record](cart-checkout-reconciliation-2026-10-27.md) describes the stale-base regression and recovery copies. `NetworkConfig.s.sol` now records the confirmed addresses. Integrations keep the proxy address and switch to the new Lens through the SDK address update.

## Transaction gas

The sender estimated each transaction with the live RPC, supplied a 50 percent buffer, and waited for confirmation before proceeding. It checked the remote branch, clean source checkout, source hashes, signer nonces, deployed runtimes, and live proxy state. It did not use the older local simulator's deployment gas estimates.

| Transaction | Receipt gas | Transaction |
| --- | ---: | --- |
| CartPayments | 15,636,674 | [Receipt](https://sepolia.etherscan.io/tx/0x279b5f31fd6e6742bd995f556a108c30507a35d3b5dd8a7a7eed2cab437025f8) |
| Cart | 27,732,235 | [Receipt](https://sepolia.etherscan.io/tx/0xb674b46e8dec6e5cce696d4c7064e59003c57591685e8d36139b9747c1d373d7) |
| CartLens | 15,041,549 | [Receipt](https://sepolia.etherscan.io/tx/0xd2c69a63b0dbaeac9fee018dc248eaa03573c8ee18fe3836015a49320ae23fae) |
| Upgrade | 42,622 | [Receipt](https://sepolia.etherscan.io/tx/0x05ae2023640a210d968ba06f0d571361639de5413d997452bac41ea9b6384eb9) |
