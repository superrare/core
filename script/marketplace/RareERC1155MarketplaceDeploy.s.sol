// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ERC20ApprovalManager} from "../../src/v2/approver/ERC20/ERC20ApprovalManager.sol";
import {ERC1155ApprovalManager} from "../../src/v2/approver/ERC1155/ERC1155ApprovalManager.sol";
import {RareERC1155Marketplace} from "../../src/marketplace/RareERC1155Marketplace.sol";
import {RareERC1155Settlement} from "../../src/marketplace/RareERC1155Settlement.sol";
import {RareERC1155SettlementScriptGuard} from "./RareERC1155SettlementScriptGuard.s.sol";

/// @title RareERC1155MarketplaceDeploy
/// @notice Deploys the ERC1155 marketplace implementation, settlement module, and ERC1967 marketplace proxy.
contract RareERC1155MarketplaceDeploy is RareERC1155SettlementScriptGuard {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(privateKey);

        address deployer = vm.addr(privateKey);
        address networkBeneficiary = vm.envOr("NETWORK_BENEFICIARY", deployer);
        address marketplaceSettings = vm.envAddress("SETTINGS_ADDRESS");
        address spaceOperatorRegistry = vm.envAddress("SPACE_OPERATOR_REGISTRY");
        address royaltyEngine = vm.envAddress("ROYALTY_ENGINE");
        address payments = vm.envAddress("PAYMENTS");
        address approvedTokenRegistry = vm.envAddress("TOKEN_REGISTRY");
        address stakingSettings = vm.envAddress("STAKING_SETTINGS");
        address stakingRegistry = vm.envAddress("STAKING_REGISTRY");
        address erc20ApprovalManager = vm.envAddress("ERC20_APPROVAL_MANAGER");
        address erc721ApprovalManager = vm.envAddress("ERC721_APPROVAL_MANAGER");
        address erc1155ApprovalManager = vm.envAddress("ERC1155_APPROVAL_MANAGER");

        RareERC1155Settlement settlement = new RareERC1155Settlement();
        _validateSettlementModuleForScript(address(settlement));
        RareERC1155Marketplace marketplaceImplementation = new RareERC1155Marketplace();

        bytes memory initData = abi.encodeWithSelector(
            RareERC1155Marketplace.initialize.selector,
            networkBeneficiary,
            marketplaceSettings,
            spaceOperatorRegistry,
            royaltyEngine,
            payments,
            approvedTokenRegistry,
            stakingSettings,
            stakingRegistry,
            erc20ApprovalManager,
            erc721ApprovalManager,
            erc1155ApprovalManager,
            address(settlement)
        );

        ERC1967Proxy marketplaceProxy = new ERC1967Proxy(address(marketplaceImplementation), initData);

        ERC20ApprovalManager(erc20ApprovalManager).grantOperatorRole(address(marketplaceProxy));
        ERC1155ApprovalManager(erc1155ApprovalManager).grantOperatorRole(address(marketplaceProxy));

        console.log("RareERC1155Settlement deployed at:", address(settlement));
        console.log("RareERC1155Marketplace implementation deployed at:", address(marketplaceImplementation));
        console.log("RareERC1155Marketplace proxy deployed at:", address(marketplaceProxy));

        vm.stopBroadcast();
    }
}
