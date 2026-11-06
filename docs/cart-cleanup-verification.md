# Verify a Cart refactor

1. Pin the baseline and candidate revisions. Use the same compiler, EVM target,
   optimizer settings, and dependencies for both builds.
2. Compare compiled ABIs and method selectors for Cart and its helpers. Compare
   the signed type definitions, SDK vectors, and payment-state types. Check
   inherited storage and the ERC-7201 namespaces against the storage baseline.
3. Check observable execution order. Include malformed calldata, validation
   precedence, grouped payout order and failure indexes, ETH/WETH separation,
   and callbacks before final settlement checks.
4. Run the Cart suite with pinned dependencies installed.

   ```sh
   FOUNDRY_PROFILE=cart forge test --offline --gas-report
   FOUNDRY_PROFILE=cart forge build --offline --sizes
   ```

5. Compare discovered test scenarios and assertions. Keep shared setup in
   abstract fixtures so executable suites do not inherit duplicate tests.
6. Compare runtime sizes and matched checkout workloads. Read checkout-call
   gas from each benchmark's event and record calldata bytes separately.
   Use [split verification](cart-split-verification.md) for split workloads.
7. Run the [mainnet fork suite](cart-mainnet-fork-verification.md) for changes
   that affect real dependency behavior. Record evidence for the exact candidate
   revision and identify checks that remain open.
