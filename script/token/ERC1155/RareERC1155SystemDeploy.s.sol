// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {RareERC1155Marketplace} from "../../../src/marketplace/RareERC1155Marketplace.sol";
import {RareERC1155Settlement} from "../../../src/marketplace/RareERC1155Settlement.sol";
import {ERC20ApprovalManager} from "../../../src/v2/approver/ERC20/ERC20ApprovalManager.sol";
import {ERC1155ApprovalManager} from "../../../src/v2/approver/ERC1155/ERC1155ApprovalManager.sol";
import {RareERC1155ContractFactory} from "../../../src/token/ERC1155/RareERC1155ContractFactory.sol";
import {RareERC1155SettlementScriptGuard} from "../../marketplace/RareERC1155SettlementScriptGuard.s.sol";
import {NetworkConfig} from "../../NetworkConfig.s.sol";

/// @title RareERC1155SystemDeploy
/// @notice Deploys and wires the ERC1155 marketplace, approval managers, settlement module, and collection factory.
/// @dev Shared marketplace dependency addresses are selected from NetworkConfig using block.chainid.
contract RareERC1155SystemDeploy is RareERC1155SettlementScriptGuard {
    error NetworkAddressNotConfigured(string name, uint256 chainId);

    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        NetworkConfig.Addresses memory config = NetworkConfig.getCurrent();

        vm.startBroadcast(privateKey);

        address networkBeneficiary = _required(config.networkBeneficiary, "networkBeneficiary");
        address marketplaceSettings = _required(config.marketplaceSettingsV3, "marketplaceSettingsV3");
        address spaceOperatorRegistry = _required(config.spaceOperatorRegistry, "spaceOperatorRegistry");
        address royaltyEngine = _required(config.royaltyEngineManifold, "royaltyEngineManifold");
        address payments = _required(config.payments, "payments");
        address approvedTokenRegistry = _required(config.approvedTokenRegistry, "approvedTokenRegistry");
        address stakingSettings = marketplaceSettings;
        address stakingRegistry = _required(config.stakingRegistry, "stakingRegistry");

        address erc20ApprovalManager = _required(config.erc20ApprovalManager, "erc20ApprovalManager");
        address erc721ApprovalManager = _required(config.erc721ApprovalManager, "erc721ApprovalManager");
        address erc1155ApprovalManager = _required(config.erc1155ApprovalManager, "erc1155ApprovalManager");

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

        _grantErc20OperatorIfAuthorized(erc20ApprovalManager, address(marketplaceProxy), deployer);
        _grantErc1155OperatorIfAuthorized(erc1155ApprovalManager, address(marketplaceProxy), deployer);

        RareERC1155ContractFactory factory = new RareERC1155ContractFactory();
        factory.setDefaultMinter(address(marketplaceProxy));

        console.log("Network:", NetworkConfig.chainName(block.chainid));
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", deployer);
        console.log("Network beneficiary:", networkBeneficiary);
        console.log("Marketplace settings:", marketplaceSettings);
        console.log("Space operator registry:", spaceOperatorRegistry);
        console.log("Royalty engine:", royaltyEngine);
        console.log("Payments:", payments);
        console.log("Approved token registry:", approvedTokenRegistry);
        console.log("Staking settings:", stakingSettings);
        console.log("Staking registry:", stakingRegistry);
        console.log("ERC20ApprovalManager:", erc20ApprovalManager);
        console.log("ERC721ApprovalManager:", erc721ApprovalManager);
        console.log("ERC1155ApprovalManager:", erc1155ApprovalManager);
        console.log("RareERC1155Settlement:", address(settlement));
        console.log("RareERC1155Marketplace implementation:", address(marketplaceImplementation));
        console.log("RareERC1155Marketplace proxy:", address(marketplaceProxy));
        console.log("RareERC1155ContractFactory:", address(factory));
        console.log("RareERC1155 implementation:", factory.rareERC1155());
        console.log("RareERC1155ContractFactory owner:", factory.owner());
        console.log("RareERC1155ContractFactory default minter:", factory.defaultMinter());

        vm.stopBroadcast();
    }

    function _required(address value, string memory name) private view returns (address) {
        if (value == address(0)) revert NetworkAddressNotConfigured(name, block.chainid);
        return value;
    }

    function _grantErc20OperatorIfAuthorized(address manager, address operator, address deployer) private {
        ERC20ApprovalManager approvalManager = ERC20ApprovalManager(manager);
        bytes32 operatorRole = approvalManager.OPERATOR_ROLE();
        if (approvalManager.hasRole(operatorRole, operator)) {
            console.log("ERC20ApprovalManager operator role already granted:", operator);
            return;
        }

        if (!approvalManager.hasRole(approvalManager.MANAGER_ROLE(), deployer)) {
            console.log("ERC20ApprovalManager operator role not granted; deployer lacks MANAGER_ROLE");
            console.log("ERC20ApprovalManager:", manager);
            console.log("Missing operator:", operator);
            return;
        }

        approvalManager.grantOperatorRole(operator);
        console.log("ERC20ApprovalManager operator role granted:", operator);
    }

    function _grantErc1155OperatorIfAuthorized(address manager, address operator, address deployer) private {
        ERC1155ApprovalManager approvalManager = ERC1155ApprovalManager(manager);
        bytes32 operatorRole = approvalManager.OPERATOR_ROLE();
        if (approvalManager.hasRole(operatorRole, operator)) {
            console.log("ERC1155ApprovalManager operator role already granted:", operator);
            return;
        }

        if (!approvalManager.hasRole(approvalManager.MANAGER_ROLE(), deployer)) {
            console.log("ERC1155ApprovalManager operator role not granted; deployer lacks MANAGER_ROLE");
            console.log("ERC1155ApprovalManager:", manager);
            console.log("Missing operator:", operator);
            return;
        }

        approvalManager.grantOperatorRole(operator);
        console.log("ERC1155ApprovalManager operator role granted:", operator);
    }
}
