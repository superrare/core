// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "forge-std/Script.sol";

import "../../../src/v2/marketplace/RareBatchListingMarketplace.sol";

/// @title RareBatchListingMarketplaceUpgrade
/// @notice Deploys a new RareBatchListingMarketplace implementation and upgrades
///         the existing UUPS proxy to point at it. Must be broadcast by the proxy
///         owner (see _authorizeUpgrade -> onlyOwner).
/// @dev Required env vars:
///        PRIVATE_KEY                   - deployer/owner key
///        RARE_BATCH_LISTING_MARKETPLACE - address of the deployed proxy to upgrade
contract RareBatchListingMarketplaceUpgrade is Script {
  function run() external {
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    address proxy = vm.envAddress("RARE_BATCH_LISTING_MARKETPLACE");

    vm.startBroadcast(privateKey);

    // Deploy the new implementation.
    RareBatchListingMarketplace newImplementation = new RareBatchListingMarketplace();

    // Point the proxy at the new implementation (no re-initialization needed).
    RareBatchListingMarketplace(address(proxy)).upgradeTo(address(newImplementation));

    console.log("RareBatchListingMarketplace proxy:", proxy);
    console.log("New RareBatchListingMarketplace implementation:", address(newImplementation));

    vm.stopBroadcast();
  }
}
