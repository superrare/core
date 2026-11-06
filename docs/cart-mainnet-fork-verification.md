# Verify Cart on a mainnet fork

The fixture pins Ethereum mainnet block **25,800,000** and deploys the
Cart bundle locally on the fork.

## Coverage

- Deployment dependencies match Ethereum NetworkConfig: real Universal Router, Permit2, and WETH. Router code hash and pool identities/liquidity are checked by the fixture.
- Seven router-template tests cover ETH wrapping/unwrapping and V2/V3/V4 exact-input and exact-output routes, including refunds.
- Nine Cart tests cover mixed routes, ETH/WETH normalization, surplus capture, output shortfall, disallowed third-party delivery, protected unnamed tokens, and the new seller-signed split scenarios.

The successful split case has three off-chain seller listings and an ETH fee line. V3 swaps ETH through WETH into DAI, and V4 swaps ETH into USDC. One listing distributes `1 ether + 3` DAI units at 80/20; another distributes `1,000,001` USDC units at 50/50. Both share primary and secondary recipients. A third unsplit DAI listing pays the same primary recipient, as does the ETH fee. Assertions verify exact currency-specific balances, remainder allocation to the primary, no split inheritance, fills, replay state, and surplus delivery. Preexisting Cart ETH and WETH remain protected; Cart-to-Permit2 and Permit2-to-router WETH allowances end at zero.

The second split case rejects the last ETH fee payout after routing and earlier split payouts. It verifies rollback of recipient and payer balances, spread balances, listing fills, and order execution state, and checks the original Cart custody baselines.

## Reproduce

Set `ETH_MAINNET_RPC_URL` to an archive-capable Ethereum mainnet RPC without exposing the credential in logs. Then run with local dependencies installed:

```sh
FOUNDRY_PROFILE=cart FOUNDRY_TEST=src/test/forks/ethereum/cart forge test --offline -vv
```

If a linked worktree cannot build with its installed dependencies, use an
isolated Foundry root with the same pinned dependencies and configuration.
Record the source revision, fixture hash, effective compiler settings, and
results.

## Limits

The pinned fixture checks behavior at one block. Simulate release payloads
at the intended deployment state to check liquidity, quotes, and gas admission.
The mixed-currency split cases use off-chain fulfillment. The local advanced
checkout suite covers NFT transfers with splits.
