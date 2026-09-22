# Creator membership USDC billing

`CreatorMemberships` implements fixed-price calendar-month subscriptions paid directly to an artist and a SuperRare treasury, initially split 95%/5%. Members authorize USDC spending and submit their first payment. SuperRare submits renewal transactions and pays their gas; contract renewal is permissionless and constrained to the member's immutable terms. Membership benefits remain account-based in the application; no NFT is minted.

The EIP-712 initial authorization binds the subscription ID, payer, artist, amount and expiry to this contract and chain. The contract rejects early/duplicate renewals, overlapping subscriptions for the same payer/artist, self-subscriptions, expired quotes, prices outside 1–500 USDC and fractional-cent prices. Each successful payment purchases a full calendar month from its timestamp, with month-end clamping. Recovery is allowed for seven days after expiry and never charges arrears.

A payer or operator can cancel. An artist or operator can permanently end the artist's offer. Both remain available while payments are paused. Cancellation does not change the paid-through timestamp. The owner can pause/unpause, rotate the operator, and change the platform fee and treasury. Use a separately managed operator and multisig owner. The contract holds no collected USDC and exposes no refund/withdrawal function.

## Authorized administration

- `setFeeBasisPoints(uint256)`, restricted to `owner()`, changes the platform share of **all future payments**, including existing renewals. The initial rate is 500 basis points (5%); one basis point is 0.01%. Accepted values are 0–10,000 (0–100%), so the owner is explicitly trusted to control the full artist/platform split. There is no business fee cap or timelock. The member's total charge remains unchanged. The fee rounds down in integer USDC base units and the artist receives the remainder.
- `setTreasury(address)`, also owner-only, redirects the platform share of future payments. Zero, this contract, and the USDC token contract are rejected. It does not redirect the artist's share or move past payments. Validate and simulate the destination before submitting through the owner multisig.
- `FeeBasisPointsChanged` and `TreasuryChanged` include the previous and new values. Each `MembershipPaid` records the actual fee amount, rate and treasury used; historical accounting must use that event's terms rather than the current configuration. Zero-value transfers are omitted at 0% and 100%.
- Two-step ownership transfer uses the existing OpenZeppelin `transferOwnership` / `acceptOwnership`. A pending owner, member, artist or renewal operator cannot administer fees or treasury unless they are also the current owner. These setters work while paused.

The token, enrollment payer/artist/monthly amount, calendar-month cadence and seven-day renewal window remain fixed. This contract is not upgradeable. The new payment event ABI replaces the earlier undeployed prototype ABI; deploy this revision and use the corresponding application ABI together.

## Verification

```sh
git submodule update --init --recursive
npm ci --ignore-scripts
FOUNDRY_PROFILE=memberships forge test -vv
npx prettier --check src/memberships/CreatorMemberships.sol src/test/memberships/CreatorMemberships.t.sol script/memberships/creator-memberships-deploy/CreatorMembershipsDeploy.s.sol
npx solhint src/memberships/CreatorMemberships.sol src/test/memberships/CreatorMemberships.t.sol script/memberships/creator-memberships-deploy/CreatorMembershipsDeploy.s.sol
```

The profile pins Solidity 0.8.24, Paris EVM and 512 fuzz runs. Solady's calendar library is pinned by submodule; OpenZeppelin's existing repository version supplies EIP-712, signatures, access control, pausing, reentrancy protection and SafeERC20. Passing tests is not an independent contract audit.

The required application integration workflow lives in `superrare-monorepo/docs/creator-memberships-usdc-operations.md`. It deploys this compiled artifact on a pinned Sepolia Anvil fork, uses the actual Circle USDC implementation and real PostgreSQL, and exercises sponsored renewal, fee/treasury rotation, historical fee replay, worker restart, reorganization recovery, deduplication, cancellation and paid access. Application ABI: `libraries/abis/src/creator-memberships.ts` in that repository.

## Deployment

Provide the values listed in `script/memberships/creator-memberships-deploy/env.sample` through an approved secret store or ignored local file. `MEMBERSHIPS_DEPLOY_ENV` can identify a trusted shell environment file. Run `bash script/memberships/creator-memberships-deploy/deploy.sh` to simulate. Only an explicitly authorized deployment should use `--broadcast`, which also requests source verification. The script validates chain 1 or 11155111 and that chain's native USDC address.

Record the source revision, compiler settings, constructor roles, deployment receipt/block and verified bytecode. The application validates chain/token/operator against this deployment, reads the current fee/treasury from the contract, and requires a funded renewal runner, scheduled invocations and alerts. Fee and treasury changes do not require a server redeploy. A budget and independent review are required before a mainnet launch. No live Sepolia or mainnet address is claimed by this branch.
