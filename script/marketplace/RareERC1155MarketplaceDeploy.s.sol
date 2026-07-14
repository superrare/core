// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ERC20ApprovalManager} from "../../src/v2/approver/ERC20/ERC20ApprovalManager.sol";
import {ERC1155ApprovalManager} from "../../src/v2/approver/ERC1155/ERC1155ApprovalManager.sol";
import {RareERC1155CheckoutExecutionModule} from "../../src/marketplace/RareERC1155CheckoutExecutionModule.sol";
import {RareERC1155Marketplace} from "../../src/marketplace/RareERC1155Marketplace.sol";
import {RareERC1155TradeExecutionModule} from "../../src/marketplace/RareERC1155TradeExecutionModule.sol";
import {RareERC1155ExecutionModuleScriptGuard} from "./RareERC1155ExecutionModuleScriptGuard.s.sol";
import {NetworkConfig} from "../NetworkConfig.s.sol";

/// @title RareERC1155MarketplaceDeploy
/// @notice Deploys the ERC1155 marketplace implementation, execution modules, and ERC1967 marketplace proxy.
contract RareERC1155MarketplaceDeploy is RareERC1155ExecutionModuleScriptGuard {
    error NetworkAddressNotConfigured(string name, uint256 chainId);
    error ApprovalManagerOperatorGrantUnauthorized(string name, address manager, address deployer, address operator);
    error ApprovalManagerOperatorRoleMissing(string name, address manager, address operator);

    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        NetworkConfig.Addresses memory config = NetworkConfig.getCurrent();

        vm.startBroadcast(privateKey);

        address networkBeneficiary = _required(config.networkBeneficiary, "networkBeneficiary");
        address marketplaceSettings = _required(config.marketplaceSettingsV3, "marketplaceSettingsV3");
        address royaltyEngine = _required(config.royaltyEngineManifold, "royaltyEngineManifold");
        address payments = _required(config.payments, "payments");
        address approvedTokenRegistry = _required(config.approvedTokenRegistry, "approvedTokenRegistry");
        address erc20ApprovalManager = _required(config.erc20ApprovalManager, "erc20ApprovalManager");
        address erc721ApprovalManager = _required(config.erc721ApprovalManager, "erc721ApprovalManager");
        address erc1155ApprovalManager = _required(config.erc1155ApprovalManager, "erc1155ApprovalManager");

        RareERC1155TradeExecutionModule tradeExecutionModule = new RareERC1155TradeExecutionModule();
        _validateExecutionModuleForScript(address(tradeExecutionModule));
        RareERC1155CheckoutExecutionModule checkoutExecutionModule = new RareERC1155CheckoutExecutionModule();
        _validateExecutionModuleForScript(address(checkoutExecutionModule));
        RareERC1155Marketplace marketplaceImplementation = new RareERC1155Marketplace();

        bytes memory initData = abi.encodeWithSelector(
            RareERC1155Marketplace.initialize.selector,
            networkBeneficiary,
            marketplaceSettings,
            royaltyEngine,
            payments,
            approvedTokenRegistry,
            erc20ApprovalManager,
            erc721ApprovalManager,
            erc1155ApprovalManager,
            address(tradeExecutionModule),
            address(checkoutExecutionModule)
        );

        ERC1967Proxy marketplaceProxy = new ERC1967Proxy(address(marketplaceImplementation), initData);

        _grantErc20OperatorOrRevert(erc20ApprovalManager, address(marketplaceProxy), deployer);
        _grantErc1155OperatorOrRevert(erc1155ApprovalManager, address(marketplaceProxy), deployer);

        console.log("Network:", NetworkConfig.chainName(block.chainid));
        console.log("Chain ID:", block.chainid);
        console.log("Network beneficiary:", networkBeneficiary);
        console.log("Marketplace settings:", marketplaceSettings);
        console.log("Royalty engine:", royaltyEngine);
        console.log("Payments:", payments);
        console.log("Approved token registry:", approvedTokenRegistry);
        console.log("ERC20ApprovalManager:", erc20ApprovalManager);
        console.log("ERC721ApprovalManager:", erc721ApprovalManager);
        console.log("ERC1155ApprovalManager:", erc1155ApprovalManager);
        console.log("RareERC1155TradeExecutionModule deployed at:", address(tradeExecutionModule));
        console.log("RareERC1155CheckoutExecutionModule deployed at:", address(checkoutExecutionModule));
        console.log("RareERC1155Marketplace implementation deployed at:", address(marketplaceImplementation));
        console.log("RareERC1155Marketplace proxy deployed at:", address(marketplaceProxy));

        vm.stopBroadcast();
    }

    function _required(address value, string memory name) private view returns (address) {
        if (value == address(0)) revert NetworkAddressNotConfigured(name, block.chainid);
        return value;
    }

    function _grantErc20OperatorOrRevert(address manager, address operator, address deployer) private {
        ERC20ApprovalManager approvalManager = ERC20ApprovalManager(manager);
        bytes32 operatorRole = approvalManager.OPERATOR_ROLE();
        if (approvalManager.hasRole(operatorRole, operator)) {
            console.log("ERC20ApprovalManager operator role already granted:", operator);
            return;
        }

        if (!approvalManager.hasRole(approvalManager.MANAGER_ROLE(), deployer)) {
            revert ApprovalManagerOperatorGrantUnauthorized("ERC20ApprovalManager", manager, deployer, operator);
        }

        approvalManager.grantOperatorRole(operator);
        if (!approvalManager.hasRole(operatorRole, operator)) {
            revert ApprovalManagerOperatorRoleMissing("ERC20ApprovalManager", manager, operator);
        }
        console.log("ERC20ApprovalManager operator role granted:", operator);
    }

    function _grantErc1155OperatorOrRevert(address manager, address operator, address deployer) private {
        ERC1155ApprovalManager approvalManager = ERC1155ApprovalManager(manager);
        bytes32 operatorRole = approvalManager.OPERATOR_ROLE();
        if (approvalManager.hasRole(operatorRole, operator)) {
            console.log("ERC1155ApprovalManager operator role already granted:", operator);
            return;
        }

        if (!approvalManager.hasRole(approvalManager.MANAGER_ROLE(), deployer)) {
            revert ApprovalManagerOperatorGrantUnauthorized("ERC1155ApprovalManager", manager, deployer, operator);
        }

        approvalManager.grantOperatorRole(operator);
        if (!approvalManager.hasRole(operatorRole, operator)) {
            revert ApprovalManagerOperatorRoleMissing("ERC1155ApprovalManager", manager, operator);
        }
        console.log("ERC1155ApprovalManager operator role granted:", operator);
    }
}
