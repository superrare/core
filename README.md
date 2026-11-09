# Rare Protocol Core Smart Contracts

This repository contains the Solidity contracts that power Rare Protocol's marketplace, minting, and (legacy) staking systems. This README is a usage guide: it explains what each contract is for, what it pairs with, and what to use today vs. what's deprecated.

## Table of contents

- [Quick reference](#quick-reference)
- [Marketplace](#marketplace)
  - [`SuperRareBazaar` — single-token marketplace](#superrarebazaar--single-token-marketplace)
  - [`RareBatchListingMarketplace`](#rarebatchlistingmarketplace)
  - [`RareBatchAuctionHouse`](#rarebatchauctionhouse)
  - [`BatchOffer`](#batchoffer)
  - [`RareMinter` — blind & sequential lazy minting](#rareminter--blind--sequential-lazy-minting)
- [Token Contracts](#token-contracts)
  - [`LazySovereignNFT` — token contract for `RareMinter` drops](#lazysovereignnft--token-contract-for-rareminter-drops)
  - [`LazySovereignNFTV5` — optional creator-token transfer validation](#lazysovereignnftv5--optional-creator-token-transfer-validation)
  - [`SovereignBatchMint` — standard creator collections](#sovereignbatchmint--standard-creator-collections)
  - [`LazySovereignBatchMint` — lazy batch drops](#lazysovereignbatchmint--lazy-batch-drops)
  - [Choosing between `SovereignBatchMint` and `LazySovereignBatchMint`](#choosing-between-sovereignbatchmint-and-lazysovereignbatchmint)
  - [Factories — how creators get their own contract instance](#factories--how-creators-get-their-own-contract-instance)
  - [Royalty extensions](#royalty-extensions)
- [Infra Contracts](#infra-contracts)
  - [`MarketplaceSettings` — fees, limits, primary/secondary tracking](#marketplacesettings--fees-limits-primarysecondary-tracking)
  - [`ApprovedTokenRegistry` — required ERC-20 allowlist](#approvedtokenregistry--required-erc-20-allowlist)
  - [`Payments` — DoS-resistant ETH payouts](#payments--dos-resistant-eth-payouts)
  - [`MarketConfig` / `MarketUtils` — shared marketplace library](#marketconfig--marketutils--shared-marketplace-library)
- [Deprecated](#deprecated)
  - [Staking (wound down — lookups return zero)](#staking-wound-down--lookups-return-zero)
  - [Token contracts (superseded)](#token-contracts-superseded)
  - [Factories (superseded)](#factories-superseded)
  - [Never deployed](#never-deployed)
  - [Registries (no longer driving behavior)](#registries-no-longer-driving-behavior)
- [Building](#building)
- [Tests](#tests)

## Quick reference

| What you want to do | Use this |
|---|---|
| List, offer on, or auction a **single** token | [`SuperRareBazaar`](#superrarebazaar--single-token-marketplace) |
| Run a public mint (blind or sequential) of newly-created tokens | [`RareMinter`](#rareminter--blind--sequential-lazy-minting) + [`LazySovereignNFT`](#lazysovereignnft--token-contract-for-rareminter-drops) |
| Prep a large drop for sale or auction | [`LazySovereignBatchMint`](#lazysovereignbatchmint--lazy-batch-drops) |
| Batch-sell many tokens at one price (Merkle) | [`RareBatchListingMarketplace`](#rarebatchlistingmarketplace) |
| Batch-auction many tokens (Merkle) | [`RareBatchAuctionHouse`](#rarebatchauctionhouse) |
| Make one offer covering many tokens, even across collections (Merkle) | [`BatchOffer`](#batchoffer) |
| Mint into a single creator-owned collection | [`SovereignBatchMint`](#sovereignbatchmint--standard-creator-collections) |
| Restrict which ERC-20s the protocol accepts | [`ApprovedTokenRegistry`](#approvedtokenregistry--required-erc-20-allowlist) |
| Stake RARE / earn rewards | **Deprecated — see below** |

---

## Marketplace

The contracts in this section are the entry points for buying, selling, and making offers on NFTs in Rare Protocol — including the public-mint (buyer-pays-to-mint) flow.

### `SuperRareBazaar` — single-token marketplace

The Bazaar is the entry point for **all single-token marketplace actions** on Rare Protocol:

- List a token for sale (set / cancel sale price)
- Place and accept offers
- Run Coldie (reserve) auctions
- Run scheduled auctions
- Buy a listed token

**Integration pattern:** `SuperRareBazaar` is the contract that gets approved on your ERC-721. Before listing a token or accepting an offer, the seller must `setApprovalForAll(superRareBazaar, true)` (or `approve` the specific token) on the NFT contract. The Bazaar pulls the NFT during sale settlement.

This is the right contract for any single-token flow. For multi-token Merkle flows (batch listings, batch auctions, batch offers), see the batch contracts below.

#### How the Bazaar is built

`SuperRareBazaar` is the public entry point, but the marketplace and auction logic actually live in two separate implementation contracts that the Bazaar `delegatecall`s into:

- **`src/marketplace/SuperRareMarketplace.sol`** — implements offers (place / cancel / accept), sale prices (set / remove), and direct buys.
- **`src/auctionhouse/SuperRareAuctionHouse.sol`** — implements `configureAuction`, `bid`, `settleAuction`, and `cancelAuction`. (`convertOfferToAuction` exists on the interface but is deprecated — the implementation reverts.)

Routing is **per-function and explicit**: the Bazaar has its own functions that each `delegatecall` to the appropriate implementation address (no generic `fallback()`). Storage is shared via inheritance — both implementations extend `SuperRareBazaarBase`, which extends `SuperRareBazaarStorage`, so all three contracts read and write the same storage layout when delegatecalled. The implementation addresses are owner-swappable on the Bazaar via `setSuperRareMarketplace` and `setSuperRareAuctionHouse`, which is how marketplace logic can be upgraded without redeploying the Bazaar (and without changing the address users have approved).

If you're reading the Bazaar's source and the function bodies look thin, that's why — the real logic is in `SuperRareMarketplace` and `SuperRareAuctionHouse`.

### `RareBatchListingMarketplace`

`src/v2/marketplace/RareBatchListingMarketplace.sol`. Merkle-based batch listings at a uniform price.

- Seller commits a Merkle root over `(contract, tokenId)` pairs, plus a single price, currency, and split config.
- Buyers prove inclusion of the token they want and pay the price.
- Optional nested Merkle allow-list to gate buyers.

### `RareBatchAuctionHouse`

`src/v2/auctionhouse/RareBatchAuctionHouse.sol`. Merkle-based batch auctions.

- Seller commits a Merkle root plus auction parameters (starting bid, duration, currency, splits).
- Each token in the batch can be bid on independently using a Merkle proof.
- Auctions settle per-token via `settleAuction`.

### `BatchOffer`

`src/batchoffer/BatchOffer.sol`. The offer-side complement to `RareBatchListingMarketplace` — a Merkle-based batch *offer* contract. A buyer commits a single offer covering an arbitrary set of `(contract, tokenId)` pairs and any holder of any token in that set can accept.

- **Maker (buyer)** calls `createBatchOffer(rootHash, amount, currency, expiry)` and **funds are escrowed at offer creation** (offer amount + marketplace fee).
- **Acceptor (token holder)** calls `acceptBatchOffer(creator, proof, rootHash, contractAddress, tokenId, splits)` with a Merkle proof for their `(contract, tokenId)` leaf.
- **Cross-collection by design** — the leaf format is `keccak256(contract, tokenId)`, so a single Merkle root can cover tokens from multiple ERC-721 contracts.
- Buyer can pull escrowed funds back via `revokeBatchOffer(rootHash)`. Offers also expire via the `expiry` timestamp set at creation.
- No allow-list — any holder of a token in the commitment can accept.
- Acceptors must approve `BatchOffer` as an operator on their ERC-721 before accepting (NFT settlement uses `safeTransferFrom`).

Use `BatchOffer` when you want to make a **blanket offer over a curated list of tokens** (potentially across collections). For an entire-collection offer, the buyer simply commits a Merkle root that covers every token ID in the collection.

### `RareMinter` — blind & sequential lazy minting

`RareMinter` is the marketplace contract for **blind mints and sequential token lazy minting** — fixed-price public drops where buyers pay and receive a newly-minted token in one transaction. Token IDs are assigned sequentially as each buyer comes in (1, 2, 3, ...), and tokens are minted on-demand at sale settlement rather than pre-minted upfront. The contract supports optional Merkle allow-lists, per-address and per-tx mint caps, payment currency selection, and revenue splits.

**Pairs with:** [`LazySovereignNFT`](#lazysovereignnft--token-contract-for-rareminter-drops) and its [`LazySovereignNFTV5`](#lazysovereignnftv5--optional-creator-token-transfer-validation) variant. `RareMinter` calls `IERC721Mint.mintTo(address) returns (uint256)`. The other active token contracts (`SovereignBatchMint`, `LazySovereignBatchMint`) have richer `mintTo` signatures and aren't callable by `RareMinter`.

**Setup:**
1. Deploy `LazySovereignNFT` via `LazySovereignNFTFactory` (see [Token Contracts](#token-contracts)).
2. Call `setMinterApproval(rareMinterAddress, true)` on the NFT to authorize `RareMinter` as a minter.
3. Call `RareMinter.prepareMintDirectSale(...)` to configure currency, price, start time, mint caps, and splits.
4. Buyers call `RareMinter.mintDirectSale(...)` to purchase + mint in one tx.

---

## Token Contracts

The ERC-721 contracts that hold the NFTs themselves, plus the factories that deploy creator-owned instances of them. All active contracts inherit the standard ERC-2981 royalty extension (see [Royalty extensions](#royalty-extensions) below).

### `LazySovereignNFT` — token contract for `RareMinter` drops

`src/token/ERC721/sovereign/lazy/LazySovereignNFT.sol`. The ERC-721 designed to be paired with `RareMinter`. Token IDs are assigned sequentially by an internal counter — every call to `mintTo(receiver)` returns the next ID (1, 2, 3, ...).

This contract supports two common drop styles when paired with `RareMinter`:

- **Sequential mints** — buyers receive tokens in mint order with metadata pinned at deploy time (e.g. `baseURI/<id>.json` resolves to a real, finalized asset from day one).
- **Blind mints** — sequential token IDs, but the `baseURI` initially points at placeholder metadata. After the sale completes, the creator calls `updateBaseURI(...)` to swap in the real metadata, "revealing" the collection.

There is no on-chain randomization or shuffle mechanism — "blind" here is an off-chain UX pattern enabled by `updateBaseURI`. If you need randomized assignment, that has to be implemented at a layer above this contract.

### `LazySovereignNFTV5` — optional creator-token transfer validation

[`LazySovereignNFTV5`](src/token/ERC721/sovereign/lazy/extensions/LazySovereignNFTV5.sol) extends `LazySovereignNFT` with the creator-token interface and transfer-time validation. It preserves `mintTo(address)`, minter permissions, metadata preparation, URI updates/locking, supply cap and ERC-2981 queries used by the existing release flow. It is a new optional implementation, not a replacement for standard or legacy RoyaltyGuard collections.

**Deployment and tooling**

1. Deploy a `LazySovereignNFTV5` implementation and the updated `LazySovereignNFTFactory`. Its owner installs the implementation with `setSovereignNFT(implementation, factory.LAZY_SOVEREIGN_NFT_V5())`.
2. Artists create clones with the existing `createSovereignNFTContract(name, symbol, maxTokens, contractType)` signature, selecting `LAZY_SOVEREIGN_NFT_V5`. Both existing creation events are retained.
3. Prepare metadata, approve `RareMinter` and configure the release using the existing methods. Minting does not require a new `RareMinter` implementation.

The implementation is installed separately because embedding a fourth token deployment in the factory constructor exceeds Ethereum's init-code limit. V5 creation reverts until an implementation with code is installed. The standalone V5 implementation is initialization-locked; each clone initializes once. Existing factory deployments are not upgraded by this source change.

**This is not yet a new published CLI option.** The inspected Rare SDK/CLI deployment selectors only recognize the existing lazy types and use configured per-chain factory addresses. Selecting V5 through their normal deployment flow requires the new constant/ABI/type selection and the deployed factory address to be registered downstream. Do not disguise V5 as `lazy-royalty-guard` or silently switch the ordinary lazy type. Existing release/mint/metadata interfaces can be used once a V5 collection address is supplied; this does not establish Studio-kit or hosted Connect end-to-end readiness.

**Validator policy and royalties**

- Clone initialization selects Limit Break V5 at `0x721C008fdff27BF06E7E123956E2Fe03B63342e3` and registers token type 721. It reverts if the validator is absent or registration fails, rather than silently creating an unrestricted collection. Validate deployment on every intended chain.
- `ICreatorToken` discovery reports the view selector `validateTransfer(address,address,address,uint256)`. Ordinary transfers call that validator even when an operator already holds approval. Mint/burn skip validation; validator-originated transfers follow the upstream prevalidated-transfer convention. The token never grants automatic validator approval.
- The collection owner can call `setTransferValidator(address)` or directly configure V5's ruleset/list. Zero disables validation; nonzero replacements must have code and accept token-type registration. This is artist-controlled policy, not an immutable royalty guarantee.
- Initially the collection uses V5's default policy/list, including its upstream-managed authorizers. To support SuperRare trading, configure a reviewed operator list for the actual Bazaar/other supported transfer callers. This token does not automatically whitelist every SuperRare sale contract. Enabling V5's default-list extension adds Limit Break list 0; it does not create a SuperRare-owned default.
- OpenSea uses the creator-token/authorizer flow with restricted orders and signed fulfillment data. Generic Seaport/conduit allowlisting is not equivalent to royalty checking. A compatible interface and a successful SuperRare test are not evidence of an OpenSea signed-order fill.
- ERC-2981 and payout remain separate. There is no new platform cut, splitter or approved collection rate baked in. Initialization retains the existing lazy collection's 10% default receiver/rate behavior; configure approved terms before minting. The added owner-only `setDefaultRoyaltyPercentage(uint256)` matches the existing SDK selector, uses **whole percent (0–100), not basis points**, and rejects values above 100.
- The inherited mint logic stores token-specific receiver/rate values. Changing a default does not rewrite an already-minted token's nonzero stored values; explicit per-token receiver updates remain available. Zero is the inherited royalty-percentage fallback sentinel. Keep these semantics in mind when changing settings after mint.

Protocol references: [creator-token-standards v5.0.0](https://github.com/limitbreakinc/creator-token-standards/tree/980a63b33591d568b6e04b45f37deba05a55f787), [V5 deployment directory](https://apptokens.com/docs/integration-guide/creator-token-standards/v5/contract-deployments), [V5 policy source](https://github.com/limitbreakinc/creator-token-transfer-validator/tree/59adb8b36ab0256c7430b017b1c9f8b4841d6e1e), and [OpenSea creator-fee integration](https://docs.opensea.io/docs/creator-fee-enforcement).

**PFP launch work beyond this token**

These are integration/design boundaries, not commitments to implement them in this change:

| Area | Reuse | Work still required |
| --- | --- | --- |
| deans artwork and immediate reveal | Sequential mint IDs, base URI, per-token URI override and metadata lock | Final asset/trait-attribution preparation, permanent storage, assignment fairness, pre-mint secrecy and the exact immediate-reveal mechanism. A later collection-wide URI update is not automatically that mechanism. |
| deans multi-artist payouts | Existing primary-sale split inputs and a configurable secondary royalty receiver | Approved individual allocations, fee basis and an executable multi-recipient distribution design. Primary proceeds and secondary royalties need separate configurations; a two-recipient example does not distribute contributor pools. |
| Both collections' phases | One active RareMinter price/start/transaction cap; replaceable address-only allowlist root and expiry | Different scheduled phase prices, reserved supply/carryover and phase-specific allowances need operational reconfiguration or additional phase logic. Root replacement does not reset existing wallet counters. Approve any rolling-update/proof-delivery process. |
| deans wallet limits | RareMinter's collection-wide wallet mint and transaction counters | Confirm the proposed limit and whether it applies only to allowlist or across phases; verify checkout eligibility and proof delivery in the chosen Studio kit. |
| CARNAGE dynamic artwork | Virtual `tokenURI`, standard NFT ownership and existing creator-token integration surface | Integrate V5 with the artist's actual renderer/game contract if it must retain onchain artwork and arena state. This generic URI token does not implement or migrate that art. Verify thumbnails, fighter pages and the reported metadata-refresh fix; no ERC-4906 refresh mechanism is added here. |
| CARNAGE supply/burn and delegated wallets | Fixed cumulative mint cap; inherited burn; sender-based RareMinter minting | Resolve fixed/open/timed supply and burn policy. Burning does not replenish mint capacity. An allowlisted hot wallet receives its own mint; native vault minting is not supplied. |
| Both launches' readiness | Existing token/minter primitives | Per-collection consent/economics, supported wallet/device and sale-path checks, peak-demand rehearsal, monitoring, incident/pause procedures and launch sign-off. |

In the inspected source, `RareMinter` does not invoke `MarketUtils.checkSplits`, even though that helper specifies a five-recipient cap. Do not infer that an arbitrary contributor allocation is validated on-chain: approve and validate recipient/ratio totals through the actual deployment tool and exercise real payouts. No unrelated payout or phase implementation is changed here.


### `SovereignBatchMint` — standard creator collections

`src/v2/token/ERC721/sovereign/SovereignBatchMint.sol`. A creator-owned ERC-721 supporting both individual minting and batch creation:

- `mintTo(string uri, address receiver, address royaltyReceiver)` — immediately mints a single token to `receiver` with the given URI. Owner-only.
- `addNewToken(string uri)` — same as `mintTo` but mints to `msg.sender` (the contract owner).
- `batchMint(string baseURI, uint256 numberOfTokens)` — reserves a contiguous token ID range under `baseURI` and emits an EIP-2309 `ConsecutiveTransfer` event. Standard ERC-721 indexers and marketplaces interpret this event as ownership of the whole range by the contract owner, so **the tokens are immediately visible and tradeable on any ERC-721 marketplace** the moment the batch is created. Token URIs resolve to `baseURI/<id>.json`.

Use this when you want a creator collection that works seamlessly with the broader ERC-721 ecosystem — both Rare's marketplace contracts and external marketplaces (OpenSea, Blur, etc.) — with the option of either one-off immediate mints or large batch reservations.

### `LazySovereignBatchMint` — lazy batch drops

`src/v2/token/ERC721/sovereign/LazySovereignBatchMint.sol`. Designed for large drops where the creator doesn't want to pay gas to mint every token upfront.

**Flow:**

1. **Prep** — `prepareMint(string baseURI, uint256 numberOfTokens)` reserves a contiguous token ID range and stores the base URI. No tokens are minted on-chain yet; gas cost is one-time per batch, not per token.
2. **Configure for sale** — the prepped tokens can be sold three ways:
   - **Individually**, by listing a single prepped token on [`SuperRareBazaar`](#superrarebazaar--single-token-marketplace).
   - **Batch fixed-price**, by registering a Merkle root on [`RareBatchListingMarketplace`](#rarebatchlistingmarketplace).
   - **Batch auction**, by registering a Merkle root on [`RareBatchAuctionHouse`](#rarebatchauctionhouse).
3. **Materialize on transfer** — when a buyer purchases (or wins an auction for) a prepped token, it's minted on-chain as part of the `transferFrom`. The buyer never sees the lazy/prep mechanics.

The contract owner is the "owner of record" for unminted prepped tokens, which is what makes them listable before they exist on-chain.

### Choosing between `SovereignBatchMint` and `LazySovereignBatchMint`

Both contracts let a creator reserve a contiguous range of token IDs with a base URI, and in both cases the underlying ERC-721 storage isn't actually written until each token is first transferred. **The meaningful difference is what events get emitted, and therefore who can see the tokens.**

- **`SovereignBatchMint.batchMint`** emits `ConsecutiveTransfer(startId, endId, address(0), owner())` — the EIP-2309 batch-mint event. Standard ERC-721 indexers (block explorers, OpenSea, Blur, any marketplace that watches the standard events) recognize this and immediately treat the entire range as owned by the contract owner. The tokens are visible and tradeable everywhere from the moment the batch is created. `SovereignBatchMint` also exposes individual `mintTo` and `addNewToken` for one-off immediate mints.
- **`LazySovereignBatchMint.prepareMint`** emits only a custom `PrepareMint` event (not EIP-2309, not `Transfer`). Standard indexers don't know what to do with this and won't show the prepped tokens at all. From the outside world's perspective the tokens don't exist until they're actually transferred for the first time — at which point a normal `Transfer(0x0, owner, tokenId)` event fires and the token becomes visible to indexers.

In practice:

| | `SovereignBatchMint` | `LazySovereignBatchMint` |
|---|---|---|
| Visible to external marketplaces / indexers immediately after batch | Yes | No — only after first transfer |
| Listable on Rare's contracts ([Bazaar](#superrarebazaar--single-token-marketplace), [`RareBatchListingMarketplace`](#rarebatchlistingmarketplace), [`RareBatchAuctionHouse`](#rarebatchauctionhouse), [`BatchOffer`](#batchoffer)) | Yes | Yes |
| Listable on any other ERC-721 marketplace contract | Yes | Yes technically, but in practice no — the external marketplace's UI won't display the tokens until they're transferred |
| Individual immediate mint via `mintTo` / `addNewToken` | Yes | No (only `prepareMint`) |

**Use `SovereignBatchMint`** when you want the batch to be discoverable and tradeable across the broader ERC-721 ecosystem (OpenSea, Blur, etc.) from day one, or when you want individual immediate-mint capability alongside batch reservation.

**Use `LazySovereignBatchMint`** when you only intend to sell through Rare's own contracts (or you specifically want the batch invisible to external marketplaces until each token is settled). The Rare API exposes prepped tokens for display purposes, so they aren't invisible everywhere — just to indexers that only watch standard ERC-721 events.

### Factories — how creators get their own contract instance

All creator-owned NFT contracts above are designed to be deployed per-creator via a factory. Every active factory in this repo uses OpenZeppelin's `Clones.clone()` (EIP-1167 minimal proxy) and exposes a permissionless deploy function — anyone can call it to spin up a new collection instance owned by `msg.sender`.

**Recommended (V2):**

- **`SovereignBatchMintFactory`** (`src/v2/token/ERC721/sovereign/SovereignBatchMintFactory.sol`) — deploys `SovereignBatchMint`. This is the recommended path for new creator collections.
- **`LazySovereignBatchMintFactory`** (`src/v2/token/ERC721/sovereign/LazySovereignBatchMintFactory.sol`) — deploys `LazySovereignBatchMint`. Use this for large drops that will be sold via the batch listing/auction contracts.

**Use only for `RareMinter` drops:**

- **`LazySovereignNFTFactory`** (`src/token/ERC721/sovereign/lazy/LazySovereignNFTFactory.sol`) — deploys `LazySovereignNFT` and its optional variants, including separately installed `LazySovereignNFTV5`. Use this for `RareMinter` drops; the implementations retain its `mintTo(address)` interface. For non-`RareMinter` drops, prefer the V2 factories above.

### Royalty extensions

All active NFT contracts in this repo (`LazySovereignNFT`, `SovereignBatchMint`, `LazySovereignBatchMint`) inherit `ERC2981Upgradeable` from `src/token/extensions/`, the standard ERC-2981 royalty interface. Royalty info is set during the contract's `init` and can be configured per-token or per-contract.

---

## Infra Contracts

These contracts aren't entry points for users, but every marketplace and minting contract in this repo depends on them.

### `MarketplaceSettings` — fees, limits, primary/secondary tracking

`src/marketplace/MarketplaceSettingsV3.sol` is the current version, and it's the only one the active marketplace and minting contracts hold a reference to. `V1` and `V2` are still around because each version's contract is the source of truth for **which tokens were sold primary under it** — `markERC721Token` / `hasERC721TokenSold` data lives on whichever version was active at the time of sale. `V3` chains backward internally: when `hasERC721TokenSold` is queried, it checks its own `contractSold` set first and then delegates to `V2` (which delegates to `V1`) so historical primary-sale state is preserved. Callers don't need to know about the older versions — they always go through `V3`.

Holds the protocol-wide configuration that every marketplace and minting contract reads from:

- **Marketplace fee percentage** + helpers like `calculateMarketplaceFee(amount)` (applied on secondary sales).
- **Primary sale fee percentage** — applied on a token's first sale instead of the marketplace fee. V3 uses a single protocol-wide rate; the per-contract override that existed in V1 was removed (V3's `getERC721ContractPrimarySaleFeePercentage(address)` ignores the address argument and always returns the default).
- **Min / max transaction values** that bound any single sale.
- **Primary-vs-secondary tracking** via `markERC721Token` / `hasERC721TokenSold` — determines which fee rate applies on a given sale.

It is `Ownable`, not a proxy. Configuration changes happen by calling owner-only setters; the active settings address is held by the Bazaar, `RareMinter`, and the V2 batch contracts (`RareBatchListingMarketplace`, `RareBatchAuctionHouse`, `BatchOffer`) and can be rotated via setters on each.

### `ApprovedTokenRegistry` — required ERC-20 allowlist

`src/registry/ApprovedTokenRegistry.sol`. Maintains the set of ERC-20 tokens that the protocol's marketplace and minting contracts will accept as payment currency.

This registry **is required** and **is enforced** — the marketplace and minting contracts check it before settling any sale denominated in an ERC-20. Its purpose is security: it prevents a malicious or malformed ERC-20 (e.g., one with hooks that re-enter, fee-on-transfer behavior, or other quirks) from being used as a sale currency. ETH is always allowed without registry membership; arbitrary ERC-20s are not.

If you're integrating a new currency, that token must be added to this registry by the protocol owner before it can be used in `SuperRareBazaar`, `RareMinter`, or the batch contracts (`RareBatchListingMarketplace`, `RareBatchAuctionHouse`, `BatchOffer`).

### `Payments` — DoS-resistant ETH payouts

`src/payments/Payments.sol`. Wraps every ETH payout in the protocol with a pull-payment fallback to prevent malicious recipient contracts from blocking sales.

The risk it mitigates: if a payout recipient is a contract that intentionally reverts or burns gas in its `receive()`/`fallback()` (e.g., an attacker-controlled royalty receiver, an artist contract gone bad, or just a buggy multisig), a naive ETH transfer would revert the entire sale tx — meaning that token could never sell again until the recipient was changed. That's a denial-of-service on listings.

`Payments` solves this by:

1. Attempting a direct ETH send via `call{value: amount, gas: 50_000}("")` (gas is bounded so a recipient can't burn unlimited gas).
2. **If the send fails, the funds are escrowed** for the recipient using OpenZeppelin's `PullPayment` (via `_asyncTransfer`). The outer transaction never reverts on this failure.
3. The recipient must later call `withdrawPayments(payee)` themselves to pull the escrowed funds.

`refund(payee, amount)` and `payout(splits, amounts, ...)` both use this pattern. The escrow path applies to ETH only — ERC-20 transfers don't have this DoS shape and are sent directly.

### `MarketConfig` / `MarketUtils` — shared marketplace library

`src/utils/structs/MarketConfig.sol` and `src/utils/MarketUtils.sol` (plus `MarketConfigV2` / `MarketUtilsV2` under `src/v2/utils/`).

These are **stateless Solidity libraries**, not contracts. They were extracted out of the original Bazaar so that the same logic could be reused everywhere — historically a lot of validation, fee math, and payment routing was inlined into the Bazaar itself; today it lives here and is shared.

- **`MarketConfig`** defines a `Config` struct that bundles every interface address a marketplace contract needs (`MarketplaceSettings`, `ApprovedTokenRegistry`, royalty engine, payment router, etc.) plus owner-gated update helpers for each field.
- **`MarketUtils`** holds the cross-cutting helpers: currency-is-approved checks, "sender must own this token" / "marketplace must be approved" guards, split validation, and the `checkAmountAndTransfer` payment routing helper that handles both ETH and ERC-20 paths.

Used by `RareMinter`, `BatchOffer`, and the V1 Bazaar internals (V1 variants), and by `RareBatchListingMarketplace` and `RareBatchAuctionHouse` (V2 variants). If you're writing a new marketplace-style contract in this repo, prefer extending these libraries over re-implementing the same checks.

---

## Deprecated

The contracts in this section remain in the repo for reference and to support existing on-chain deployments. **Do not deploy new instances and do not build new integrations against them.**

A note on what "deprecated" means here: some of these contracts are still wired into the active marketplace and minting contracts as initialization parameters or state variables, and a few of them are still called on the live payout / minting paths. The deprecation is at the **data layer**: the registries hold no live data — no approved space operators, no stakers with non-zero balances, no royalty engine fallback to the legacy registry — so the calls return empty/zero values and produce no effect. Either the contract is never called, or the lookup is performed and evaluates to a no-op. Either way, the protocol behavior these contracts used to gate has been turned off.

### Staking (wound down — lookups return zero)

Staking has been wound down at the data level. The on-chain code paths that read from `RareStakingRegistry`, `RarityPool`, and `RewardAccumulator` are still live: `RareMinter` calls `stakingRegistry.getStakingAddressForUser(...)` and `IRarityPool.getAmountStakedByUser(...)` to enforce its (now-zero) seller staking minimum, and the payout helpers (`MarketUtils.payout`, `MarketUtilsV2.payoutWithMarketplaceFee`, `SuperRareBazaarBase._payout`) call `stakingRegistry.getRewardAccumulatorAddressForUser(...)` to look up where to route rewards. But the staking data itself has been zeroed out — staked amounts are 0, no reward accumulators are configured, and the contract-seller-staking-minimum is 0 — so each lookup returns nothing useful and the staking branch is effectively skipped.

The staking-registry address still appears as an init parameter on `RareMinter`, `RareBatchListingMarketplace`, `RareBatchAuctionHouse`, and as a field on `MarketConfig` / `MarketConfigV2`.

- `src/staking/RareStakingRegistry.sol`
- `src/staking/RarityPool.sol`
- `src/staking/reward/RewardAccumulator.sol`

### Token contracts (superseded)

Use the V2 token contracts in [Token Contracts](#token-contracts) instead.

- `src/token/ERC721/sovereign/SovereignNFT.sol` — superseded by `SovereignBatchMint`.
- `src/token/ERC721/spaces/RareSpaceNFT.sol` — Spaces are no longer a supported product surface.
- `src/token/ERC721/superrare/SuperRareV2.sol` — the original platform NFT; new mints go through the V2 minting contracts.

### Factories (superseded)

- **`src/token/ERC721/sovereign/SovereignNFTContractFactory.sol`** — deploys `SovereignNFT` and its royalty-guarded variants. Superseded by `SovereignBatchMintFactory`.
- **`src/token/ERC721/spaces/RareSpaceNFTContractFactory.sol`** — paired with `RareSpaceNFT`, which is no longer supported.

### Never deployed

- **`src/collection/RareCollectionMarket.sol`** — designed as a collection-wide offer / collection-wide sale-price contract. Never deployed; we ended up using `BatchOffer` for the same use case (a buyer-side offer covering many tokens) since `BatchOffer`'s Merkle commitment is strictly more flexible. The source is kept for posterity.

### Registries (no longer driving behavior)

- **`src/registry/RoyaltyRegistry.sol`** — replaced by the royalty engine (the `royaltyEngine` field on `MarketConfig`) for all royalty lookups. `SuperRareBazaar` still imports `IRareRoyaltyRegistry` and stores its address, but the active flow never calls into it.
- **`src/registry/SpaceOperatorRegistry.sol`** — Spaces are no longer a supported product. The payout helpers (`MarketUtils.payout`, `MarketUtilsV2.payoutWithMarketplaceFee`, `SuperRareBazaarBase._payout`) still call `isApprovedSpaceOperator(seller)` and `getPlatformCommission(seller)` on every payout, but **all space operator entries have been removed from the registry**, so `isApprovedSpaceOperator` returns false for every seller and the platform-commission branch never fires.
- **`src/registry/CreatorRegistry.sol`** — unused by the active contracts (not even imported).

---

## Building

```bash
forge install
make build
```

## Tests

```bash
make test
```

The existing `make test` target runs the non-fork suite. The V5 integration module uses the real V5 validator, deployed RareMinter and Bazaar at Ethereum block 26350391:

```bash
MAINNET_RPC_URL="$ARCHIVE_MAINNET_RPC_URL" forge test \
  --match-path src/test/forks/mainnet/LazySovereignNFTV5.t.sol -vv
```

The module performs all writes only inside Foundry's fork. A local Anvil fork at the same block can be supplied as `MAINNET_RPC_URL` when the upstream RPC transport is unreliable. It covers paid primary minting, secondary Bazaar royalty balances after explicit operator setup, default denied/allowed transfers, revocation despite prior approval, owner controls, initialization and inherited metadata/royalty behavior. It does not exercise OpenSea's offchain signature service, every marketplace fill path or a hosted Connect browser checkout.

