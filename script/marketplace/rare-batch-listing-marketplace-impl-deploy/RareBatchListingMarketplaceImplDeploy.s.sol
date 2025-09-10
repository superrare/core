// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "forge-std/Script.sol";

import "../../../src/v2/marketplace/RareBatchListingMarketplace.sol";

/// @title RareBatchListingMarketplaceImplDeploy
/// @notice Deployment script for RareBatchListingMarketplace implementation only (no proxy deployment)
contract RareBatchListingMarketplaceImplDeploy is Script {
  function run() external {
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    vm.startBroadcast(privateKey);
    address deployer = vm.addr(privateKey);

    // Deploy implementation only
    RareBatchListingMarketplace marketplaceImplementation = new RareBatchListingMarketplace();

    // Log deployed address
    console.log("Deployer address:", deployer);
    console.log("RareBatchListingMarketplace implementation deployed at:", address(marketplaceImplementation));

    vm.stopBroadcast();
  }
}
