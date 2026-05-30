// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import "../../src/marketplace/RareERC1155Listings.sol";

/// @title RareERC1155ListingsLogicUpdate
/// @notice Forge script for upgrading an existing ERC1155 marketplace proxy to a new implementation.
/// @dev Reads `PRIVATE_KEY` and `RARE_ERC1155_LISTINGS` from the environment.
contract RareERC1155ListingsLogicUpdate is Script {
    /// @notice Deploys new marketplace logic and calls `upgradeTo` on the configured proxy.
    function run() external {
        // Broadcast boundary: following operations are submitted as deployer transactions.
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        // Environment read: proxy address to upgrade.
        address marketplaceProxy = vm.envAddress("RARE_ERC1155_LISTINGS");

        // Deployment operation: deploy replacement UUPS implementation.
        RareERC1155Listings marketplace = new RareERC1155Listings();

        // Upgrade transaction: proxy owner must authorize the implementation change.
        RareERC1155Listings(marketplaceProxy).upgradeTo(address(marketplace));

        // Broadcast boundary: stop submitting transactions.
        vm.stopBroadcast();
    }
}
