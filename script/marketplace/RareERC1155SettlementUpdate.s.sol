// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {console} from "forge-std/Script.sol";

import {RareERC1155Marketplace} from "../../src/marketplace/RareERC1155Marketplace.sol";
import {RareERC1155Settlement} from "../../src/marketplace/RareERC1155Settlement.sol";
import {RareERC1155SettlementScriptGuard} from "./RareERC1155SettlementScriptGuard.s.sol";

/// @title RareERC1155SettlementUpdate
/// @notice Deploys a new settlement module and points an existing marketplace proxy at it.
contract RareERC1155SettlementUpdate is RareERC1155SettlementScriptGuard {
    function run() external {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        address marketplaceProxy = vm.envAddress("RARE_ERC1155_MARKETPLACE");
        RareERC1155Settlement settlement = new RareERC1155Settlement();
        _validateSettlementModuleForScript(address(settlement));

        RareERC1155Marketplace(marketplaceProxy).setSettlement(address(settlement));

        console.log("RareERC1155Settlement deployed at:", address(settlement));
        console.log("RareERC1155Marketplace proxy updated at:", marketplaceProxy);

        vm.stopBroadcast();
    }
}
