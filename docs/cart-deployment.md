# Deploy a fresh Cart system

Use this procedure to deploy new Cart addresses. It creates a policy, payment executor, Cart implementation, ERC1967 proxy, Lens, and Hashes helper. It does not upgrade or pause an existing proxy.

## Prepare the checkout

1. Install Foundry and npm.
2. Run `npm run setup:cart`. This initializes only missing Cart dependencies and installs the npm lockfile, including Husky, lint-staged, and commitlint. Existing populated Solidity dependencies stay intact.
3. Copy [env.sample](../script/cart/env.sample) to a private environment file. Set `RPC_URL`, `PRIVATE_KEY`, and `CART_CHAIN_ID`. Set `CART_PLATFORM_SIGNER` for a chain without an initial signer in [NetworkConfig](../script/NetworkConfig.s.sol). Set `CART_OWNER` when the owner differs from the deployer. Set `ETHERSCAN_API_KEY` for explorer verification.
4. Commit reviewed changes to the named deployment branch. Fetch and reconcile its remote reference. The checkout guard requires a clean Cart checkout containing `CART_EXPECTED_REF`, which defaults to `origin/keegan/cart-fixed-quote-currency-swap`.

The fresh deployment wrappers default to chain 11155111. Set `CART_CHAIN_ID` explicitly for another intended chain. Use an authenticated RPC for that chain. The wrappers fail on an unreachable endpoint or unexpected chain before compilation. They do not choose a fallback provider or print authenticated endpoint errors.

`CART_ENV_FILE` selects the environment file explicitly. Without it, the wrappers search the current directory, `script/cart`, and the repository root for `.env`, in that order. Keep credentials out of committed files.

For Ethereum mainnet, set `RPC_URL` to the authenticated Alchemy Ethereum mainnet endpoint and `CART_CHAIN_ID=1` in the gitignored `script/cart/.env.mainnet` file. Leave `CART_PLATFORM_SIGNER` unset to use the committed initial signer in `NetworkConfig`. Run the following command from the repository root to select that file for simulation, broadcast, and resume.

```bash
	export CART_ENV_FILE="$PWD/script/cart/.env.mainnet"
```

## Simulate the deployment

Run the complete script without broadcasting:

```bash
	CART_ENV_FILE="${CART_ENV_FILE:-/absolute/path/to/cart.env}" bash script/cart/deploy.sh
```

Check the RPC chain, owner, platform signer, external dependencies, and optional dependency code hashes. Simulation does not deploy the printed addresses on the network.

The wrapper checks that Cart's required dependency files exist, then lets `forge script` compile them under the Cart profile. Do not run a separate unrestricted `forge build` as deployment preparation. That command can try to initialize unrelated submodules. Missing dependencies produce a setup instruction instead of an automatic install during deployment.

## Broadcast and verify all six contracts

Run the same wrapper with broadcasting and source verification enabled:

```bash
	CART_ENV_FILE="${CART_ENV_FILE:-/absolute/path/to/cart.env}" bash script/cart/deploy.sh --broadcast --verify
```

`--verify` requires `ETHERSCAN_API_KEY` before deployment starts. Omit that flag only when intentionally deferring explorer verification.

Broadcast uses `--slow --skip-simulation`. Foundry estimates gas against the live RPC and confirms each transaction before submitting the next. `CART_GAS_ESTIMATE_MULTIPLIER` defaults to 150 percent and must be at least 100. The wrapper retains the local script's dependency checks before broadcast.

The script prints all six addresses. Foundry saves transactions and receipts together in `broadcast/CartDeploy.s.sol/<chain-id>/run-latest.json`. AST and build information are retained with the compilation artifacts. The wrapper suppresses Foundry's source-parser warning noise while retaining other warnings and errors. Set `RUST_LOG` to override that logging filter.

Verify every receipt's status, the six runtime bytecodes and constructor immutables, the proxy implementation slot, owner, signer, pause state, and external dependencies. Record the source revision, compiler settings, addresses, and verification results. Update `NetworkConfig`, SDK address configuration, and ABI bindings from the confirmed deployment. The [November 6 deployment record](cart-sepolia-fresh-2026-11-06.md) shows the evidence to retain.

Use `deploy-lens.sh` with the same flags only when intentionally deploying a separate Lens. The complete `deploy.sh` already includes Lens and Hashes.

## Continue an interrupted broadcast

Inspect the saved transactions, receipts, deployer nonce, and pending transactions before retrying. A failed verification step can follow a successful deployment. Do not start a fresh deployment to retry verification.

To continue the saved broadcast and verification for the same chain and signer, use Foundry's resume path:

```bash
	CART_ENV_FILE="${CART_ENV_FILE:-/absolute/path/to/cart.env}" bash script/cart/deploy.sh --broadcast --resume --verify
```

Preserve the original checkout and broadcast files. Resume requires the original transaction sequence and compatible signer nonces. Stop and reconcile unexpected pending transactions or nonce changes before retrying.

## Rehearse wrapper changes locally

Run the deployment checks against a disposable loopback Anvil node:

```bash
	python3 tools/testCartDeployment.py
```

The checks use an isolated Git checkout and a local bare remote to exercise the checkout guard. They reject RPC authentication failures, wrong chains, missing verification credentials, unsafe gas margins, and resume without broadcasting. The successful path broadcasts all six deployments, checks live node estimates and sequential confirmations, verifies proxy configuration, and checks the independent Lens wrapper. External dependencies contain fixture code for deployment wiring only. This rehearsal does not verify router behavior or explorer acceptance.
