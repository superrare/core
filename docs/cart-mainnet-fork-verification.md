# Cart mainnet-fork verification, November 2, 2026

All 17 tests across three suites pass against Ethereum mainnet block **25,800,000**, with zero failures or skips. The tests deploy the current Cart implementation, payments executor, route policy, and proxy locally on the fork. Production source is unchanged from `b05d955` and the November 1 Sepolia deployment. No transaction was broadcast, and no production signing key was used.

## Coverage

- Deployment dependencies match Ethereum NetworkConfig: real Universal Router, Permit2, and WETH. Router code hash and pool identities/liquidity are checked by the fixture.
- Seven router-template tests cover ETH wrapping/unwrapping and V2/V3/V4 exact-input and exact-output routes, including refunds.
- Nine Cart tests cover mixed routes, ETH/WETH normalization, surplus capture, output shortfall, disallowed third-party delivery, protected unnamed tokens, and the new seller-signed split scenarios.

The new successful split case has three off-chain seller listings and an ETH fee line. V3 swaps ETH through WETH into DAI, and V4 swaps ETH into USDC. One listing distributes `1 ether + 3` DAI units at 80/20; another distributes `1,000,001` USDC units at 50/50. Both share primary and secondary recipients. A third unsplit DAI listing pays the same primary recipient, as does the ETH fee. Assertions verify exact currency-specific balances, remainder allocation to the primary, no split inheritance, fills, replay state, and surplus delivery. Preexisting Cart ETH and WETH remain protected; Cart-to-Permit2 and Permit2-to-router WETH allowances end at zero.

The second split case rejects the last ETH fee payout after routing and earlier split payouts. It verifies rollback of recipient and payer balances, spread balances, listing fills, and order execution state, and checks the original Cart custody baselines.

## Reproduce

Set `ETH_MAINNET_RPC_URL` to an archive-capable Ethereum mainnet RPC without exposing the credential in logs. Then run with local dependencies installed:

```sh
FOUNDRY_PROFILE=cart FOUNDRY_TEST=src/test/forks/ethereum/cart forge test --offline -vv
```

The recorded run used an isolated scratch Foundry root with repository source/dependency symlinks and this fork test directory, Solidity 0.8.18, via IR, optimizer runs 100. The [result summary](data/cart-mainnet-fork-2026-11-02.json) records test names and the source fingerprint. Its gas numbers cover entire tests, not checkout transaction estimates.

## Limits

These results validate current contracts against real dependencies at the pinned historical block. They do not establish current liquidity, future quotes, production gas admission, SDK/API/indexer rollout, or operational readiness. The new split cases use off-chain fulfillment and do not add a mainnet NFT fulfillment test. The local advanced-checkout suite separately tests NFT transfers with splits. This run is not an independent security audit or a formal proof.
