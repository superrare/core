// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "forge-std/Script.sol";

import "../../../src/v2/auctionhouse/RareBatchAuctionHouse.sol";

/// @title RareBatchAuctionHouseUpgrade
/// @notice Deploys a new RareBatchAuctionHouse implementation and upgrades the
///         existing UUPS proxy to point at it. Must be broadcast by the proxy
///         owner (see _authorizeUpgrade -> onlyOwner).
/// @dev Required env vars:
///        PRIVATE_KEY              - deployer/owner key
///        RARE_BATCH_AUCTIONHOUSE  - address of the deployed proxy to upgrade
contract RareBatchAuctionHouseUpgrade is Script {
  function run() external {
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    address proxy = vm.envAddress("RARE_BATCH_AUCTIONHOUSE");

    vm.startBroadcast(privateKey);

    // Deploy the new implementation.
    RareBatchAuctionHouse newImplementation = new RareBatchAuctionHouse();

    // Point the proxy at the new implementation (no re-initialization needed).
    RareBatchAuctionHouse(payable(proxy)).upgradeTo(address(newImplementation));

    console.log("RareBatchAuctionHouse proxy:", proxy);
    console.log("New RareBatchAuctionHouse implementation:", address(newImplementation));

    vm.stopBroadcast();
  }
}
