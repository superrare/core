// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "forge-std/Script.sol";

import "../../../src/v2/auctionhouse/RareBatchAuctionHouse.sol";

/// @title RareBatchAuctionHouseImplDeploy
/// @notice Deployment script for RareBatchAuctionHouse implementation only (no proxy deployment)
contract RareBatchAuctionHouseImplDeploy is Script {
  function run() external {
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    vm.startBroadcast(privateKey);
    address deployer = vm.addr(privateKey);

    // Deploy implementation only
    RareBatchAuctionHouse auctionHouseImplementation = new RareBatchAuctionHouse();

    // Log deployed address
    console.log("Deployer address:", deployer);
    console.log("RareBatchAuctionHouse implementation deployed at:", address(auctionHouseImplementation));

    vm.stopBroadcast();
  }
}
