// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import "../../src/marketplace/RareERC1155Marketplace.sol";

/// @title RareERC1155MarketplaceLogicUpdate
/// @notice Forge script for upgrading an existing ERC1155 marketplace proxy to a new implementation.
/// @dev Reads `PRIVATE_KEY` and `RARE_ERC1155_MARKETPLACE` from the environment.
contract RareERC1155MarketplaceLogicUpdate is Script {
    /// @notice Deploys new marketplace logic and calls `upgradeTo` on the configured proxy.
    function run() external {
        // Broadcast boundary: following operations are submitted as deployer transactions.
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        // Environment read: proxy address to upgrade.
        address marketplaceProxy = vm.envAddress("RARE_ERC1155_MARKETPLACE");

        // Deployment operation: deploy replacement UUPS implementation.
        RareERC1155Marketplace marketplace = new RareERC1155Marketplace();

        // Upgrade transaction: proxy owner must authorize the implementation change.
        RareERC1155Marketplace(marketplaceProxy).upgradeTo(address(marketplace));

        // Broadcast boundary: stop submitting transactions.
        vm.stopBroadcast();
    }
}
