# Signed spread-recipient verification

The comparison baseline is PR #26 revision `1df23430daa9aef0911f31b823950f5412e4154b`, immediately after the behavior-preserving cleanup. This migration intentionally changes the checkout interface and signature type.

## Contract behavior and compatibility

`PurchaseOrder.spreadRecipient` follows `paymentAmount` and is required even for free or zero-spread orders. Cart authenticates it in the platform signature and forwards it through the payment executor to every supported-currency residual transfer after line payouts. No global recipient getter, setter, initialization, or configuration-change event remains. `ProtocolSpreadCaptured` retains its existing shape.

Old checkout signatures cannot authorize the new type. Clients must regenerate bindings, rebuild old orders and sign them again. Seller Listing and Listing Root typehashes, other witness typehashes, and the EIP-712 domain remain unchanged. Existing Lens validation-code ordinals are preserved; the new recipient failure code is appended.

The former configuration slot is reserved as `__deprecatedProtocolRecipient`. All namespace locations, field slots, offsets, and types remain unchanged. The upgrade canary verifies a seeded legacy value survives an upgrade, and a settlement test verifies it cannot redirect signed spread. Inherited compiled storage layouts match the baseline.

The upgrade helpers deploy matching executor and hashing helpers or fail before broadcast. No contracts were deployed or upgraded for this change.

## Tests

The final `FOUNDRY_PROFILE=cart forge test --offline --gas-report` run passes 218 tests across 20 suites with no failures or skips. Both stateful invariants complete 256 runs and 128,000 calls with zero reverts. Coverage includes recipient tampering, independently encoded typed-data hashing, old-format signature rejection, signed zero rejection, successive native and multi-token recipients, preexisting-balance protection, retired-slot isolation, and atomic rollback after recipient failure. Lens checks a genuinely signed zero recipient and a valid replacement.

The final build also type-checks the upgrade scripts, Ethereum router-template test, and formal-verification builders. The RPC-backed fork execution was not run because `ETH_MAINNET_RPC_URL` is not configured. Formal proofs were not rerun; saved proof results predate this change.

## Runtime bytecode

Solidity 0.8.18, optimizer 100 runs, via IR, Paris EVM match the baseline. Runtime sizes exclude deployment transaction overhead. All deployable runtimes are below the EIP-170 limit of 24,576 bytes. No external library linking is required. Route policy executable bytecode is unchanged after excluding compiler metadata.

| Contract | Baseline bytes | Signed-recipient bytes | Change |
| --- | ---: | ---: | ---: |
| Cart | 18,041 | 17,565 | -476 |
| CartPayments | 9,821 | 9,801 | -20 |
| CartLens | 9,593 | 9,627 | +34 |
| CartRoutePolicy | 697 | 697 | +0 |
| CartHashes | 2,247 | 2,286 | +39 |

## Checkout gas

All 29 matched checkout cases use the same benchmark workloads and local environment as the cleanup baseline. Each payload grows by exactly 32 bytes for the signed address. Gross checkout-call gas changes range from -0.59% to 0.34%. These are benchmark call measurements; calldata intrinsic gas and chain-specific total transaction costs must be estimated separately for deployment and production admission.

Run the benchmark suites with tracing:

```sh
FOUNDRY_PROFILE=cart forge test --offline --match-contract 'CartListingGasTest|CartERC721GasTest|CartRareERC1155GasTest' -vvvv
```

The [machine-readable comparison](data/cart-signed-spread-verification.json) records every gas case, calldata length, runtime size, and changed method selector. Independent source review found no remaining correctness findings in the integrated code, tests, and operational scripts.
