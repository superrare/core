// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {console} from "forge-std/Script.sol";

import {RareERC1155CheckoutExecutionModule} from "../../src/marketplace/RareERC1155CheckoutExecutionModule.sol";
import {RareERC1155Marketplace} from "../../src/marketplace/RareERC1155Marketplace.sol";
import {RareERC1155ExecutionModuleScriptGuard} from "./RareERC1155ExecutionModuleScriptGuard.s.sol";

/// @title RareERC1155CheckoutExecutionModuleUpdate
/// @notice Deploys a new checkout execution module and points an existing marketplace proxy at it.
contract RareERC1155CheckoutExecutionModuleUpdate is RareERC1155ExecutionModuleScriptGuard {
    function run() external {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        address marketplaceProxy = vm.envAddress("RARE_ERC1155_MARKETPLACE");
        RareERC1155CheckoutExecutionModule checkoutExecutionModule = new RareERC1155CheckoutExecutionModule();
        _validateExecutionModuleForScript(address(checkoutExecutionModule));

        RareERC1155Marketplace(marketplaceProxy).setCheckoutExecutionModule(address(checkoutExecutionModule));

        console.log("RareERC1155CheckoutExecutionModule deployed at:", address(checkoutExecutionModule));
        console.log("RareERC1155Marketplace proxy updated at:", marketplaceProxy);

        vm.stopBroadcast();
    }
}
