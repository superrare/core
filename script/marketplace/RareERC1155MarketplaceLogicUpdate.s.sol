// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";

import {RareERC1155Marketplace} from "../../src/marketplace/RareERC1155Marketplace.sol";

/// @title RareERC1155MarketplaceLogicUpdate
/// @notice Deploys a new marketplace implementation and upgrades an existing marketplace proxy.
contract RareERC1155MarketplaceLogicUpdate is Script {
    function run() external {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        address marketplaceProxy = vm.envAddress("RARE_ERC1155_MARKETPLACE");
        RareERC1155Marketplace marketplaceImplementation = new RareERC1155Marketplace();

        RareERC1155Marketplace(marketplaceProxy).upgradeTo(address(marketplaceImplementation));

        console.log("RareERC1155Marketplace implementation deployed at:", address(marketplaceImplementation));
        console.log("RareERC1155Marketplace proxy upgraded at:", marketplaceProxy);

        vm.stopBroadcast();
    }
}
