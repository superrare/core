// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../../../src/v2/marketplace/RareBatchListingMarketplace.sol";
import "../../../src/v2/approver/ERC721/ERC721ApprovalManager.sol";
import "../../../src/v2/approver/ERC20/ERC20ApprovalManager.sol";

/// @title RareBatchListingMarketplaceDeploy
/// @notice Deployment script for RareBatchListingMarketplace and its dependencies
contract RareBatchListingMarketplaceDeploy is Script {
  function run() external {
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    vm.startBroadcast(privateKey);
    address deployer = vm.addr(privateKey);

    // Get Market Config Values from .env
    address networkBeneficiary = vm.envAddress("NETWORK_BENEFICIARY");
    address marketplaceSettings = vm.envAddress("MARKETPLACE_SETTINGS");
    address spaceOperatorRegistry = vm.envAddress("SPACE_OPERATOR_REGISTRY");
    address royaltyEngine = vm.envAddress("ROYALTY_ENGINE");
    address payments = vm.envAddress("PAYMENTS");
    address approvedTokenRegistry = vm.envAddress("APPROVED_TOKEN_REGISTRY");
    address stakingSettings = vm.envAddress("STAKING_SETTINGS");
    address stakingRegistry = vm.envAddress("STAKING_REGISTRY");
    address erc721ApprovalManager = vm.envAddress("ERC721_APPROVAL_MANAGER");
    address erc20ApprovalManager = vm.envAddress("ERC20_APPROVAL_MANAGER");

    // Deploy implementation
    RareBatchListingMarketplace marketplaceImplementation = new RareBatchListingMarketplace();

    // Deploy proxy
    ERC1967Proxy marketplaceProxy = new ERC1967Proxy(address(marketplaceImplementation), "");

    // Initialize the proxy
    RareBatchListingMarketplace(address(marketplaceProxy)).initialize(
      marketplaceSettings,
      royaltyEngine,
      spaceOperatorRegistry,
      approvedTokenRegistry,
      payments,
      stakingRegistry,
      stakingSettings,
      networkBeneficiary,
      erc20ApprovalManager,
      erc721ApprovalManager
    );

    // Grant operator role to the marketplace proxy for both approval managers
    ERC721ApprovalManager(erc721ApprovalManager).grantOperatorRole(address(marketplaceProxy));
    ERC20ApprovalManager(erc20ApprovalManager).grantOperatorRole(address(marketplaceProxy));

    // Log deployed addresses
    console.log("ERC721ApprovalManager deployed at:", address(erc721ApprovalManager));
    console.log("ERC20ApprovalManager deployed at:", address(erc20ApprovalManager));
    console.log("RareBatchListingMarketplace implementation deployed at:", address(marketplaceImplementation));
    console.log("RareBatchListingMarketplace proxy deployed at:", address(marketplaceProxy));

    vm.stopBroadcast();
  }
}
