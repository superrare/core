# Creator membership USDC billing

`CreatorMemberships` implements fixed-price calendar-month subscriptions paid directly to an artist (95%) and a SuperRare treasury (5%). Members authorize USDC spending and submit their first payment. SuperRare submits renewal transactions and pays their gas; contract renewal is permissionless and constrained to the member's immutable terms. Membership benefits remain account-based in the application; no NFT is minted.

The EIP-712 initial authorization binds the subscription ID, payer, artist, amount and expiry to this contract and chain. The contract rejects early/duplicate renewals, overlapping subscriptions for the same payer/artist, self-subscriptions, expired quotes, prices outside 1–500 USDC and fractional-cent prices. Each successful payment purchases a full calendar month from its timestamp, with month-end clamping. Recovery is allowed for seven days after expiry and never charges arrears.

A payer or operator can cancel. An artist or operator can permanently end the artist's offer. Both remain available while payments are paused. Cancellation does not change the paid-through timestamp. The owner can pause/unpause and rotate the operator; token, treasury and 5% fee are immutable. Use a separately managed operator and multisig owner. The contract holds no USDC and exposes no refund/withdrawal function.

## Verification

```sh
git submodule update --init --recursive
npm ci --ignore-scripts
FOUNDRY_PROFILE=memberships forge test -vv
npx prettier --check src/memberships/CreatorMemberships.sol src/test/memberships/CreatorMemberships.t.sol script/memberships/creator-memberships-deploy/CreatorMembershipsDeploy.s.sol
npx solhint src/memberships/CreatorMemberships.sol src/test/memberships/CreatorMemberships.t.sol script/memberships/creator-memberships-deploy/CreatorMembershipsDeploy.s.sol
```

The profile pins Solidity 0.8.24, Paris EVM and 512 fuzz runs. Solady's calendar library is pinned by submodule; OpenZeppelin's existing repository version supplies EIP-712, signatures, access control, pausing, reentrancy protection and SafeERC20. Passing tests is not an independent contract audit.

The required application integration workflow lives in `superrare-monorepo/docs/creator-memberships-usdc-operations.md`. It deploys this compiled artifact on a pinned Sepolia Anvil fork, uses the actual Circle USDC implementation and real PostgreSQL, and exercises sponsored renewal, worker restart, reorganization recovery, deduplication, cancellation and paid access. Application ABI: `libraries/abis/src/creator-memberships.ts` in that repository.

## Deployment

Provide the values listed in `script/memberships/creator-memberships-deploy/env.sample` through an approved secret store or ignored local file. `MEMBERSHIPS_DEPLOY_ENV` can identify a trusted shell environment file. Run `bash script/memberships/creator-memberships-deploy/deploy.sh` to simulate. Only an explicitly authorized deployment should use `--broadcast`, which also requests source verification. The script validates chain 1 or 11155111 and that chain's native USDC address.

Record the source revision, compiler settings, constructor roles, deployment receipt/block and verified bytecode. The application validates token/treasury/operator against this deployment and requires a funded renewal runner, scheduled invocations and alerts. A budget and independent review are required before a mainnet launch. No live Sepolia or mainnet address is claimed by this branch.
