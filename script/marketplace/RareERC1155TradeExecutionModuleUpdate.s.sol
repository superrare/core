// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {console} from "forge-std/Script.sol";

import {RareERC1155Marketplace} from "../../src/marketplace/RareERC1155Marketplace.sol";
import {RareERC1155TradeExecutionModule} from "../../src/marketplace/RareERC1155TradeExecutionModule.sol";
import {RareERC1155ExecutionModuleScriptGuard} from "./RareERC1155ExecutionModuleScriptGuard.s.sol";

/// @title RareERC1155TradeExecutionModuleUpdate
/// @notice Deploys a new trade execution module and points an existing marketplace proxy at it.
contract RareERC1155TradeExecutionModuleUpdate is RareERC1155ExecutionModuleScriptGuard {
    function run() external {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        address marketplaceProxy = vm.envAddress("RARE_ERC1155_MARKETPLACE");
        RareERC1155TradeExecutionModule tradeExecutionModule = new RareERC1155TradeExecutionModule();
        _validateExecutionModuleForScript(address(tradeExecutionModule));

        RareERC1155Marketplace(marketplaceProxy).setTradeExecutionModule(address(tradeExecutionModule));

        console.log("RareERC1155TradeExecutionModule deployed at:", address(tradeExecutionModule));
        console.log("RareERC1155Marketplace proxy updated at:", marketplaceProxy);

        vm.stopBroadcast();
    }
}
